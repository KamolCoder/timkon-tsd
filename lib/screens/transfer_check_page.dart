import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Offline check of one «Перемещение товаров» downloaded by TransferListWidget.
/// No network: document, names, articles, units and barcodes (from 1C) are on the TSD.
///
/// Scan or typed article → quantity dialog (prefilled 1, or the package quantity
/// for a package barcode; weighed goods: the weight is typed). fact = plan → OK,
/// less → shortage, more → excess (allowed after confirmation, listed in the
/// comment). Goods not in the document only show a warning and are not added. «Готово» is a hold-to-confirm button; the result is stored on the
/// TSD and TransferListWidget sends it to 1C.
class TransferCheckWidget extends StatefulWidget {
  const TransferCheckWidget({
    super.key,
    this.width,
    this.height,
    required this.transferKey,
    this.checkerName,
    this.onSaved,
  });

  final double? width;
  final double? height;

  /// Ref_Key of Document_ПеремещениеТоваров (downloaded to the TSD)
  final String transferKey;

  /// Who checks — goes to the 1C comment. Empty → from settings.
  final String? checkerName;

  /// After «Готово». Default: go back to the list (Navigator.maybePop).
  final Future Function()? onSaved;

  @override
  State<TransferCheckWidget> createState() => _TransferCheckWidgetState();
}

// ───────────── local storage (same format as in TransferListWidget) ─────────────

class _Store {
  static const docPrefix = 'tsd_doc_';
  static const prodPrefix = 'tsd_prod_';

  static Map<String, dynamic>? read(SharedPreferences p, String key) {
    final s = p.getString(key);
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? doc(SharedPreferences p, String key) => read(p, '$docPrefix$key');

  static Future<void> putDoc(SharedPreferences p, Map<String, dynamic> d) =>
      p.setString('$docPrefix${d['key']}', jsonEncode(d));

  static Map<String, dynamic>? prod(SharedPreferences p, String key) => read(p, '$prodPrefix$key');
}

// ───────────────────────────── model ─────────────────────────────

const _zeroGuid = '00000000-0000-0000-0000-000000000000';

enum _St { pending, ok, short, excess }

class _DocLine {
  _DocLine(this.raw);
  final Map<String, dynamic> raw;
  double get plan => _num(raw['Количество']);
  String get unitKey => (raw['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString();
}

class _Item {
  _Item(this.productKey, this.charKey, this.name);
  final String productKey;
  final String charKey;
  String name;
  String article = '';
  bool weight = false;
  final List<_DocLine> lines = [];
  double fact = 0;

  String get key => '$productKey|$charKey';
  double get plan => lines.fold(0, (s, l) => s + l.plan);
}

/// EAN / UPC check digit for the data digits: from the right, weights 3, 1, 3, …;
/// check = (10 − sum mod 10) mod 10.
int _eanCheckDigit(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    final d = digits.codeUnitAt(digits.length - 1 - i) - 48;
    sum += i.isEven ? d * 3 : d;
  }
  return (10 - sum % 10) % 10;
}

/// After Enter, waits until the field has not changed for [quiet], then calls
/// [onDone]. A keyboard-wedge scanner's Enter can overtake its last characters
/// (the code was read without the last digit); they get in before the read.
class _EnterSettle {
  _EnterSettle(this.ctrl, this.onDone);
  final TextEditingController ctrl;
  final void Function() onDone;
  static const quiet = Duration(milliseconds: 150);
  Timer? _timer;
  String _seen = '';

  bool get pending => _timer != null;

  void enter() {
    _timer?.cancel();
    _seen = ctrl.text;
    _timer = Timer(quiet, _check);
  }

