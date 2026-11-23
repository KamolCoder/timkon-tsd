// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import '/custom_code/actions/index.dart'; // Imports custom actions
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// TSD check of one «Перемещение товаров» (unposted) against what was picked.
///
/// Scanner: keyboard-wedge mode (scanner types the code + Enter). A block
/// barcode (unit with Коэффициент > 1) adds the whole block.
/// Line rule: rounded = ceil(plan / k) * k; plan < fact <= rounded and
/// fact % k == 0 is OK (rounded up to the block).
/// Save: writes the actual quantities into Товары + a log in Комментарий.
/// The document is NOT posted — the storekeeper posts it in 1C.
///
/// Connection settings come from TsdSettingsWidget (SharedPreferences
/// `tsd_settings`); non-empty parameters override them.
class TransferCheckWidget extends StatefulWidget {
  const TransferCheckWidget({
    super.key,
    this.width,
    this.height,
    required this.transferKey,
    this.baseUrl,
    this.username,
    this.password,
    this.checkerName,
    this.onSaved,
  });

  final double? width;
  final double? height;

  /// Ref_Key of Document_ПеремещениеТоваров
  final String transferKey;

  /// Optional overrides of the saved settings, e.g. http://192.168.1.10/tbase
  final String? baseUrl;
  final String? username;
  final String? password;

  /// Who checks — goes to the 1C comment
  final String? checkerName;

  /// After a successful save. Default: go back to the list (Navigator.maybePop).
  final Future Function()? onSaved;

  @override
  State<TransferCheckWidget> createState() => _TransferCheckWidgetState();
}

// ───────────────────────────── 1C OData client ─────────────────────────────

class _OData {
  _OData(String baseUrl, String user, String pass)
      : root = '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/odata/standard.odata',
        auth = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  final String root;
  final String auth;

  Uri _uri(String path, Map<String, String> params) {
    final q = {r'$format': 'json', ...params}
        .entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return Uri.parse('$root/$path?$q');
  }

  static String entity(String name, [String? guid]) =>
      guid == null ? Uri.encodeComponent(name) : "${Uri.encodeComponent(name)}(guid'$guid')";

