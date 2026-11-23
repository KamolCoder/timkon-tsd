// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import '/custom_code/actions/index.dart'; // Imports custom actions
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Offline check of one «Перемещение товаров» downloaded by TransferListWidget.
/// No network here: the document, names, units and barcodes are on the TSD.
///
/// Scanner: keyboard-wedge mode (code + Enter). A block barcode (unit with
/// Коэффициент > 1) adds the whole block.
/// Line rule: rounded = ceil(plan / k) * k; plan < fact <= rounded and
/// fact % k == 0 is OK (rounded up to the block).
/// «Готово» stores the result on the TSD (status «checked»); TransferListWidget
/// sends it to 1C. Posting stays manual in 1C.
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

  static Future<void> putProd(SharedPreferences p, String key, Map<String, dynamic> e) =>
      p.setString('$prodPrefix$key', jsonEncode(e));
}

// ───────────────────────────── model ─────────────────────────────

const _zeroGuid = '00000000-0000-0000-0000-000000000000';

enum _St { pending, ok, block, short, excess, askBlock, foreign }

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

bool _isMultiple(double v, double k) {
  final q = v / k;
  return (q - q.round()).abs() < 1e-6;
}

/// The agreed rule, k = block size (null = unknown).
_St _status(_Item it, double? k) {
  final plan = it.plan, fact = it.fact;
  if (!it.inDoc) return fact > 0 ? _St.foreign : _St.pending;
  if (fact == 0) return _St.pending;
  if ((fact - plan).abs() < 1e-6) return _St.ok;
  if (fact < plan) return _St.short;
  if (it.weight) return _St.excess;
  if (k == null || k <= 1) return _St.askBlock;
  final rounded = (plan / k).ceil() * k;
  if (fact <= rounded + 1e-6 && _isMultiple(fact, k)) return _St.block;
  return _St.excess;
}

// ───────────────────────────── state ─────────────────────────────

class _TransferCheckWidgetState extends State<TransferCheckWidget> {
  bool _loading = true;
  String? _error;

  Map<String, dynamic> _doc = {};
  final List<_Item> _items = [];
  final Map<String, _Item> _byKey = {};

  /// barcode → (productKey, charKey, unitKey); goods of this document
  final Map<String, List<String>> _barcodes = {};

  /// barcodes / names of goods of all documents on the TSD (to name a resort)
  Map<String, List<String>>? _otherCodes;
  final Map<String, String> _otherNames = {};

  final Map<String, double> _unitCoef = {};
  final Map<String, double> _blocks = {};
  final Map<String, String> _baseUnit = {};
  final Map<String, String> _unitClassifier = {};

  String _checker = '';
  final StringBuffer _scanBuf = StringBuffer();
  bool _dialogOpen = false;
  String _lastScan = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _load();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  // ── loading (local only) ──

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = _Store.read(prefs, 'tsd_settings') ?? {};
      _checker = (widget.checkerName?.isNotEmpty ?? false)
          ? widget.checkerName!
          : (settings['checkerName'] ?? '').toString();

      final doc = _Store.doc(prefs, widget.transferKey);
      if (doc == null) throw 'Документа нет на ТСД. Нажмите «Загрузить» в списке.';
      if (doc['status'] == 'conflict') throw 'Конфликт: ${doc['error'] ?? ''}';
      _doc = doc;