  void _check() {
    if (ctrl.text != _seen) {
      _seen = ctrl.text; // still typing: wait for the next quiet period
      _timer = Timer(quiet, _check);
      return;
    }
    _timer = null;
    onDone();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Article for matching: trimmed, lower case, without leading zeros («00435» = «435»).
String _normArticle(String s) => s.trim().toLowerCase().replaceFirst(RegExp(r'^0+'), '');

double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

String _fmt(double v) {
  final r = (v * 1000).roundToDouble() / 1000;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

_St _status(_Item it) {
  final plan = it.plan, fact = it.fact;
  if (fact == 0) return _St.pending;
  if ((fact - plan).abs() < 1e-6) return _St.ok;
  return fact < plan ? _St.short : _St.excess;
}

const _stColor = {
  _St.pending: Color(0xFF9E9E9E),
  _St.ok: Color(0xFF2E7D32),
  _St.short: Color(0xFFF9A825),
  _St.excess: Color(0xFFC62828),
};

const _stBg = {
  _St.pending: Colors.white,
  _St.ok: Color(0xFFE8F5E9),
  _St.short: Color(0xFFFFF8E1),
  _St.excess: Color(0xFFFFEBEE),
};

const _stLabel = {
  _St.pending: 'не собрано',
  _St.ok: 'совпало',
  _St.short: 'недостача',
  _St.excess: 'излишек',
};

enum _Filter { all, left, issues }

// ───────────────────────────── state ─────────────────────────────

class _TransferCheckWidgetState extends State<TransferCheckWidget> {

  bool _loading = true;
  String? _error;

  Map<String, dynamic> _doc = {};
  final List<_Item> _items = [];
  final Map<String, _Item> _byKey = {};

  /// barcode → (productKey, charKey, unitKey); goods of this document (from 1C)
  final Map<String, List<String>> _barcodes = {};

  /// barcodes / names / articles of goods of the other downloaded documents
  Map<String, List<String>>? _otherCodes;
  final Map<String, String> _otherNames = {};

  final Map<String, List<String>> _otherArticles = {}; // normalized article → productKeys

  final Map<String, double> _unitCoef = {};

  String _checker = '';
  bool _dialogOpen = false;
  _Filter _filter = _Filter.all;

  /// Scan field on top: always focused, so keyboard-wedge scanners that type
  /// through the input method (not as key events) reach the app.
  final TextEditingController _scanCtrl = TextEditingController();
  final FocusNode _scanFocus = FocusNode();
  Timer? _scanTimer;
  late final _scanSettle = _EnterSettle(_scanCtrl, _submitScan);
  bool _keyboard = false; // soft keyboard for manual input
  String _lastScan = '';

  /// true: every scan opens the quantity dialog; false: added at once.
  bool _askQty = true;

  @override
  void initState() {
    super.initState();
    _scanFocus.addListener(() {
      if (!_scanFocus.hasFocus && !_reattaching) _refocus();
    });
    // Back from the Android home screen: the field still has focus, but its input
    // connection is gone and the scanner types into nowhere → reconnect it.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scanTimer?.cancel();
    _scanSettle.cancel();
    _scanCtrl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _refocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dialogOpen || _loading || _error != null) return;
      if (!_scanFocus.hasFocus) _scanFocus.requestFocus();
    });
  }

  late final AppLifecycleListener _lifecycle;
  bool _reattaching = false;

  void _onResume() {
    if (!_dialogOpen) return _reattach();
    // a dialog is open: reconnect its focused field (quantity / hidden scan field)
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    node.unfocus();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (node.context != null) node.requestFocus();
    });
  }

  /// Unfocus + focus again (what the ⌨ button does): opens a fresh input
  /// connection, so a keyboard-wedge scanner reaches the field again. Used after
  /// returning to the app and after every dialog.
  void _reattach() {
    if (!mounted || _dialogOpen || _loading || _error != null) return;
    _reattaching = true;
    _scanFocus.unfocus();
    Future.delayed(const Duration(milliseconds: 50), () {
      _reattaching = false;
      if (mounted && !_dialogOpen) _scanFocus.requestFocus();
    });
  }

  // ── loading (local only) ──

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = _Store.read(prefs, 'tsd_settings') ?? {};
      _askQty = prefs.getBool('tsd_ask_qty') ?? true;
      _checker = (widget.checkerName?.isNotEmpty ?? false)
          ? widget.checkerName!
          : (settings['checkerName'] ?? '').toString();

