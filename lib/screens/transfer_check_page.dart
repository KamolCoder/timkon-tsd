import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Offline check of one «Перемещение товаров» downloaded by TransferListWidget.
/// No network for the check itself: document, names, units and barcodes are on
/// the TSD; the goods catalog with photos (Stock API) is in SQLite.
///
/// Scan → quantity dialog (prefilled 1, or the package quantity for a package
/// barcode). fact = plan → OK, less → shortage, more → excess (allowed after
/// confirmation, listed in the comment). Goods not in the document block
/// «Готово». «Готово» is a hold-to-confirm button; the result is stored on the
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

/// Goods catalog from Stock API (filled by TransferListWidget), read-only here.
class _Catalog {
  static Database? _db;

  static Future<Database?> open() async {
    if (_db != null) return _db;
    try {
      final path = p.join(await getDatabasesPath(), 'tsd_catalog.db');
      if (!await databaseExists(path)) return null;
      return _db = await openDatabase(path); // same instance as the list widget (read-write)
    } catch (_) {
      return null;
    }
  }

  /// barcode → {id, name, article, unit, thumb, image}
  static Future<Map<String, dynamic>?> byBarcode(String code) async {
    final db = await open();
    if (db == null) return null;
    final r = await db.rawQuery(
        'SELECT p.* FROM barcodes b JOIN products p ON p.id = b.id WHERE b.code = ? LIMIT 1', [code]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  static Future<Map<String, Map<String, dynamic>>> byIds(Iterable<String> ids) async {
    final db = await open();
    final out = <String, Map<String, dynamic>>{};
    if (db == null) return out;
    final all = ids.toSet().toList();
    for (var i = 0; i < all.length; i += 500) {
      final part = all.sublist(i, math.min(i + 500, all.length));
      for (final r in await db.query('products', where: 'id IN (${List.filled(part.length, '?').join(',')})', whereArgs: part)) {
        out[r['id'].toString()] = Map<String, dynamic>.from(r);
      }
    }
    return out;
  }

  static Future<String> base() async {
    final prefs = await SharedPreferences.getInstance();
    final s = _Store.read(prefs, 'tsd_settings') ?? {};
    return (s['stockUrl'] ?? '').toString().trim().replaceAll(RegExp(r'/+$'), '');
  }
}

// ───────────────────────────── model ─────────────────────────────

const _zeroGuid = '00000000-0000-0000-0000-000000000000';

enum _St { pending, ok, short, excess, foreign }

class _DocLine {
  _DocLine(this.raw);
  final Map<String, dynamic> raw;
  double get plan => _num(raw['Количество']);
  String get unitKey => (raw['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString();
}

class _Item {
  _Item(this.productKey, this.charKey, this.name, {this.inDoc = true});
  final String productKey;
  final String charKey;
  String name;
  String article = '';
  String thumb = '';
  String image = '';
  bool weight = false;
  final bool inDoc;
  final List<_DocLine> lines = [];
  double fact = 0;

  String get key => '$productKey|$charKey';
  double get plan => lines.fold(0, (s, l) => s + l.plan);
}

double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

String _fmt(double v) {
  final r = (v * 1000).roundToDouble() / 1000;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

_St _status(_Item it) {
  final plan = it.plan, fact = it.fact;
  if (!it.inDoc) return fact > 0 ? _St.foreign : _St.pending;
  if (fact == 0) return _St.pending;
  if ((fact - plan).abs() < 1e-6) return _St.ok;
  return fact < plan ? _St.short : _St.excess;
}

const _stColor = {
  _St.pending: Color(0xFF9E9E9E),
  _St.ok: Color(0xFF2E7D32),
  _St.short: Color(0xFFF9A825),
  _St.excess: Color(0xFFC62828),
  _St.foreign: Color(0xFFC62828),
};

const _stBg = {
  _St.pending: Colors.white,
  _St.ok: Color(0xFFE8F5E9),
  _St.short: Color(0xFFFFF8E1),
  _St.excess: Color(0xFFFFEBEE),
  _St.foreign: Color(0xFFFFEBEE),
};

const _stLabel = {
  _St.pending: 'не собрано',
  _St.ok: 'совпало',
  _St.short: 'недостача',
  _St.excess: 'излишек',
  _St.foreign: 'нет в документе',
};

enum _Filter { all, left, issues }

// ───────────────────────────── state ─────────────────────────────

class _TransferCheckWidgetState extends State<TransferCheckWidget> {
  static const _enterSettle = Duration(milliseconds: 80);

  bool _loading = true;
  String? _error;

  Map<String, dynamic> _doc = {};
  final List<_Item> _items = [];
  final Map<String, _Item> _byKey = {};

  /// barcode → (productKey, charKey, unitKey); goods of this document (from 1C)
  final Map<String, List<String>> _barcodes = {};

  /// barcodes / names of goods of the other downloaded documents
  Map<String, List<String>>? _otherCodes;
  final Map<String, String> _otherNames = {};

  final Map<String, double> _unitCoef = {};
  String _stockBase = '';

  String _checker = '';
  bool _dialogOpen = false;
  _Filter _filter = _Filter.all;

  /// Scan field on top: always focused, so keyboard-wedge scanners that type
  /// through the input method (not as key events) reach the app.
  final TextEditingController _scanCtrl = TextEditingController();
  final FocusNode _scanFocus = FocusNode();
  Timer? _scanTimer;
  bool _keyboard = false; // soft keyboard for manual input
  String _lastScan = '';

  /// true: every scan opens the quantity dialog; false: added at once.
  bool _askQty = true;

  @override
  void initState() {
    super.initState();
    _scanFocus.addListener(() {
      if (!_scanFocus.hasFocus) _refocus();
    });
    _load();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
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

  String _url(String path) => path.isEmpty || _stockBase.isEmpty ? '' : '$_stockBase$path';

  // ── loading (local only) ──

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = _Store.read(prefs, 'tsd_settings') ?? {};
      _askQty = prefs.getBool('tsd_ask_qty') ?? true;
      _checker = (widget.checkerName?.isNotEmpty ?? false)
          ? widget.checkerName!
          : (settings['checkerName'] ?? '').toString();
      _stockBase = await _Catalog.base();

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
      // photos (and names, if 1C data is missing) from the catalog
      final cat = await _Catalog.byIds(keys);
      for (final it in _items) {
        final c = cat[it.productKey];
        if (c == null) continue;
        it.thumb = (c['thumb'] ?? '').toString();
        it.image = (c['image'] ?? '').toString();
        if (it.name.length <= 8) it.name = (c['name'] ?? it.name).toString();
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
    for (final f in ((m['foreign'] as List?) ?? const [])) {
      final it = _Item(f['p'], f['c'], f['n'], inDoc: false)
        ..fact = _num(f['f'])
        ..thumb = (f['t'] ?? '').toString();
      _items.add(it);
      _byKey[it.key] = it;
    }
    (m['facts'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _byKey[k]?.fact = _num(v));
  }

  Future<void> _saveProgress() async {
    _doc['progress'] = {
      'facts': {for (final i in _items) if (i.fact != 0) i.key: i.fact},
      'foreign': [
        for (final i in _items.where((i) => !i.inDoc))
          {'p': i.productKey, 'c': i.charKey, 'n': i.name, 'f': i.fact, 't': i.thumb}
      ],
    };
    _doc['status'] = 'work'; // any change after «Готово» needs «Готово» again
    _doc.remove('result');
    _doc.remove('error');
    await _Store.putDoc(await SharedPreferences.getInstance(), _doc);
  }

  // ── scanning ──

  void _submitScan() {
    _scanTimer?.cancel();
    final code = _scanCtrl.text.trim();
    _scanCtrl.clear();
    if (code.isNotEmpty) _onScan(code);
    _refocus();
  }

  /// Enter from a keyboard-wedge scanner can arrive before the last character
  /// reaches the field (the code was read without its last digit, and the digit
  /// stuck to the next scan). Wait a moment so the field has the whole code.
  void _onScanEnter() {
    _scanTimer?.cancel();
    _scanTimer = Timer(_enterSettle, _submitScan);
  }

  /// Scanners without an Enter suffix: accept the code 300 ms after the last char.
  void _onScanChanged(String v) {
    _scanTimer?.cancel();
    if (_keyboard) return;
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
    final hit = _barcodes[code] ?? (await _others())[code];
    final cat = hit == null || !_byKey.containsKey('${hit[0]}|${hit[1]}') ? await _Catalog.byBarcode(code) : null;

    String key, productKey, charKey, name;
    String thumb = '', image = '';
    double step = 1;
    if (hit != null) {
      productKey = hit[0];
      charKey = hit[1];
      key = '${hit[0]}|${hit[1]}';
      step = _unitCoef[hit[2]] ?? 1;
      name = _byKey[key]?.name ?? _otherNames[hit[0]] ?? (cat?['name'] ?? 'Товар не из документа').toString();
    } else if (cat != null) {
      // known only in the catalog (Stock API): not in this document
      productKey = cat['id'].toString();
      charKey = _zeroGuid;
      key = '$productKey|$charKey';
      name = (cat['name'] ?? '').toString();
    } else {
      productKey = '?';
      charKey = code;
      key = '?|$code';
      name = 'Неизвестный штрихкод $code';
    }
    final existing = _byKey[key] ?? _byKey['$productKey|$_zeroGuid'];
    if (existing != null) {
      thumb = existing.thumb;
      image = existing.image;
    } else if (cat != null) {
      thumb = (cat['thumb'] ?? '').toString();
      image = (cat['image'] ?? '').toString();
    }
    final inDoc = existing?.inDoc ?? false;

    String? next;
    double qty = step;
    if (_askQty) {
      final r = await _qtyDialog(existing, name, inDoc, step, image.isNotEmpty ? image : thumb, cat?['article']);
      if (r == null) return;
      qty = r.qty;
      next = r.nextCode;
    }

    if (qty > 0) {
      var it = existing;
      if (it == null) {
        it = _Item(productKey, charKey, name, inDoc: false)
          ..thumb = thumb
          ..image = image
          ..article = (cat?['article'] ?? '').toString();
        _items.add(it);
        _byKey[it.key] = it;
      }
      it.fact += qty;
      final st = _status(it);
      if (st == _St.foreign || st == _St.excess) {
        _alarm(st == _St.foreign ? 'Нет в документе: ${it.name}' : 'Больше плана: ${it.name}');
      } else {
        HapticFeedback.lightImpact();
      }
      setState(() {});
      await _saveProgress();
    }
    if (next != null) await _onScan(next);
  }

  Future<_QtyResult?> _qtyDialog(
      _Item? it, String name, bool inDoc, double step, String photo, dynamic article) async {
    final ctrl = TextEditingController(text: _fmt(step));
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
    _dialogOpen = true;
    if (!inDoc) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    }

    _QtyResult? parse(String raw) {
      final t = raw.trim();
      if (t.length >= 8 && RegExp(r'^\d+$').hasMatch(t)) return _QtyResult(step, t); // next barcode
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
        void submitLater() => Future.delayed(_enterSettle, () {
              if (ctx.mounted) submit();
            });

        final art = (it?.article.isNotEmpty ?? false) ? it!.article : (article ?? '').toString();
        return AlertDialog(
          backgroundColor: inDoc ? null : const Color(0xFFFFEBEE),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!inDoc)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(8)),
                  child: const Text('НЕТ В ЭТОМ ДОКУМЕНТЕ',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              if (photo.isNotEmpty)
                Center(child: _Photo(url: _url(photo), size: 140, radius: 12)),
              const SizedBox(height: 8),
              Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              if (art.isNotEmpty) Text('арт. $art', style: const TextStyle(color: Colors.black54)),
              if (it != null && it.inDoc) ...[
                const SizedBox(height: 8),
                Row(children: [
                  _chip('План', _fmt(it.plan), Colors.blueGrey),
                  const SizedBox(width: 8),
                  _chip('Собрано', _fmt(it.fact), _stColor[_status(it)]!),
                ]),
              ],
              if (step > 1)
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
                    decoration: const InputDecoration(
                        labelText: 'Количество', border: OutlineInputBorder(), isDense: true),
                    onSubmitted: (_) => submitLater(),
                  ),
                ),
                const SizedBox(width: 8),
                _roundBtn(Icons.add, () => bump(1)),
              ]),
              const SizedBox(height: 4),
              const Text('Enter — добавить. Следующий скан добавит этот товар сам.',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
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
    _refocus();
    ctrl.dispose();
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
    SystemSound.play(SystemSoundType.alert);
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
    final r = await _qtyDialog(it, it.name, it.inDoc, it.fact, it.image.isNotEmpty ? it.image : it.thumb, null);
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
    _refocus();
    return res == true;
  }

  // ── finish: result for 1C, stored on the TSD ──

  Future<void> _finish() async {
    final foreign = _items.where((i) => _status(i) == _St.foreign).toList();
    if (foreign.isNotEmpty) {
      setState(() => _filter = _Filter.issues);
      _alarm('Уберите товар не из документа (тап → 0): ${foreign.map((i) => i.name).join(', ')}');
      return;
    }

    final shorts = <String>[], excess = <String>[];
    for (final i in _items.where((i) => i.inDoc)) {
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
    for (final it in _items.where((i) => i.inDoc)) {
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
    _items.removeWhere((i) => !i.inDoc);
    _byKey.removeWhere((k, i) => !i.inDoc);
    for (final i in _items) {
      i.fact = 0;
    }
    setState(() {});
    await _saveProgress();
  }

  // ── UI ──

  int _rank(_St s) => const [_St.foreign, _St.excess, _St.short, _St.pending, _St.ok].indexOf(s);

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
      final inDocItems = _items.where((i) => i.inDoc).toList();
      final done = inDocItems.where((i) => _status(i) == _St.ok).length;
      final left = _items.where((i) => _status(i) == _St.pending || _status(i) == _St.short).length;
      final issues = _items.where((i) {
        final s = _status(i);
        return s == _St.excess || s == _St.foreign || s == _St.short;
      }).length;
      final shown = _items.where((i) {
        final s = _status(i);
        switch (_filter) {
          case _Filter.all:
            return true;
          case _Filter.left:
            return s == _St.pending || s == _St.short;
          case _Filter.issues:
            return s == _St.excess || s == _St.foreign || s == _St.short;
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
            keyboardType: _keyboard ? TextInputType.text : TextInputType.none,
            textInputAction: TextInputAction.done,
            onChanged: _onScanChanged,
            onSubmitted: (_) => _onScanEnter(),
            onEditingComplete: () {},
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF1F3F4),
              hintText: _lastScan.isEmpty ? 'Сканируйте товар' : 'Последний: $_lastScan',
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
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            _filterChip(_Filter.all, 'Все ${_items.length}'),
            _filterChip(_Filter.left, 'Осталось $left'),
            _filterChip(_Filter.issues, 'Расхождения $issues', danger: issues > 0),
          ]),
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

  Widget _filterChip(_Filter f, String label, {bool danger = false}) => ChoiceChip(
        label: Text(label, style: TextStyle(color: danger && _filter != f ? Colors.red.shade700 : null)),
        selected: _filter == f,
        showCheckmark: false,
        onSelected: (_) => setState(() => _filter = f),
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
            Padding(
              padding: const EdgeInsets.all(8),
              child: _Photo(url: _url(it.thumb), size: 52, radius: 8),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
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
                if (it.inDoc) Text('из ${_fmt(it.plan)}', style: const TextStyle(fontSize: 13, color: Colors.black54)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Product photo from Stock API, cached on disk; placeholder without photo / network.
class _Photo extends StatelessWidget {
  const _Photo({required this.url, required this.size, this.radius = 8});
  final String url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: const Color(0xFFEEEEEE),
      child: Icon(Icons.inventory_2_outlined, size: size * 0.45, color: Colors.black26),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => placeholder,
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