  Map<String, String> get _headers => {
        'Authorization': auth,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response r;
    try {
      r = await call().timeout(const Duration(seconds: 30));
    } catch (e) {
      throw 'Нет связи с 1С: $e';
    }
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode == 401) throw '1С: неверный логин или пароль';
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw '1С: HTTP ${r.statusCode} ${_odataError(body)}';
    }
    return body.isEmpty ? null : jsonDecode(body);
  }

  static String _odataError(String body) {
    try {
      final m = jsonDecode(body);
      final msg = m['odata.error']?['message']?['value'];
      if (msg != null) return msg.toString();
    } catch (_) {}
    // IIS / Apache HTML error page → just its title
    final title = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body)?.group(1);
    if (title != null) return title.trim();
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  Future<Map<String, dynamic>> getOne(String path, [Map<String, String> params = const {}]) async =>
      (await _send(() => http.get(_uri(path, params), headers: _headers))) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> getList(String path, Map<String, String> params) async {
    final m = await getOne(path, params);
    return ((m['value'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// IIS rejects query strings over 2048 chars by default (HTTP 404.15), and
  /// Cyrillic names grow ×6 when URL-encoded, so chunks are sized by the
  /// encoded length of the whole query, not by a fixed number of keys.
  static const _maxQuery = 1900;

  /// GET with an `or`-chain over many GUIDs, in chunks that fit the URL limit.
  Future<List<Map<String, dynamic>>> getByKeys(
      String name, String field, Iterable<String> keys, String select) async {
    final all = keys.where((k) => k.isNotEmpty).toSet().toList();
    final out = <Map<String, dynamic>>[];
    final fixed = Uri.encodeComponent(select).length + 60; // $format, $select, separators
    var i = 0;
    while (i < all.length) {
      final part = <String>[];
      var len = fixed;
      while (i < all.length) {
        final term = "${part.isEmpty ? '' : ' or '}$field eq guid'${all[i]}'";
        final add = Uri.encodeComponent(term).length;
        if (part.isNotEmpty && len + add > _maxQuery) break;
        part.add(all[i]);
        len += add;
        i++;
      }
      out.addAll(await getList(entity(name), {
        r'$filter': part.map((k) => "$field eq guid'$k'").join(' or '),
        r'$select': select,
      }));
    }
    return out;
  }

  Future<dynamic> patch(String path, Map<String, dynamic> body) =>
      _send(() => http.patch(_uri(path, const {}), headers: _headers, body: jsonEncode(body)));

  Future<dynamic> post(String path, Map<String, dynamic> body) =>
      _send(() => http.post(_uri(path, const {}), headers: _headers, body: jsonEncode(body)));
}

// ───────────────────────────── local cache ─────────────────────────────

/// Per-product cache on the TSD: name, units, barcodes. TTL 24 h, so the next
/// document with the same goods opens without asking 1C. A stale entry is
/// harmless: unknown barcodes / units are always checked online, «Обновить»
/// bypasses the cache.
/// Entry: {name, article, weight, base, units: [[ref, coef, classifier, deleted]],
///         codes: [[barcode, charKey, unitKey]], ts}
class _Cache {
  static const ttl = Duration(hours: 24);
  static const _prefix = 'tsdc_p_';

  static Map<String, dynamic>? get(SharedPreferences prefs, String productKey) {
    final s = prefs.getString('$_prefix$productKey');
    if (s == null) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      final ts = DateTime.fromMillisecondsSinceEpoch((m['ts'] as num).toInt());
      return DateTime.now().difference(ts) > ttl ? null : m;
    } catch (_) {
      return null;
    }
  }

  static Future<void> put(SharedPreferences prefs, String productKey, Map<String, dynamic> m) {
    m['ts'] = DateTime.now().millisecondsSinceEpoch;
    return prefs.setString('$_prefix$productKey', jsonEncode(m));
  }

  /// Drop entries older than a week so the cache does not grow forever.
  static Future<void> cleanup(SharedPreferences prefs) async {
    final border = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    for (final k in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      try {
        final ts = (jsonDecode(prefs.getString(k) ?? '{}')['ts'] as num?)?.toInt() ?? 0;
        if (ts < border) await prefs.remove(k);
      } catch (_) {
        await prefs.remove(k);
      }
    }
  }
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
  _OData _od = _OData('', '', '');
  String _checker = '';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  Map<String, dynamic> _doc = {};
  final List<_Item> _items = [];
  final Map<String, _Item> _byKey = {};

  /// barcode → (productKey, charKey, unitKey)
  final Map<String, List<String>> _barcodes = {};

  /// unitKey → Коэффициент
  final Map<String, double> _unitCoef = {};

  /// productKey → block size (from 1C units or entered here)
  final Map<String, double> _blocks = {};

  /// productKey → base unit key (to copy the classifier when creating «блок»)
  final Map<String, String> _baseUnit = {};
  final Map<String, String> _unitClassifier = {};

  /// productKey → cache entry (see _Cache)
  final Map<String, Map<String, dynamic>> _entries = {};

  final StringBuffer _scanBuf = StringBuffer();
  bool _dialogOpen = false;
  String _lastScan = '';

  String get _prefsKey => 'tsdcheck_${widget.transferKey}';

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

  // ── loading ──

  /// [force] — ignore the local cache (the «Обновить» button).
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _items.clear();
      _byKey.clear();
      _barcodes.clear();
      _unitCoef.clear();
      _blocks.clear();
      _entries.clear();

      await _readSettings();
      _doc = await _od.getOne(_OData.entity('Document_ПеремещениеТоваров', widget.transferKey),
          {r'$select': 'Number,Posted,DataVersion,Комментарий,Товары'});
      if (_doc['Posted'] == true) throw 'Документ уже проведён — проверка недоступна';

      for (final row in ((_doc['Товары'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final p = (row['Номенклатура_Key'] ?? _zeroGuid).toString();
        final c = (row['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString();
        final it = _byKey.putIfAbsent('$p|$c', () {
          final n = _Item(p, c, p.substring(0, 8));
          _items.add(n);
          return n;
        });
        it.lines.add(_DocLine(row));
      }
      final productKeys = _items.map((e) => e.productKey).toSet();

      final prefs = await SharedPreferences.getInstance();
      final missing = <String>[];
      for (final p in productKeys) {
        final e = force ? null : _Cache.get(prefs, p);
        if (e == null) {
          missing.add(p);
        } else {
          _entries[p] = e;
        }
      }
      if (missing.isNotEmpty) await _fetchProducts(prefs, missing);
      _entries.forEach(_apply);

      await _restoreProgress();
      unawaited(_Cache.cleanup(prefs));
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _readSettings() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> m = {};
    try {
      m = jsonDecode(prefs.getString('tsd_settings') ?? '{}') as Map<String, dynamic>;
    } catch (_) {}
    String pick(String? param, String key) =>
        (param != null && param.isNotEmpty) ? param : (m[key] ?? '').toString();
    final url = pick(widget.baseUrl, 'baseUrl');
    if (url.trim().isEmpty) throw 'Не заданы настройки подключения к 1С';
    _od = _OData(url, pick(widget.username, 'username'), pick(widget.password, 'password'));
    _checker = pick(widget.checkerName, 'checkerName');
  }

  /// Names, units and barcodes from 1C only for products missing in the cache.
  Future<void> _fetchProducts(SharedPreferences prefs, List<String> keys) async {
    final fresh = {
      for (final p in keys)
        p: <String, dynamic>{
          'name': p.substring(0, 8),
          'article': '',
          'weight': false,
          'base': _zeroGuid,
          'units': <dynamic>[],
          'codes': <dynamic>[],
        }
    };

    for (final p in await _od.getByKeys('Catalog_Номенклатура', 'Ref_Key', keys,
        'Ref_Key,Description,Артикул,Весовой,ЕдиницаИзмерения_Key')) {
      final e = fresh[p['Ref_Key'].toString()];
      if (e == null) continue;
      e['name'] = (p['Description'] ?? '').toString();
      e['article'] = (p['Артикул'] ?? '').toString();
      e['weight'] = p['Весовой'] == true;
      e['base'] = (p['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString();
    }

    for (final u in await _od.getByKeys('Catalog_ЕдиницыИзмерения', 'Owner_Key', keys,
        'Ref_Key,Owner_Key,Коэффициент,DeletionMark,ЕдиницаИзмеренияПоКлассификатору_Key')) {
      (fresh[u['Owner_Key'].toString()]?['units'] as List?)?.add([
        u['Ref_Key'].toString(),
        _num(u['Коэффициент']),
        (u['ЕдиницаИзмеренияПоКлассификатору_Key'] ?? _zeroGuid).toString(),
        u['DeletionMark'] == true,
      ]);
    }

    for (final b in await _od.getByKeys('InformationRegister_ШтрихкодыНоменклатуры', 'Номенклатура_Key', keys,
        'Штрихкод,Номенклатура_Key,ХарактеристикаНоменклатуры_Key,ЕдиницаИзмерения_Key,НеИспользуется')) {
      if (b['НеИспользуется'] == true) continue;
      (fresh[b['Номенклатура_Key'].toString()]?['codes'] as List?)?.add([
        b['Штрихкод'].toString().trim(),
        (b['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString(),
        (b['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString(),
      ]);
    }

    for (final e in fresh.entries) {
      _entries[e.key] = e.value;
      await _Cache.put(prefs, e.key, e.value);
    }
  }

  /// Cache entry → in-memory maps.
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
      if (u[3] != true && coef > 1) {
        _blocks[productKey] = math.max(_blocks[productKey] ?? 0, coef);
      }
    }
    for (final c in (e['codes'] as List? ?? const [])) {
      _barcodes[c[0].toString()] = [productKey, c[1].toString(), c[2].toString()];
    }
  }

  // ── local progress (survives app restart / dead battery) ──

  Future<void> _saveProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey,
        jsonEncode({
          'facts': {for (final i in _items) if (i.fact != 0) i.key: i.fact},
          'foreign': [
            for (final i in _items.where((i) => !i.inDoc))
              {'p': i.productKey, 'c': i.charKey, 'n': i.name, 'f': i.fact}
          ],
          'blocks': _blocks,
        }));
  }

  Future<void> _restoreProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsKey);
    if (s == null) return;
    final m = jsonDecode(s) as Map<String, dynamic>;
    for (final f in ((m['foreign'] as List?) ?? const [])) {
      final it = _Item(f['p'], f['c'], f['n'], inDoc: false)..fact = _num(f['f']);
      _items.add(it);
      _byKey[it.key] = it;
    }
    (m['facts'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _byKey[k]?.fact = _num(v));
    (m['blocks'] as Map<String, dynamic>? ?? {}).forEach((k, v) => _blocks[k] = _num(v));
  }

  // ── scanning ──

  bool _onKey(KeyEvent e) {
    if (_dialogOpen || _loading || _saving || e is! KeyDownEvent) return false;
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
    var hit = _barcodes[code];
    if (hit == null) {
      // Not among the document's products: ask 1C who it is (resort / new barcode).
      try {
        final rows = await _od.getList(_OData.entity('InformationRegister_ШтрихкодыНоменклатуры'), {
          r'$filter': "Штрихкод eq '${code.replaceAll("'", "''")}'",
          r'$select': 'Номенклатура_Key,ХарактеристикаНоменклатуры_Key,ЕдиницаИзмерения_Key',
        });
        if (rows.isNotEmpty) {
          hit = [
            rows.first['Номенклатура_Key'].toString(),
            (rows.first['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString(),
            (rows.first['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString(),
          ];
          _barcodes[code] = hit;
        }
      } catch (e) {
        _alarm('Ошибка поиска штрихкода: $e');
        return;
      }
    }
    if (hit == null) {
      _alarm('Неизвестный штрихкод $code');
      return;
    }

    // Barcode of a unit we have not seen (created in 1C after caching) — ask its coefficient.
    if (hit[2] != _zeroGuid && !_unitCoef.containsKey(hit[2])) {
      try {
        final u = await _od.getOne(_OData.entity('Catalog_ЕдиницыИзмерения', hit[2]),
            {r'$select': 'Ref_Key,Коэффициент,DeletionMark,ЕдиницаИзмеренияПоКлассификатору_Key'});
        final coef = _num(u['Коэффициент']);
        _unitCoef[hit[2]] = coef <= 0 ? 1 : coef;
        final e = _entries[hit[0]];
        if (e != null) {
          (e['units'] as List).add(
              [hit[2], coef, (u['ЕдиницаИзмеренияПоКлассификатору_Key'] ?? _zeroGuid).toString(), u['DeletionMark'] == true]);
          if (coef > 1 && u['DeletionMark'] != true) {
            _blocks[hit[0]] = math.max(_blocks[hit[0]] ?? 0, coef);
          }
        }
      } catch (_) {
        _unitCoef[hit[2]] = 1;
      }
    }
    // A barcode found online for a product of this document: remember it in the cache.
    final entry = _entries[hit[0]];
    if (entry != null && !(entry['codes'] as List).any((c) => c[0] == code)) {
      (entry['codes'] as List).add([code, hit[1], hit[2]]);
      unawaited(SharedPreferences.getInstance().then((p) => _Cache.put(p, hit![0], entry)));
    }

    final qty = _unitCoef[hit[2]] ?? 1;
    var it = _byKey['${hit[0]}|${hit[1]}'];
    if (it == null) {
      var name = hit[0].substring(0, 8);
      try {
        final p = await _od.getOne(_OData.entity('Catalog_Номенклатура', hit[0]), {r'$select': 'Description'});
        name = (p['Description'] ?? name).toString();
      } catch (_) {}
      it = _Item(hit[0], hit[1], name, inDoc: false);
      _items.add(it);
      _byKey[it.key] = it;
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

  /// fact > plan and the block size is unknown: «is it a block? how many in it?»
  Future<void> _askBlock(_Item it) async {
    final k = await _askNumber('Округление до блока?\n${it.name}', 'Штук в блоке (0 — это лишнее)', 0);
    if (k == null || k <= 1) return;
    setState(() => _blocks[it.productKey] = k);
    await _saveProgress();
    // Remember in 1C as a unit «блок» of this product (like a package).
    try {
      final base = _baseUnit[it.productKey] ?? _zeroGuid;
      final cls = _unitClassifier[base] ?? _zeroGuid;
      final created = await _od.post(_OData.entity('Catalog_ЕдиницыИзмерения'), {
        'Owner_Key': it.productKey,
        'Description': 'блок ${_fmt(k)}',
        'Коэффициент': k,
        'ЕдиницаИзмеренияПоКлассификатору_Key': cls,
      });
      final ref = created is Map ? created['Ref_Key']?.toString() : null;
      final entry = _entries[it.productKey];
      if (ref != null && entry != null) {
        _unitCoef[ref] = k;
        (entry['units'] as List).add([ref, k, cls, false]);
        await _Cache.put(await SharedPreferences.getInstance(), it.productKey, entry);
      }
      _toast('Кратность ${_fmt(k)} сохранена в 1С');
    } catch (e) {
      _toast('Кратность учтена только в этой проверке: $e');
    }
  }

  Future<bool> _confirm(String title, String text) async {
    _dialogOpen = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отправить')),
        ],
      ),
    );
    _dialogOpen = false;
    return ok == true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── save to 1C ──

  Future<void> _save() async {
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
    if (shorts.isNotEmpty &&
        !await _confirm('Отправить с недостачей?', shorts.join('\n'))) {
      return;
    }

    setState(() => _saving = true);
    try {
      // Re-read: the document must still be unposted and unchanged since loading.
      final fresh = await _od.getOne(_OData.entity('Document_ПеремещениеТоваров', widget.transferKey),
          {r'$select': 'Posted,DataVersion,Комментарий'});
      if (fresh['Posted'] == true) throw 'Документ уже проведён в 1С';
      if (fresh['DataVersion'] != _doc['DataVersion']) {
        throw 'Документ изменён в 1С после загрузки — нажмите «Обновить» и проверьте заново';
      }

      final rows = <Map<String, dynamic>>[];
      for (final it in _items.where((i) => i.inDoc)) {
        var rest = it.fact;
        for (var n = 0; n < it.lines.length; n++) {
          final line = it.lines[n];
          final last = n == it.lines.length - 1;
          final qty = last ? rest : math.min(rest, line.plan);
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
      final oldComment = (fresh['Комментарий'] ?? '').toString().trim();

      await _od.patch(_OData.entity('Document_ПеремещениеТоваров', widget.transferKey), {
        'Товары': rows,
        'Комментарий': oldComment.isEmpty ? log.toString() : '$oldComment\n$log',
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
      _toast('Сохранено в 1С. Проведите документ в 1С.');
      if (widget.onSaved != null) {
        await widget.onSaved!();
      } else if (mounted) {
        await Navigator.of(context).maybePop();
      }
    } catch (e) {
      _alarm('$e');
    }
    if (mounted) setState(() => _saving = false);
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

  int _rank(_St s) => const [
        _St.foreign, _St.excess, _St.askBlock, _St.short, _St.pending, _St.block, _St.ok
      ].indexOf(s);

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
            FilledButton(onPressed: () => _load(force: true), child: const Text('Повторить')),
            TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Назад')),
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

      body = Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Row(children: [
            IconButton(
                tooltip: 'Назад',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(
                '№ ${_doc['Number'] ?? ''} · собрано $done из $inDoc'
                '${_lastScan.isEmpty ? '' : '\nскан: $_lastScan'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Ввести штрихкод',
              icon: const Icon(Icons.keyboard),
              onPressed: () async {
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
              },
            ),
            IconButton(
                tooltip: 'Обновить из 1С (без кэша)',
                icon: const Icon(Icons.refresh),
                onPressed: _saving ? null : () => _load(force: true)),
          ]),
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
                    if (st == _St.askBlock)
                      TextButton(onPressed: () => _askBlock(it), child: const Text('Блок?')),
                    Text('${_fmt(it.fact)} / ${_fmt(it.plan)}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_upload),
                label: const Text('Отправить в 1С'),
              ),
            ),
          ),
        ),
      ]);
    }
    return SizedBox(width: widget.width, height: widget.height, child: _EdgeSwipeBack(child: SafeArea(child: body)));
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