      final doc = _Store.doc(prefs, widget.transferKey);
      if (doc == null) throw 'Документа нет на ТСД.\nНажмите «Загрузить» на списке.';
      if (doc['status'] == 'conflict') throw 'Конфликт: ${doc['error'] ?? ''}';
      _doc = doc;

      for (final row in ((doc['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final pk = (row['Номенклатура_Key'] ?? _zeroGuid).toString();
        final c = (row['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString();
        final it = _byKey.putIfAbsent('$pk|$c', () {
          final n = _Item(pk, c, pk.length >= 8 ? pk.substring(0, 8) : pk);
          _items.add(n);
          return n;
        });
        it.lines.add(_DocLine(row));
      }
      final keys = _items.map((e) => e.productKey).toSet();
      for (final pk in keys) {
        final e = _Store.prod(prefs, pk);
        if (e != null) _apply(pk, e);
      }
      _restoreProgress();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _apply(String productKey, Map<String, dynamic> e) {
    for (final it in _items.where((i) => i.productKey == productKey)) {
      it.name = (e['name'] ?? it.name).toString();
      it.article = (e['article'] ?? '').toString();
      it.weight = e['weight'] == true;
    }
    for (final u in (e['units'] as List? ?? const [])) {
      final coef = _num(u[1]);
      _unitCoef[u[0].toString()] = coef <= 0 ? 1 : coef;
    }
    for (final c in (e['codes'] as List? ?? const [])) {
      _barcodes[c[0].toString()] = [productKey, c[1].toString(), c[2].toString()];
    }
  }

  Future<Map<String, List<String>>> _others() async {
    if (_otherCodes != null) return _otherCodes!;
    final prefs = await SharedPreferences.getInstance();
    final map = <String, List<String>>{};
    for (final k in prefs.getKeys().where((k) => k.startsWith(_Store.prodPrefix))) {
      final e = _Store.read(prefs, k);
      if (e == null) continue;
      final pk = k.substring(_Store.prodPrefix.length);
      _otherNames[pk] = (e['name'] ?? '').toString();
      final art = _normArticle((e['article'] ?? '').toString());
      if (art.isNotEmpty) _otherArticles.putIfAbsent(art, () => []).add(pk);
      for (final u in (e['units'] as List? ?? const [])) {
        _unitCoef.putIfAbsent(u[0].toString(), () => math.max(1.0, _num(u[1])));
      }
      for (final c in (e['codes'] as List? ?? const [])) {
        map[c[0].toString()] = [pk, c[1].toString(), c[2].toString()];
      }
    }
    return _otherCodes = map;
  }

  // ── progress on the TSD ──

  void _restoreProgress() {
    final m = _doc['progress'] as Map<String, dynamic>?;
    if (m == null) return;
    (m['facts'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _byKey[k]?.fact = _num(v));
  }

  Future<void> _saveProgress() async {
    _doc['progress'] = {
      'facts': {for (final i in _items) if (i.fact != 0) i.key: i.fact},
    };
    _doc['status'] = 'work'; // any change after «Готово» needs «Готово» again
    _doc.remove('result');
    _doc.remove('error');
    await _Store.putDoc(await SharedPreferences.getInstance(), _doc);
  }

  // ── scanning ──

  void _submitScan() {
    _scanTimer?.cancel();
    _scanSettle.cancel();
    final code = _scanCtrl.text.trim();
    _scanCtrl.clear();
    if (code.isNotEmpty) _onScan(code);
    _refocus();
  }

  void _onScanEnter() {
    _scanTimer?.cancel();
    _scanSettle.enter();
  }

  /// Scanners without an Enter suffix: accept the code 300 ms after the last char.
  void _onScanChanged(String v) {
    _scanTimer?.cancel();
    if (_keyboard || _scanSettle.pending) return; // after Enter: _EnterSettle submits
    _scanTimer = Timer(const Duration(milliseconds: 300), () {
      if (_scanCtrl.text.trim().length >= 6) _submitScan();
    });
  }

  void _toggleKeyboard() {
    setState(() => _keyboard = !_keyboard);
    _scanFocus.unfocus();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) _scanFocus.requestFocus();
    });
  }

  Future<void> _onScan(String code) async {
    setState(() => _lastScan = code);
    // barcode of this document / of another downloaded document, else article
    var hit = await _byBarcode(code);
    if (hit == null) {
      final byArt = await _findByArticle(code);
      if (byArt == _cancelled) return;
      hit = byArt as List<String>?;
    }
    final it = hit == null ? null : (_byKey['${hit[0]}|${hit[1]}'] ?? _byKey['${hit[0]}|$_zeroGuid']);
    if (it == null) {
      // not in this document: only a warning, nothing is added
      final next = await _notInDocDialog(code, hit == null ? null : _otherNames[hit[0]]);
      if (next != null) await _onScan(next);
      return;
    }
    final step = _unitCoef[hit![2]] ?? 1;

    String? next;
    double qty = step;
    final ask = _askQty || it.weight;
    if (ask) {
      _Beep.ok(); // recognized
      final r = await _qtyDialog(it, step);
      if (r == null) return;
      qty = r.qty;
      next = r.nextCode;
    }

    if (qty > 0) {
      it.fact += qty;
      final st = _status(it);
      if (st == _St.excess) {
        _alarm('Больше плана: ${it.name}');
      } else {
        HapticFeedback.lightImpact();
        if (st == _St.ok) {
          _Beep.done(); // line complete
        } else if (!ask) {
          _Beep.ok();
        }
      }
      setState(() {});
      await _saveProgress();
    }
    if (next != null) await _onScan(next);
  }

  static const _cancelled = Object();

  /// Barcode of this / another downloaded document. A scanner set up without the
  /// check digit sends 12 (EAN-13) / 7 (EAN-8) / 11 (UPC-A) digits: retry with it.
  Future<List<String>?> _byBarcode(String code) async {
    final others = await _others();
    List<String>? find(String c) => _barcodes[c] ?? others[c];
    final hit = find(code);
    if (hit != null) return hit;
    if (const {7, 11, 12}.contains(code.length) && RegExp(r'^\d+$').hasMatch(code)) {
      return find('$code${_eanCheckDigit(code)}');
    }
    return null;
  }

  /// Typed article (weighed goods usually have no barcode in 1C) → goods of this
  /// document (several: pick one), then goods of the other downloaded documents
  /// (→ «not in this document»). Returns [productKey, charKey, unitKey], null or [_cancelled].
  Future<Object?> _findByArticle(String code) async {
    final n = _normArticle(code);
    if (n.isEmpty) return null;
    final inDoc = _items.where((i) => _normArticle(i.article) == n).toList();
    if (inDoc.isNotEmpty) {
      final it = inDoc.length == 1 ? inDoc.first : await _pickItem(inDoc, code);
      if (it == null) return _cancelled;
      return [it.productKey, it.charKey, ''];
    }
    await _others();
    final other = _otherArticles[n];
    if (other != null && other.isNotEmpty) return [other.first, _zeroGuid, ''];
    return null;
  }

  Future<_Item?> _pickItem(List<_Item> items, String code) async {
    _dialogOpen = true;
    final r = await showDialog<_Item>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Артикул $code'),
        children: [
          for (final it in items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, it),
              child: Text('${it.name}\nплан ${_fmt(it.plan)} · собрано ${_fmt(it.fact)}'),
            ),
        ],
      ),
    );
    _dialogOpen = false;
    _reattach();
    return r;
  }