      for (final row in ((doc['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final p = (row['Номенклатура_Key'] ?? _zeroGuid).toString();
        final c = (row['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString();
        final it = _byKey.putIfAbsent('$p|$c', () {
          final n = _Item(p, c, p.length >= 8 ? p.substring(0, 8) : p);
          _items.add(n);
          return n;
        });
        it.lines.add(_DocLine(row));
      }
      for (final p in _items.map((e) => e.productKey).toSet()) {
        final e = _Store.prod(prefs, p);
        if (e != null) _apply(p, e);
      }
      _restoreProgress();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _apply(String productKey, Map<String, dynamic> e) {
    _baseUnit[productKey] = (e['base'] ?? _zeroGuid).toString();
    for (final it in _items.where((i) => i.productKey == productKey)) {
      it.name = (e['name'] ?? it.name).toString();
      it.article = (e['article'] ?? '').toString();
      it.weight = e['weight'] == true;
    }
    for (final u in (e['units'] as List? ?? const [])) {
      final ref = u[0].toString();
      final coef = _num(u[1]);
      _unitCoef[ref] = coef <= 0 ? 1 : coef;
      _unitClassifier[ref] = u[2].toString();
      if (u[3] != true && coef > 1) _blocks[productKey] = math.max(_blocks[productKey] ?? 0, coef);
    }
    for (final c in (e['codes'] as List? ?? const [])) {
      _barcodes[c[0].toString()] = [productKey, c[1].toString(), c[2].toString()];
    }
  }

  /// Barcodes of goods of the other downloaded documents (built on first need).
  Future<Map<String, List<String>>> _others() async {
    if (_otherCodes != null) return _otherCodes!;
    final prefs = await SharedPreferences.getInstance();
    final map = <String, List<String>>{};
    for (final k in prefs.getKeys().where((k) => k.startsWith(_Store.prodPrefix))) {
      final e = _Store.read(prefs, k);
      if (e == null) continue;
      final p = k.substring(_Store.prodPrefix.length);
      _otherNames[p] = (e['name'] ?? '').toString();
      for (final u in (e['units'] as List? ?? const [])) {
        _unitCoef.putIfAbsent(u[0].toString(), () => math.max(1.0, _num(u[1])));
      }
      for (final c in (e['codes'] as List? ?? const [])) {
        map[c[0].toString()] = [p, c[1].toString(), c[2].toString()];
      }
    }
    return _otherCodes = map;
  }

  // ── progress on the TSD ──

  void _restoreProgress() {
    final m = _doc['progress'] as Map<String, dynamic>?;
    if (m == null) return;
    for (final f in ((m['foreign'] as List?) ?? const [])) {
      final it = _Item(f['p'], f['c'], f['n'], inDoc: false)..fact = _num(f['f']);
      _items.add(it);
      _byKey[it.key] = it;
    }
    (m['facts'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _byKey[k]?.fact = _num(v));
    (m['blocks'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _blocks[k] = _num(v));
  }

  Future<void> _saveProgress() async {
    _doc['progress'] = {
      'facts': {for (final i in _items) if (i.fact != 0) i.key: i.fact},
      'foreign': [
        for (final i in _items.where((i) => !i.inDoc)) {'p': i.productKey, 'c': i.charKey, 'n': i.name, 'f': i.fact}
      ],
      'blocks': _blocks,
    };
    // Any change after «Готово» needs «Готово» again.
    _doc['status'] = 'work';
    _doc.remove('result');
    _doc.remove('error');
    await _Store.putDoc(await SharedPreferences.getInstance(), _doc);
  }

  // ── scanning ──

  bool _onKey(KeyEvent e) {
    if (_dialogOpen || _loading || _error != null || e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _scanBuf.toString().trim();
      _scanBuf.clear();
      if (code.isNotEmpty) _onScan(code);
      return true;
    }
    final ch = e.character;
    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _scanBuf.write(ch);
      return true;
    }
    return false;
  }

  Future<void> _onScan(String code) async {
    _lastScan = code;
    var hit = _barcodes[code] ?? (await _others())[code];

    _Item? it;
    double qty = 1;
    if (hit == null) {
      // Unknown on the TSD: count it as a resort line by the barcode itself.
      it = _byKey['?|$code'];
      if (it == null) {
        it = _Item('?', code, 'Неизвестный штрихкод $code', inDoc: false);
        _items.add(it);
        _byKey[it.key] = it;
      }
    } else {
      qty = _unitCoef[hit[2]] ?? 1;
      it = _byKey['${hit[0]}|${hit[1]}'];
      if (it == null) {
        it = _Item(hit[0], hit[1], _otherNames[hit[0]] ?? 'Товар не из документа', inDoc: false);
        _items.add(it);
        _byKey[it.key] = it;
      }
    }
    it.fact += qty;

    final st = _status(it, _blocks[it.productKey]);
    if (st == _St.foreign || st == _St.excess) {
      _alarm(st == _St.foreign ? 'Нет в документе: ${it.name}' : 'Лишнее: ${it.name}');
    } else {
      HapticFeedback.lightImpact();
    }
    setState(() {});
    await _saveProgress();
  }

  void _alarm(String msg) {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
    setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── dialogs ──

  Future<double?> _askNumber(String title, String hint, double initial) async {
    final ctrl = TextEditingController(text: initial == 0 ? '' : _fmt(initial));
    _dialogOpen = true;
    final res = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.replaceAll(',', '.'))),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    return res;
  }

  Future<void> _editFact(_Item it) async {
    final v = await _askNumber(it.name, 'Фактическое количество', it.fact);
    if (v == null || v < 0) return;
    setState(() => it.fact = v);
    await _saveProgress();
  }

  /// fact > plan, block size unknown: «is it a block? how many in it?»
  /// Applied at once on the TSD; the unit «блок N» goes to 1C with the document.
  Future<void> _askBlock(_Item it) async {
    final k = await _askNumber('Округление до блока?\n${it.name}', 'Штук в блоке (0 — это лишнее)', 0);
    if (k == null || k <= 1) return;
    setState(() => _blocks[it.productKey] = k);

    final cls = _unitClassifier[_baseUnit[it.productKey] ?? _zeroGuid] ?? _zeroGuid;
    final units = ((_doc['units'] as List?) ?? <dynamic>[])
      ..removeWhere((u) => u is Map && u['Owner_Key'] == it.productKey);
    units.add({
      'Owner_Key': it.productKey,
      'Description': 'блок ${_fmt(k)}',
      'Коэффициент': k,
      'ЕдиницаИзмеренияПоКлассификатору_Key': cls,
    });
    _doc['units'] = units;

    // Other documents on the TSD learn the block too.
    final prefs = await SharedPreferences.getInstance();
    final e = _Store.prod(prefs, it.productKey);
    if (e != null) {
      (e['units'] as List).add(['local', k, cls, false]);
      await _Store.putProd(prefs, it.productKey, e);
    }
    await _saveProgress();
    _toast('Блок ${_fmt(k)} шт учтён');
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
    return res == true;
  }

  // ── finish: result for 1C, stored on the TSD ──

  Future<void> _finish() async {
    final blocking = _items.where((i) {
      final s = _status(i, _blocks[i.productKey]);
      return s == _St.excess || s == _St.askBlock || s == _St.foreign;
    }).toList();
    if (blocking.isNotEmpty) {
      _alarm('Уберите лишнее / пересорт: ${blocking.map((i) => i.name).join(', ')}');
      return;
    }

    final rounded = <String>[], shorts = <String>[];
    for (final i in _items.where((i) => i.inDoc)) {
      final s = _status(i, _blocks[i.productKey]);
      if (s == _St.block) rounded.add('${i.name} ${_fmt(i.plan)}→${_fmt(i.fact)}');
      if (s == _St.short || s == _St.pending) shorts.add('${i.name} ${_fmt(i.plan)}→${_fmt(i.fact)}');
    }
    if (shorts.isNotEmpty && !await _confirm('Завершить с недостачей?', shorts.join('\n'), 'Завершить')) return;

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
    final log = StringBuffer('Проверено ТСД: ${_checker.isEmpty ? 'ТСД' : _checker} '
        '${two(now.day)}.${two(now.month)} ${two(now.hour)}:${two(now.minute)}');
    if (rounded.isNotEmpty) log.write('; округлено: ${rounded.join(', ')}');
    if (shorts.isNotEmpty) log.write('; недостача: ${shorts.join(', ')}');

    await _saveProgress();
    _doc['result'] = {'rows': rows, 'log': log.toString()};
    _doc['status'] = 'checked';
    _doc['checkedAt'] = now.toIso8601String();
    await _Store.putDoc(await SharedPreferences.getInstance(), _doc);

    _toast('Проверено. Документ будет отправлен в 1С.');
    if (widget.onSaved != null) {
      await widget.onSaved!();
    } else if (mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _reset() async {
    if (!await _confirm('Сбросить проверку?', 'Все отсканированные количества будут обнулены.', 'Сбросить')) return;
    _items.removeWhere((i) => !i.inDoc);
    _byKey.removeWhere((k, i) => !i.inDoc);
    for (final i in _items) {
      i.fact = 0;
    }
    setState(() {});
    await _saveProgress();
  }

  // ── UI ──

  static const _colors = {
    _St.pending: Color(0xFFEEEEEE),
    _St.ok: Color(0xFFC8E6C9),
    _St.block: Color(0xFFDCEDC8),
    _St.short: Color(0xFFFFF59D),
    _St.excess: Color(0xFFFFCDD2),
    _St.askBlock: Color(0xFFFFE0B2),
    _St.foreign: Color(0xFFFFCDD2),
  };

  static const _labels = {
    _St.pending: 'не собрано',
    _St.ok: 'совпало',
    _St.block: 'блок',
    _St.short: 'недостача',
    _St.excess: 'лишнее',
    _St.askBlock: 'больше заказа — блок?',
    _St.foreign: 'нет в документе',
  };

  int _rank(_St s) =>
      const [_St.foreign, _St.excess, _St.askBlock, _St.short, _St.pending, _St.block, _St.ok].indexOf(s);

  Future<void> _manualCode() async {
    final ctrl = TextEditingController();
    _dialogOpen = true;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Штрихкод'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    _dialogOpen = false;
    if (code != null && code.isNotEmpty) await _onScan(code);
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Назад')),
          ]),
        ),
      );
    } else {
      final sorted = [..._items]..sort((a, b) =>
          _rank(_status(a, _blocks[a.productKey])).compareTo(_rank(_status(b, _blocks[b.productKey]))));
      final done = _items.where((i) {
        final s = _status(i, _blocks[i.productKey]);
        return s == _St.ok || s == _St.block;
      }).length;
      final inDoc = _items.where((i) => i.inDoc).length;
      final checked = _doc['status'] == 'checked';

      body = Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Row(children: [
            IconButton(
                tooltip: 'Назад', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(
                '№ ${_doc['number'] ?? ''} · ${_doc['receiver'] ?? ''}\nсобрано $done из $inDoc'
                '${_lastScan.isEmpty ? '' : ' · скан: $_lastScan'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(tooltip: 'Ввести штрихкод', icon: const Icon(Icons.keyboard), onPressed: _manualCode),
            IconButton(tooltip: 'Сбросить проверку', icon: const Icon(Icons.restart_alt), onPressed: _reset),
          ]),
        ),
        if (checked)
          Container(
            width: double.infinity,
            color: const Color(0xFFC8E6C9),
            padding: const EdgeInsets.all(8),
            child: const Text('Проверен, ждёт отправки в 1С. Любое изменение — снова «Готово».'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: sorted.length,
            itemBuilder: (ctx, i) {
              final it = sorted[i];
              final k = _blocks[it.productKey];
              final st = _status(it, k);
              return Card(
                color: _colors[st],
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: ListTile(
                  dense: true,
                  onTap: () => _editFact(it),
                  title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    if (it.article.isNotEmpty) 'арт. ${it.article}',
                    if (k != null && k > 1) 'блок ${_fmt(k)}',
                    _labels[st]!,
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (st == _St.askBlock) TextButton(onPressed: () => _askBlock(it), child: const Text('Блок?')),
                    Text('${_fmt(it.fact)} / ${_fmt(it.plan)}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: _finish,
              icon: const Icon(Icons.check_circle),
              label: const Text('Готово'),
            ),
          ),
        ),
      ]);
    }
    return SizedBox(
        width: widget.width, height: widget.height, child: _EdgeSwipeBack(child: SafeArea(child: body)));
  }
}

/// Swipe from the left edge → back (Navigator.maybePop). Works on any Android,
/// also on TSDs with button navigation where the system back gesture is absent.
/// Taps and vertical scrolling pass through to the content.
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