  /// Red warning for goods not in this document. Has its own scan field, so the
  /// next scan closes the warning and is processed. Returns that next code.
  Future<String?> _notInDocDialog(String code, String? name) async {
    _dialogOpen = true;
    HapticFeedback.heavyImpact();
    _Beep.error();
    final ctrl = TextEditingController();
    var closed = false;
    _EnterSettle? settle; // created once: the builder can run again
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void close([String? value]) {
          if (closed) return;
          closed = true;
          Navigator.pop(ctx, value);
        }

        settle ??= _EnterSettle(ctrl, () {
          final t = ctrl.text.trim();
          if (ctx.mounted) close(t.isEmpty ? null : t);
        });

        return AlertDialog(
          backgroundColor: const Color(0xFFFFEBEE),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(8)),
              child: Text(name == null ? 'НЕ НАЙДЕНО' : 'НЕТ В ЭТОМ ДОКУМЕНТЕ',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const SizedBox(height: 12),
            if (name != null) Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(name == null ? 'Штрихкод / артикул $code нет в накладной' : 'Штрихкод / артикул $code',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            const Text('Отложите товар. В проверку он не добавляется.'),
            // invisible scan target: the next scan closes the warning
            SizedBox(
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.none,
                  onSubmitted: (_) => settle?.enter(),
                ),
              ),
            ),
          ]),
          actions: [FilledButton(onPressed: close, child: const Text('OK'))],
        );
      },
    );
    _dialogOpen = false;
    settle?.cancel();
    _reattach();
    ctrl.dispose();
    return next;
  }

  Future<_QtyResult?> _qtyDialog(_Item it, double step, {bool replace = false}) async {
    // weighed goods: no default for a new scan, the weight must be typed
    final ctrl = TextEditingController(text: it.weight && !replace ? '' : _fmt(step));
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
    final hint = ValueNotifier<String?>(null);
    _dialogOpen = true;

    _QtyResult? parse(String raw) {
      final t = raw.trim();
      if (t.length >= 8 && RegExp(r'^\d+$').hasMatch(t)) {
        if (!it.weight) return _QtyResult(step, t); // next barcode
        ctrl.clear();
        hint.value = 'Сначала введите вес';
        return null;
      }
      final v = double.tryParse(t.replaceAll(',', '.'));
      if (v == null || v < 0 || v > 99999) return null;
      return _QtyResult(v, null);
    }

    void bump(double d) {
      final v = (double.tryParse(ctrl.text.replaceAll(',', '.')) ?? 0) + d;
      ctrl.text = _fmt(v < 0 ? 0 : v);
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    }

    var closed = false;
    _EnterSettle? settle; // created once: the builder can run again
    final res = await showDialog<_QtyResult>(
      context: context,
      builder: (ctx) {
        void submit() {
          final r = parse(ctrl.text);
          if (r == null || closed) return;
          closed = true; // Enter + button / delayed Enter must not pop twice
          Navigator.pop(ctx, r);
        }

        // Same late-last-digit race as the scan field (next scan in the dialog).
        settle ??= _EnterSettle(ctrl, () {
          if (ctx.mounted) submit();
        });

        return AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(it.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              if (it.article.isNotEmpty) Text('арт. ${it.article}', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              Row(children: [
                _chip('План', _fmt(it.plan), Colors.blueGrey),
                const SizedBox(width: 8),
                _chip('Собрано', _fmt(it.fact), _stColor[_status(it)]!),
              ]),
              if (step > 1 && !replace)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Штрихкод упаковки: ${_fmt(step)} шт', style: const TextStyle(color: Colors.black54)),
                ),
              const SizedBox(height: 12),
              Row(children: [
                _roundBtn(Icons.remove, () => bump(-1)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: ctrl,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                        labelText: replace ? 'Факт' : (it.weight ? 'Вес, кг' : 'Количество'),
                        border: const OutlineInputBorder(),
                        isDense: true),
                    onSubmitted: (_) => settle?.enter(),
                  ),
                ),
                const SizedBox(width: 8),
                _roundBtn(Icons.add, () => bump(1)),
              ]),
              const SizedBox(height: 4),
              ValueListenableBuilder<String?>(
                valueListenable: hint,
                builder: (_, h, _) => Text(
                    h ??
                        (it.weight
                            ? 'Весовой товар: введите вес, Enter — добавить.'
                            : 'Enter — добавить. Следующий скан добавит этот товар сам.'),
                    style: TextStyle(fontSize: 12, color: h != null ? Colors.red.shade700 : Colors.black45)),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () {
                  if (closed) return;
                  closed = true;
                  Navigator.pop(ctx);
                },
                child: const Text('Отмена')),
            FilledButton(onPressed: submit, child: const Text('Добавить')),
          ],
        );
      },
    );
    _dialogOpen = false;
    settle?.cancel();
    _reattach();
    ctrl.dispose();
    hint.dispose();
    return res;
  }

  Widget _chip(String label, String value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: color.withAlpha(30),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text(label, style: TextStyle(fontSize: 12, color: color)),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      );

  Widget _roundBtn(IconData icon, VoidCallback onTap) => SizedBox(
        width: 52,
        height: 52,
        child: IconButton.filledTonal(onPressed: onTap, icon: Icon(icon, size: 28)),
      );

  void _alarm(String msg) {
    HapticFeedback.heavyImpact();
    _Beep.excess();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleAsk() async {
    setState(() => _askQty = !_askQty);
    (await SharedPreferences.getInstance()).setBool('tsd_ask_qty', _askQty);
    _toast(_askQty ? 'Скан → окно количества' : 'Скан → сразу +1');
  }

  // ── dialogs ──

  Future<void> _editFact(_Item it) async {
    final r = await _qtyDialog(it, it.fact, replace: true);
    if (r == null) return;
    setState(() => it.fact = r.qty); // here the number replaces the fact
    await _saveProgress();
    if (r.nextCode != null) await _onScan(r.nextCode!);
  }

  Future<bool> _confirm(String title, String text, String ok) async {
    _dialogOpen = true;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    );
    _dialogOpen = false;
    _reattach();
    return res == true;
  }

  // ── finish: result for 1C, stored on the TSD ──

  Future<void> _finish() async {
    final shorts = <String>[], excess = <String>[];
    for (final i in _items) {
      final s = _status(i);
      final line = '${i.name} ${_fmt(i.plan)}→${_fmt(i.fact)}';
      if (s == _St.short || s == _St.pending) shorts.add(line);
      if (s == _St.excess) excess.add(line);
    }
    if (shorts.isNotEmpty || excess.isNotEmpty) {
      final text = [
        if (excess.isNotEmpty) 'Излишек (уйдёт в 1С фактом):\n${excess.join('\n')}',
        if (shorts.isNotEmpty) 'Недостача:\n${shorts.join('\n')}',
      ].join('\n\n');
      if (!await _confirm('Есть расхождения', text, 'Завершить')) return;
    }

    final rows = <Map<String, dynamic>>[];
    for (final it in _items) {
      var rest = it.fact;
      for (var n = 0; n < it.lines.length; n++) {
        final line = it.lines[n];
        final qty = n == it.lines.length - 1 ? rest : math.min(rest, line.plan);
        rest -= qty;
        if (qty <= 0) continue;
        final coef = _unitCoef[line.unitKey] ?? 1;
        final units = qty / coef;
        final row = <String, dynamic>{
          for (final e in line.raw.entries)
            if (!e.key.contains('@') && e.key != 'Ref_Key') e.key: e.value,
        };
        row['Количество'] = qty;
        row['КоличествоЕдиницИзмерения'] = units;
        row['Сумма'] = (_num(row['Цена']) * units * 100).roundToDouble() / 100;
        rows.add(row);
      }
    }
    for (var i = 0; i < rows.length; i++) {
      rows[i]['LineNumber'] = '${i + 1}';
    }

    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final log = StringBuffer('[ТСД✓] Проверено: ${_checker.isEmpty ? 'ТСД' : _checker} '
        '${two(now.day)}.${two(now.month)} ${two(now.hour)}:${two(now.minute)}');
    if (excess.isNotEmpty) log.write('; излишек: ${excess.join(', ')}');
    if (shorts.isNotEmpty) log.write('; недостача: ${shorts.join(', ')}');

    await _saveProgress();
    _doc['result'] = {'rows': rows, 'log': log.toString()};
    _doc['status'] = 'checked';
    _doc['checkedAt'] = now.toIso8601String();
    await _Store.putDoc(await SharedPreferences.getInstance(), _doc);

    _toast('Проверено ✓ Отправляем в 1С…');
    if (widget.onSaved != null) {
      await widget.onSaved!();
    } else if (mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _reset() async {
    if (!await _confirm('Начать заново?', 'Все отсканированные количества будут обнулены.', 'Обнулить')) return;
    for (final i in _items) {
      i.fact = 0;
    }
    setState(() {});
    await _saveProgress();
  }

  // ── UI ──

  int _rank(_St s) => const [_St.excess, _St.short, _St.pending, _St.ok].indexOf(s);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 56, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Назад к списку')),
          ]),
        ),
      );
    } else {
      final inDocItems = _items;
      final done = inDocItems.where((i) => _status(i) == _St.ok).length;
      final left = _items.where((i) => _status(i) == _St.pending || _status(i) == _St.short).length;
      final issues = _items.where((i) {
        final s = _status(i);
        return s == _St.excess || s == _St.short;
      }).length;
      final shown = _items.where((i) {
        final s = _status(i);
        switch (_filter) {
          case _Filter.all:
            return true;
          case _Filter.left:
            return s == _St.pending || s == _St.short;
          case _Filter.issues:
            return s == _St.excess || s == _St.short;
        }
      }).toList()
        ..sort((a, b) => _rank(_status(a)).compareTo(_rank(_status(b))));
      final checked = _doc['status'] == 'checked';
      final progress = inDocItems.isEmpty ? 0.0 : done / inDocItems.length;

      body = Column(children: [
        // ── header ──
        Container(
          color: scheme.primaryContainer,
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
          child: Column(children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    (_doc['receiver'] ?? '').toString().isEmpty ? 'Перемещение' : _doc['receiver'].toString(),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text('№ ${_doc['number'] ?? ''}${_doc['posted'] == true ? ' · проведён' : ''}',
                      style: const TextStyle(fontSize: 13, color: Colors.black54)),
                ]),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'ask' ? _toggleAsk() : _reset(),
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(value: 'ask', checked: _askQty, child: const Text('Спрашивать количество')),
                  const PopupMenuItem(value: 'reset', child: Text('Начать заново')),
                ],
              ),
            ]),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 10,
                      backgroundColor: Colors.white,
                      color: const Color(0xFF2E7D32),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text('$done из ${inDocItems.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
        // ── scan field ──
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            autofocus: true,
            showCursor: true,
            keyboardType: _keyboard ? TextInputType.number : TextInputType.none, // ⌨: digits pad at once
            textInputAction: TextInputAction.done,
            onChanged: _onScanChanged,
            onSubmitted: (_) => _onScanEnter(),
            onEditingComplete: () {},
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF1F3F4),
              hintText: _lastScan.isEmpty ? 'Скан или артикул (⌨)' : 'Последний: $_lastScan',
              prefixIcon: const Icon(Icons.qr_code_scanner, size: 28),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              suffixIcon: IconButton(
                tooltip: _keyboard ? 'Скрыть клавиатуру' : 'Ввести вручную',
                icon: Icon(_keyboard ? Icons.keyboard_hide : Icons.keyboard),
                onPressed: _toggleKeyboard,
              ),
            ),
          ),
        ),
        if (checked)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(8)),
            child: const Text('✓ Проверен и ждёт отправки. Если что-то измените — снова «Готово».'),
          ),
        // ── filter ──
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Filter>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
              ),
              segments: [
                _filterSeg(_Filter.all, 'Все ${_items.length}'),
                _filterSeg(_Filter.left, 'Осталось $left'),
                _filterSeg(_Filter.issues, 'Расхожд. $issues', danger: issues > 0),
              ],
              selected: {_filter},
              onSelectionChanged: (v) => setState(() => _filter = v.first),
            ),
          ),
        ),
        // ── lines ──
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(_filter == _Filter.left ? 'Всё собрано ✓' : 'Нет строк',
                      style: const TextStyle(fontSize: 16, color: Colors.black54)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) => _row(shown[i]),
                ),
        ),
        // ── finish ──
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: _HoldButton(
              label: 'Готово — удерживайте',
              onConfirmed: _finish,
              onTapHint: () => _toast('Чтобы завершить, удерживайте «Готово» 1,5 секунды'),
            ),
          ),
        ),
      ]);
    }
    return SizedBox(
        width: widget.width, height: widget.height, child: _EdgeSwipeBack(child: SafeArea(child: body)));
  }

  /// One line always: the label shrinks a little instead of wrapping (3-digit counts).
  ButtonSegment<_Filter> _filterSeg(_Filter f, String label, {bool danger = false}) => ButtonSegment(
        value: f,
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 13, color: danger && _filter != f ? Colors.red.shade700 : null)),
        ),
      );

  Widget _row(_Item it) {
    final st = _status(it);
    final color = _stColor[st]!;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      color: _stBg[st],
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _editFact(it),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 6, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [if (it.article.isNotEmpty) 'арт. ${it.article}', _stLabel[st]!].join(' · '),
                    style: TextStyle(fontSize: 12, color: st == _St.pending ? Colors.black54 : color),
                  ),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_fmt(it.fact), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: color)),
                Text('из ${_fmt(it.plan)}', style: const TextStyle(fontSize: 13, color: Colors.black54)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QtyResult {
  _QtyResult(this.qty, this.nextCode);
  final double qty;
  final String? nextCode;
}

/// Fires only after being held for [hold] (protects «Готово» from an accidental
/// touch). Fills while held; a short tap shows a hint.
class _HoldButton extends StatefulWidget {
  const _HoldButton({required this.label, required this.onConfirmed, this.onTapHint});
  final String label;
  final Future<void> Function() onConfirmed;
  final VoidCallback? onTapHint;
  static const hold = Duration(milliseconds: 1500);

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _HoldButton.hold)
    ..addStatusListener((s) async {
      if (s == AnimationStatus.completed) {
        HapticFeedback.mediumImpact();
        _c.reset();
        await widget.onConfirmed();
      }
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => _c.forward(),
      onTapUp: (_) {
        if (_c.isAnimating) {
          _c.reverse();
          widget.onTapHint?.call();
        }
      },
      onTapCancel: () => _c.reverse(),
      child: AnimatedBuilder(
        animation: _c,
        builder: (ctx, _) => ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(fit: StackFit.expand, children: [
            Container(color: scheme.primary),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: _c.value,
              child: Container(color: Color.lerp(scheme.primary, Colors.black, 0.4)),
            ),
            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, color: scheme.onPrimary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Swipe from the left edge → back (Navigator.maybePop). Works on any Android,
/// also on TSDs with button navigation where the system back gesture is absent.
class _EdgeSwipeBack extends StatefulWidget {
  const _EdgeSwipeBack({required this.child});
  final Widget child;

  @override
  State<_EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<_EdgeSwipeBack> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 28,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _dx = 0,
          onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
          onHorizontalDragEnd: (d) {
            if (_dx > 80 || (d.primaryVelocity ?? 0) > 400) {
              Navigator.of(context).maybePop();
            }
          },
        ),
      ),
    ]);
  }
}

/// Scan sounds: Android ToneGenerator (MainActivity, channel `tsd/beep`), loud and
/// independent of the «touch sounds» setting. No-op if the channel is missing.
class _Beep {
  static const _ch = MethodChannel('tsd/beep');

  static void _play(String kind) => _ch.invokeMethod<void>(kind).catchError((_) {});

  /// recognized / +1
  static void ok() => _play('ok');

  /// line complete (fact = plan)
  static void done() => _play('done');

  /// more than the plan
  static void excess() => _play('excess');

  /// not in the document / not found
  static void error() => _play('error');
}
