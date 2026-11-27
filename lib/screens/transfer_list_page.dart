import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Offline-first list of transfers on the TSD.
///
/// «Загрузить накладные» downloads today's «Перемещение товаров» of the
/// warehouse (posted and unposted, not yet checked) with their lines + names /
/// units / barcodes of the goods from 1C, then updates the goods catalog with
/// photos from Stock API (SQLite) and pre-caches photos of today's goods.
/// The check itself (TransferCheckWidget) works without network. Checked
/// documents are sent to 1C here: automatically after the check and with
/// «Отправить». A posted document is re-posted (Unpost → write → Post).
///
/// One-time check: a sent document gets «[ТСД✓]» in its 1C comment; such
/// documents are never downloaded again and a send is refused if the mark
/// appeared meanwhile (another TSD) or the document changed in 1C after the
/// download («конфликт»). Sent keys are also kept on the TSD for 7 days.
/// To re-check, remove the «[ТСД✓]» line from the comment in 1C.
///
/// Settings come from TsdSettingsWidget (SharedPreferences `tsd_settings`);
/// non-empty parameters override them.
class TransferListWidget extends StatefulWidget {
  const TransferListWidget({
    super.key,
    this.width,
    this.height,
    this.baseUrl,
    this.username,
    this.password,
    this.warehouseKey,
    this.onOpen,
    this.onSettings,
  });

  final double? width;
  final double? height;

  /// Optional overrides of the saved settings, e.g. http://192.168.1.10/tbase
  final String? baseUrl;
  final String? username;
  final String? password;

  /// Ref_Key of the sender warehouse (Склад_Key)
  final String? warehouseKey;

  /// Action with one String parameter: transferKey → navigate to the check page
  final Future Function(String transferKey)? onOpen;

  /// Action: navigate to the settings page (gear icon)
  final Future Function()? onSettings;

  @override
  State<TransferListWidget> createState() => _TransferListWidgetState();
}

// ───────────── local storage (same format in TransferCheckWidget) ─────────────

/// SharedPreferences layout:
///  tsd_docs            — JSON list of document keys on the TSD
///  tsd_doc_KEY         — {key, number, date, receiver, posted, dataVersion, lines, status,
///                         progress, result, error, loadedAt}
///                         status: new | work | checked | conflict | sent
///                         (sent: lines dropped, kept 7 days as history)
///  tsd_prod_PRODUCT    — {name, article, weight, base, units, codes, ts} (from 1C)
class _Store {
  static const docsKey = 'tsd_docs';
  static const docPrefix = 'tsd_doc_';
  static const prodPrefix = 'tsd_prod_';

  static List<String> keys(SharedPreferences p) {
    try {
      return (jsonDecode(p.getString(docsKey) ?? '[]') as List).map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static Map<String, dynamic>? doc(SharedPreferences p, String key) {
    final s = p.getString('$docPrefix$key');
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> docs(SharedPreferences p) {
    final out = <Map<String, dynamic>>[];
    for (final k in keys(p)) {
      final d = doc(p, k);
      if (d != null) out.add(d);
    }
    return out;
  }

  static Future<void> putDoc(SharedPreferences p, Map<String, dynamic> d) async {
    final key = d['key'].toString();
    await p.setString('$docPrefix$key', jsonEncode(d));
    final k = keys(p);
    if (!k.contains(key)) await p.setString(docsKey, jsonEncode([...k, key]));
  }

  static Future<void> removeDoc(SharedPreferences p, String key) async {
    await p.remove('$docPrefix$key');
    await p.setString(docsKey, jsonEncode(keys(p)..remove(key)));
  }

  static Map<String, dynamic>? prod(SharedPreferences p, String key) {
    final s = p.getString('$prodPrefix$key');
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> putProd(SharedPreferences p, String key, Map<String, dynamic> e) {
    e['ts'] = DateTime.now().millisecondsSinceEpoch;
    return p.setString('$prodPrefix$key', jsonEncode(e));
  }

  /// Keep only 1C product data of documents still on the TSD; drop old-format
  /// keys and sent documents older than 7 days.
  static Future<void> cleanup(SharedPreferences p) async {
    final border = DateTime.now().subtract(const Duration(days: 7));
    for (final d in docs(p)) {
      if (d['status'] != 'sent') continue;
      final at = DateTime.tryParse((d['sentAt'] ?? '').toString());
      if (at == null || at.isBefore(border)) await removeDoc(p, d['key'].toString());
    }
    final used = <String>{
      for (final d in docs(p))
        for (final l in (d['lines'] as List? ?? const [])) (l['Номенклатура_Key'] ?? '').toString(),
    };
    for (final k in p.getKeys().toList()) {
      final legacy = k.startsWith('tsdc_p_') || k.startsWith('tsdcheck_');
      final unused = k.startsWith(prodPrefix) && !used.contains(k.substring(prodPrefix.length));
      if (legacy || unused) await p.remove(k);
    }
  }
}

// ───────────────────────────── goods catalog (Stock API → SQLite) ─────────────────────────────

class _Catalog {
  static Database? _db;

  static Future<Database> open() async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'tsd_catalog.db');
    return _db = await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE products (id TEXT PRIMARY KEY, name TEXT, article TEXT, unit TEXT, '
          'thumb TEXT, image TEXT, active INTEGER)');
      await db.execute('CREATE TABLE barcodes (code TEXT PRIMARY KEY, id TEXT)');
      await db.execute('CREATE INDEX barcodes_id ON barcodes(id)');
      await db.execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT)');
    });
  }

  static Future<int> count() async {
    try {
      final db = await open();
      return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM products')) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// First time — the whole catalog, then only changes (updated_since), pages of 1000.
  /// Returns the number of received products.
  static Future<int> sync(String base, String key, void Function(int) progress) async {
    final db = await open();
    final meta = await db.query('meta', where: 'k = ?', whereArgs: ['since']);
    final since = meta.isEmpty ? null : meta.first['v'].toString();
    final started = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();
    var offset = 0, total = 0;
    while (true) {
      final params = {
        'stocks': 'false',
        'limit': '1000',
        'offset': '$offset',
        if (since != null) 'updated_since': since,
      };
      final q = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
      http.Response r;
      try {
        r = await http.get(Uri.parse('$base/api/stock/products?$q'),
            headers: {'X-API-Key': key, 'Accept': 'application/json'}).timeout(const Duration(seconds: 60));
      } catch (e) {
        throw 'Stock API: нет связи ($e)';
      }
      if (r.statusCode == 401 || r.statusCode == 403) throw 'Stock API: неверный ключ';
      if (r.statusCode != 200) throw 'Stock API: HTTP ${r.statusCode}';
      final items = ((jsonDecode(utf8.decode(r.bodyBytes))['items'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      await db.transaction((tx) async {
        final b = tx.batch();
        for (final it in items) {
          final id = (it['external_id'] ?? '').toString();
          if (id.isEmpty) continue;
          b.insert(
              'products',
              {
                'id': id,
                'name': (it['name'] ?? '').toString(),
                'article': (it['article'] ?? '').toString(),
                'unit': (it['unit'] ?? '').toString(),
                'thumb': (it['thumb'] ?? '').toString(),
                'image': (it['image'] ?? '').toString(),
                'active': it['is_active'] == false ? 0 : 1,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          b.delete('barcodes', where: 'id = ?', whereArgs: [id]);
          final codes = <String>{
            ...((it['barcodes'] as List?) ?? const []).map((e) => e.toString()),
            if ((it['barcode'] ?? '').toString().isNotEmpty) it['barcode'].toString(),
          };
          for (final c in codes) {
            b.insert('barcodes', {'code': c, 'id': id}, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await b.commit(noResult: true);
      });
      total += items.length;
      progress(total);
      if (items.length < 1000) break;
      offset += 1000;
    }
    await db.insert('meta', {'k': 'since', 'v': started}, conflictAlgorithm: ConflictAlgorithm.replace);
    return total;
  }

  static Future<List<String>> thumbs(Iterable<String> ids) async {
    final db = await open();
    final all = ids.toSet().toList();
    final out = <String>[];
    for (var i = 0; i < all.length; i += 500) {
      final part = all.sublist(i, i + 500 > all.length ? all.length : i + 500);
      for (final r in await db.query('products',
          columns: ['thumb'], where: 'id IN (${List.filled(part.length, '?').join(',')})', whereArgs: part)) {
        final t = (r['thumb'] ?? '').toString();
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out;
  }
}

// ───────────────────────────── 1C OData client ─────────────────────────────

class _ODataError implements Exception {
  _ODataError(this.message, {this.network = false, this.status = 0});
  final String message;
  final bool network;
  final int status;
  @override
  String toString() => message;
}

class _OData {
  _OData(String baseUrl, String user, String pass)
      : root = '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/odata/standard.odata',
        auth = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  final String root;
  final String auth;

  /// IIS rejects query strings over 2048 chars (HTTP 404.15); Cyrillic grows ×6 when encoded.
  static const _maxQuery = 1900;

  static String entity(String name, [String? guid]) =>
      guid == null ? Uri.encodeComponent(name) : "${Uri.encodeComponent(name)}(guid'$guid')";

  Uri _uri(String path, Map<String, String> params) {
    final q = {r'$format': 'json', ...params}
        .entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return Uri.parse('$root/$path?$q');
  }

  Map<String, String> get _headers => {
        'Authorization': auth,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response r;
    try {
      r = await call().timeout(const Duration(seconds: 40));
    } catch (e) {
      throw _ODataError('Нет связи с 1С: $e', network: true);
    }
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode == 401) throw _ODataError('1С: неверный логин или пароль', status: 401);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw _ODataError('1С: HTTP ${r.statusCode} ${_error(body)}', status: r.statusCode);
    }
    return body.isEmpty ? null : jsonDecode(body);
  }

  static String _error(String body) {
    try {
      final msg = jsonDecode(body)['odata.error']?['message']?['value'];
      if (msg != null) return msg.toString();
    } catch (_) {}
    final title = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body)?.group(1);
    if (title != null) return title.trim();
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  Future<Map<String, dynamic>> getOne(String path, [Map<String, String> params = const {}]) async =>
      (await _send(() => http.get(_uri(path, params), headers: _headers))) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> getList(String path, Map<String, String> params) async =>
      (((await getOne(path, params))['value'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// GET with an `or`-chain over many GUIDs, chunked by the encoded query length.
  Future<List<Map<String, dynamic>>> getByKeys(
      String name, String field, Iterable<String> keys, String select) async {
    final all = keys.where((k) => k.isNotEmpty).toSet().toList();
    final out = <Map<String, dynamic>>[];
    final fixed = Uri.encodeComponent(select).length + 60;
    var i = 0;
    while (i < all.length) {
      final part = <String>[];
      var len = fixed;
      while (i < all.length) {
        final add = Uri.encodeComponent("${part.isEmpty ? '' : ' or '}$field eq guid'${all[i]}'").length;
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

  /// Bound action of a document: Post / Unpost (non-operational posting).
  Future<dynamic> action(String docPath, String name) => _send(() => http.post(
      _uri('$docPath/$name', const {'PostingModeOperational': 'false'}),
      headers: _headers));
}

// ───────────────────────────── widget ─────────────────────────────

const _zeroGuid = '00000000-0000-0000-0000-000000000000';

/// Mark of a document checked by a TSD (in Комментарий). «Проверено ТСД» is
/// the mark of the earlier app version.
const _mark = '[ТСД✓]';
bool _hasMark(dynamic comment) {
  final c = (comment ?? '').toString();
  return c.contains(_mark) || c.contains('Проверено ТСД');
}

class _TransferListWidgetState extends State<TransferListWidget> {
  List<Map<String, dynamic>> _docs = []; // to check: new / work / checked / conflict
  List<Map<String, dynamic>> _sent = []; // history
  int _tab = 0;
  String _search = '';
  String? _busy; // text of the running operation
  String? _error;
  String? _warning; // catalog problems: the 1C part still worked
  String _lastLoad = '';
  int _catalogCount = 0;

  // resolved settings
  String _root = '';
  String _user = '';
  String _pass = '';
  String _warehouse = '';
  String _warehouseName = '';
  String _stockUrl = '';
  String _stockKey = '';

  bool get _noSettings => _root.isEmpty || _warehouse.isEmpty;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _readSettings();
    final prefs = await SharedPreferences.getInstance();
    await _Store.cleanup(prefs); // history older than 7 days
    _lastLoad = prefs.getString('tsd_last_load') ?? '';
    _catalogCount = await _Catalog.count();
    await _refreshLocal();
  }

  Future<void> _readSettings() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> m = {};
    try {
      m = jsonDecode(prefs.getString('tsd_settings') ?? '{}') as Map<String, dynamic>;
    } catch (_) {}
    String pick(String? param, String key) =>
        (param != null && param.trim().isNotEmpty) ? param.trim() : (m[key] ?? '').toString();
    _root = pick(widget.baseUrl, 'baseUrl').replaceAll(RegExp(r'/+$'), '');
    _user = pick(widget.username, 'username');
    _pass = (widget.password?.isNotEmpty ?? false) ? widget.password! : (m['password'] ?? '').toString();
    _warehouse = pick(widget.warehouseKey, 'warehouseKey');
    _warehouseName = (m['warehouseName'] ?? '').toString();
    _stockUrl = (m['stockUrl'] ?? '').toString().trim().replaceAll(RegExp(r'/+$'), '');
    _stockKey = (m['stockKey'] ?? '').toString().trim();
  }

  _OData get _od => _OData(_root, _user, _pass);

  Future<void> _refreshLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final all = _Store.docs(prefs);
    final docs = all.where((d) => d['status'] != 'sent').toList()
      ..sort((a, b) => (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));
    final sent = all.where((d) => d['status'] == 'sent').toList()
      ..sort((a, b) => (b['sentAt'] ?? '').toString().compareTo((a['sentAt'] ?? '').toString()));
    if (mounted) {
      setState(() {
        _docs = docs;
        _sent = sent;
      });
    }
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red.shade700 : null,
        duration: Duration(seconds: error ? 6 : 3),
      ));
  }

  // ── download ──

  Future<void> _download() async {
    await _readSettings();
    if (_noSettings) {
      _toast('Укажите в настройках адрес 1С и склад', error: true);
      return;
    }
    setState(() {
      _busy = 'Загрузка накладных из 1С…';
      _error = null;
      _warning = null;
    });
    String summary = '';
    try {
      final od = _od;
      final prefs = await SharedPreferences.getInstance();
      // Today only (from 00:00), posted and unposted.
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final sinceStr = '${now.year}-${two(now.month)}-${two(now.day)}T00:00:00';

      final remote = await od.getList(_OData.entity('Document_ПеремещениеТоваров'), {
        r'$filter': "Склад_Key eq guid'$_warehouse' and DeletionMark eq false and Date ge datetime'$sinceStr'",
        r'$select': 'Ref_Key,Number,Date,Posted,DataVersion,Комментарий,СкладПолучатель_Key,Товары',
        r'$orderby': 'Date desc',
      });
      final names =
          await _warehouseNames(prefs, od, remote.map((m) => (m['СкладПолучатель_Key'] ?? '').toString()).toSet());

      var added = 0, updated = 0, removed = 0, conflicts = 0, markLost = 0;
      final remoteKeys = <String>{};
      for (final m in remote) {
        final key = m['Ref_Key'].toString();
        remoteKeys.add(key);
        final checkedElsewhere = _hasMark(m['Комментарий']);
        final local = _Store.doc(prefs, key);
        final status = (local?['status'] ?? '').toString();
        if (status == 'sent') {
          // Sent from this TSD: never again, even if the mark was erased in 1C.
          if (!checkedElsewhere) markLost++;
          continue;
        }
        if (checkedElsewhere) {
          if (local == null) continue;
          if (status == 'new') {
            await _Store.removeDoc(prefs, key);
            removed++;
          } else if (status != 'conflict') {
            local['status'] = 'conflict';
            local['error'] = 'Уже проверен (отметка $_mark в 1С)';
            await _Store.putDoc(prefs, local);
            conflicts++;
          }
          continue;
        }
        final changed = local != null && local['dataVersion'] != m['DataVersion'];
        if (local == null) {
          await _Store.putDoc(prefs, _fromRemote(m, names));
          added++;
        } else if (status == 'new') {
          if (changed) {
            await _Store.putDoc(prefs, _fromRemote(m, names));
            updated++;
          }
        } else if (changed && status != 'conflict') {
          local['status'] = 'conflict';
          local['error'] = 'Изменён в 1С после загрузки';
          await _Store.putDoc(prefs, local);
          conflicts++;
        }
      }

      // Local documents no longer among today's ones in 1C (deleted / date changed).
      for (final d in _Store.docs(prefs)) {
        final key = d['key'].toString();
        if (remoteKeys.contains(key)) continue;
        final status = (d['status'] ?? '').toString();
        if (status == 'sent') continue;
        if (status == 'new') {
          await _Store.removeDoc(prefs, key);
          removed++;
        } else if (status != 'conflict') {
          d['status'] = 'conflict';
          d['error'] = 'Удалён в 1С или дата не сегодня';
          await _Store.putDoc(prefs, d);
          conflicts++;
        }
      }

      if (mounted) setState(() => _busy = 'Загрузка товаров из 1С…');
      await _loadProducts(prefs, od);
      await _Store.cleanup(prefs);

      summary = 'Новых $added, обновлено $updated, убрано $removed'
          '${conflicts > 0 ? ', конфликтов $conflicts' : ''}';
      if (markLost > 0) summary += '. У $markLost отправленных стёрта отметка $_mark в 1С';

      await _syncCatalog(prefs);

      _lastLoad = DateTime.now().toIso8601String();
      await prefs.setString('tsd_last_load', _lastLoad);
      _toast(summary);
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _busy = null);
    await _refreshLocal();
  }

  /// Catalog with photos from Stock API + photos of today's goods into the cache.
  /// Failures here do not break the 1C part (shown as a warning).
  Future<void> _syncCatalog(SharedPreferences prefs) async {
    if (_stockUrl.isEmpty || _stockKey.isEmpty) {
      _warning = 'Каталог с фото не подключён: укажите Stock API в настройках';
      return;
    }
    try {
      if (mounted) setState(() => _busy = 'Каталог товаров…');
      await _Catalog.sync(_stockUrl, _stockKey, (n) {
        if (mounted) setState(() => _busy = 'Каталог товаров: $n…');
      });
      _catalogCount = await _Catalog.count();

      final ids = <String>{
        for (final d in _Store.docs(prefs).where((d) => d['status'] != 'sent'))
          for (final l in (d['lines'] as List? ?? const [])) (l['Номенклатура_Key'] ?? '').toString(),
      };
      final thumbs = await _Catalog.thumbs(ids);
      var n = 0;
      for (var i = 0; i < thumbs.length && i < 600; i += 6) {
        if (!mounted) return;
        setState(() => _busy = 'Фото товаров: ${i + 1} из ${thumbs.length}');
        await Future.wait(thumbs.skip(i).take(6).map((t) async {
          try {
            await precacheImage(CachedNetworkImageProvider('$_stockUrl$t'), context);
            n++;
          } catch (_) {}
        }));
      }
      if (n < thumbs.length) _warning = 'Загружено фото: $n из ${thumbs.length}';
    } catch (e) {
      _warning = 'Каталог не обновлён: $e';
    }
  }

  Map<String, dynamic> _fromRemote(Map<String, dynamic> m, Map<String, String> names) => {
        'key': m['Ref_Key'].toString(),
        'number': (m['Number'] ?? '').toString(),
        'date': (m['Date'] ?? '').toString(),
        'receiver': names[(m['СкладПолучатель_Key'] ?? '').toString()] ?? '',
        'dataVersion': m['DataVersion'],
        'posted': m['Posted'] == true,
        'lines': [
          for (final row in ((m['Товары'] as List?) ?? const []).cast<Map<String, dynamic>>())
            {for (final e in row.entries) if (!e.key.contains('@')) e.key: e.value},
        ],
        'status': 'new',
        'loadedAt': DateTime.now().toIso8601String(),
      };

  /// Names, units and barcodes (from 1C) of all goods in the local documents
  /// (missing ones or older than 12 h).
  Future<void> _loadProducts(SharedPreferences prefs, _OData od) async {
    final border = DateTime.now().subtract(const Duration(hours: 12)).millisecondsSinceEpoch;
    final keys = <String>{
      for (final d in _Store.docs(prefs).where((d) => d['status'] != 'sent'))
        for (final l in (d['lines'] as List? ?? const [])) (l['Номенклатура_Key'] ?? '').toString(),
    }..removeWhere((k) {
        if (k.isEmpty || k == _zeroGuid) return true;
        final e = _Store.prod(prefs, k);
        return e != null && ((e['ts'] as num?)?.toInt() ?? 0) > border;
      });
    if (keys.isEmpty) return;

    final fresh = {
      for (final pk in keys)
        pk: <String, dynamic>{
          'name': pk.substring(0, 8),
          'article': '',
          'weight': false,
          'base': _zeroGuid,
          'units': <dynamic>[],
          'codes': <dynamic>[],
        }
    };
    for (final r in await od.getByKeys('Catalog_Номенклатура', 'Ref_Key', keys,
        'Ref_Key,Description,Артикул,Весовой,ЕдиницаИзмерения_Key')) {
      final e = fresh[r['Ref_Key'].toString()];
      if (e == null) continue;
      e['name'] = (r['Description'] ?? '').toString();
      e['article'] = (r['Артикул'] ?? '').toString();
      e['weight'] = r['Весовой'] == true;
      e['base'] = (r['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString();
    }
    for (final u in await od.getByKeys('Catalog_ЕдиницыИзмерения', 'Owner_Key', keys,
        'Ref_Key,Owner_Key,Коэффициент,DeletionMark,ЕдиницаИзмеренияПоКлассификатору_Key')) {
      (fresh[u['Owner_Key'].toString()]?['units'] as List?)?.add([
        u['Ref_Key'].toString(),
        u['Коэффициент'] is num ? u['Коэффициент'] : 1,
        (u['ЕдиницаИзмеренияПоКлассификатору_Key'] ?? _zeroGuid).toString(),
        u['DeletionMark'] == true,
      ]);
    }
    for (final b in await od.getByKeys('InformationRegister_ШтрихкодыНоменклатуры', 'Номенклатура_Key', keys,
        'Штрихкод,Номенклатура_Key,ХарактеристикаНоменклатуры_Key,ЕдиницаИзмерения_Key,НеИспользуется')) {
      if (b['НеИспользуется'] == true) continue;
      (fresh[b['Номенклатура_Key'].toString()]?['codes'] as List?)?.add([
        b['Штрихкод'].toString().trim(),
        (b['ХарактеристикаНоменклатуры_Key'] ?? _zeroGuid).toString(),
        (b['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString(),
      ]);
    }
    for (final e in fresh.entries) {
      await _Store.putProd(prefs, e.key, e.value);
    }
  }

  /// Warehouse names cached on the TSD for 24 h.
  Future<Map<String, String>> _warehouseNames(SharedPreferences prefs, _OData od, Set<String> needed) async {
    const key = 'tsdc_wh';
    Map<String, String> names = {};
    var fresh = false;
    try {
      final m = jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
      fresh = DateTime.now().millisecondsSinceEpoch - ((m['ts'] as num?)?.toInt() ?? 0) <
          const Duration(hours: 24).inMilliseconds;
      names = (m['names'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {}
    if (fresh && needed.every((k) => k.isEmpty || names.containsKey(k))) return names;
    try {
      final rows = await od.getList(_OData.entity('Catalog_Склады'), {r'$select': 'Ref_Key,Description'});
      names = {for (final r in rows) r['Ref_Key'].toString(): (r['Description'] ?? '').toString()};
      await prefs.setString(key, jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'names': names}));
    } catch (_) {}
    return names;
  }

  // ── send ──

  /// true = written to 1C (moved to «Отправленные»); false = 1C refused
  /// (status saved); throws _ODataError(network: true) when there is no connection.
  ///
  /// Posted document: Unpost → write → Post. If posting fails the document
  /// stays unposted with the new quantities (visible in 1C), never «posted
  /// with old movements».
  Future<bool> _sendOne(SharedPreferences prefs, Map<String, dynamic> d) async {
    final key = d['key'].toString();
    final od = _od;
    final path = _OData.entity('Document_ПеремещениеТоваров', key);
    try {
      Map<String, dynamic> fresh;
      try {
        fresh = await od.getOne(path, {r'$select': 'Posted,DeletionMark,DataVersion,Комментарий'});
      } on _ODataError catch (e) {
        if (e.status == 404) throw _ODataError('Документ удалён в 1С', status: 409);
        rethrow;
      }
      if (fresh['DeletionMark'] == true) throw _ODataError('Документ помечен на удаление в 1С', status: 409);
      if (_hasMark(fresh['Комментарий'])) {
        throw _ODataError('Уже проверен (отметка $_mark в 1С) — повторная отправка запрещена', status: 409);
      }
      if (fresh['DataVersion'] != d['dataVersion']) {
        throw _ODataError('Изменён в 1С после загрузки', status: 409);
      }

      // repost: true when this TSD unposted it (now or in an interrupted earlier attempt)
      var repost = d['repost'] == true;
      if (fresh['Posted'] == true) {
        await od.action(path, 'Unpost');
        repost = true;
        final v = await od.getOne(path, {r'$select': 'DataVersion'});
        d['dataVersion'] = v['DataVersion'];
        d['repost'] = true;
        await _Store.putDoc(prefs, d);
      }

      final result = d['result'] as Map<String, dynamic>;
      var log = result['log'].toString();
      if (!log.startsWith(_mark)) log = '$_mark $log';
      final old = (fresh['Комментарий'] ?? '').toString().trim();
      try {
        await od.patch(path, {
          'Товары': result['rows'],
          'Комментарий': old.isEmpty ? log : '$old\n$log',
        });
      } catch (e) {
        if (repost && !(e is _ODataError && e.network)) {
          try {
            await od.action(path, 'Post'); // put the old version back as it was
            d.remove('repost');
          } catch (_) {}
        }
        rethrow;
      }

      String? postError;
      if (repost) {
        try {
          await od.action(path, 'Post');
        } on _ODataError catch (e) {
          postError = e.message;
        }
      }

      // Light record for «Отправленные» (no lines / goods); also guards against re-download.
      await _Store.putDoc(prefs, {
        'key': key,
        'number': d['number'],
        'date': d['date'],
        'receiver': d['receiver'],
        'status': 'sent',
        'sentAt': DateTime.now().toIso8601String(),
        'linesCount': (result['rows'] as List?)?.length ?? 0,
        'log': log,
        'reposted': repost && postError == null,
        if (postError != null) 'postError': postError,
      });
      return true;
    } on _ODataError catch (e) {
      if (e.status == 409) d['status'] = 'conflict';
      d['error'] = e.network ? 'нет связи, ждёт отправки' : e.message;
      await _Store.putDoc(prefs, d);
      if (e.network) rethrow;
      return false;
    }
  }

  Future<void> _sendAll({String? onlyKey}) async {
    await _readSettings();
    if (_root.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final queue = _Store.docs(prefs)
        .where((d) => d['status'] == 'checked' && (onlyKey == null || d['key'] == onlyKey))
        .toList();
    if (queue.isEmpty) return;
    setState(() => _busy = 'Отправка в 1С…');
    var sent = 0, failed = 0;
    var offline = false;
    for (final d in queue) {
      try {
        (await _sendOne(prefs, d)) ? sent++ : failed++;
      } on _ODataError {
        offline = true;
        break; // no connection: the rest stays queued
      }
    }
    if (mounted) setState(() => _busy = null);
    await _refreshLocal();
    final notPosted = _sent.where((d) => d['postError'] != null && queue.any((q) => q['key'] == d['key'])).length;
    if (offline) {
      _toast('Нет связи с 1С — проверенные документы ждут отправки', error: true);
    } else if (failed > 0) {
      _toast('Отправлено $sent, не принято $failed (см. список)', error: true);
    } else if (notPosted > 0) {
      _toast('Отправлено $sent, но $notPosted не удалось провести — проведите в 1С (вкладка «Отправленные»)',
          error: true);
    } else {
      _toast('Отправлено в 1С: $sent ✓');
    }
  }

  // ── navigation ──

  Future<void> _open(Map<String, dynamic> d) async {
    final key = d['key'].toString();
    if (d['status'] == 'sent') {
      await _sentDialog(d);
      return;
    }
    if (d['status'] == 'conflict') {
      await _conflictDialog(d);
      return;
    }
    if (widget.onOpen == null) return;
    await widget.onOpen!(key);
    await _refreshLocal();
    final now = _docs.where((x) => x['key'] == key).toList();
    if (now.isNotEmpty && now.first['status'] == 'checked') await _sendAll(onlyKey: key);
  }

  Future<void> _conflictDialog(Map<String, dynamic> d) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber, color: Colors.red, size: 40),
        title: Text('№ ${d['number']}: конфликт'),
        content: Text('${d['error'] ?? ''}\n\nРезультат проверки нельзя записать в 1С. '
            'Удалите документ с ТСД и нажмите «Загрузить накладные», чтобы получить актуальную версию.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить с ТСД')),
        ],
      ),
    );
    if (remove != true) return;
    final prefs = await SharedPreferences.getInstance();
    await _Store.removeDoc(prefs, d['key'].toString());
    await _refreshLocal();
  }

  Future<void> _sentDialog(Map<String, dynamic> d) async {
    final postError = d['postError'];
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(postError != null ? Icons.error_outline : Icons.cloud_done,
            color: postError != null ? Colors.red : Colors.green, size: 40),
        title: Text('№ ${d['number']} · ${d['receiver'] ?? ''}'),
        content: SingleChildScrollView(
          child: Text('Отправлено в 1С: ${_time((d['sentAt'] ?? '').toString())}\n'
              'Строк: ${d['linesCount'] ?? 0}\n\n${(d['log'] ?? '').toString().replaceAll('; ', '\n')}\n\n'
              '${postError != null ? 'ВНИМАНИЕ: перепровести не удалось — $postError\n'
                  'Документ не проведён, проведите его в 1С.' : d['reposted'] == true ? 'Документ перепроведён в 1С.' : 'Документ не проведён — проведите его в 1С.'}'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Убрать из истории')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK')),
        ],
      ),
    );
    if (remove != true) return;
    final prefs = await SharedPreferences.getInstance();
    await _Store.removeDoc(prefs, d['key'].toString());
    await _refreshLocal();
  }

  Future<void> _openSettings() async {
    if (widget.onSettings == null) return;
    await widget.onSettings!();
    await _readSettings();
    _catalogCount = await _Catalog.count();
    if (mounted) setState(() {});
  }

  // ── UI ──

  static const _status = {
    'new': ('Новый', Icons.fiber_new_outlined, Color(0xFF607D8B)),
    'work': ('В работе', Icons.timelapse, Color(0xFFF9A825)),
    'checked': ('Ждёт отправки', Icons.cloud_upload_outlined, Color(0xFF2E7D32)),
    'conflict': ('Конфликт', Icons.warning_amber, Color(0xFFC62828)),
    'sent': ('Отправлен', Icons.cloud_done, Color(0xFF2E7D32)),
  };

  String _time(String s) {
    final d = DateTime.tryParse(s);
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    final today = DateTime.now();
    final sameDay = d.year == today.year && d.month == today.month && d.day == today.day;
    return sameDay ? '${two(d.hour)}:${two(d.minute)}' : '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final source = _tab == 0 ? _docs : _sent;
    final q = _search.trim().toLowerCase();
    final visible = q.isEmpty
        ? source
        : source
            .where((d) =>
                d['number'].toString().toLowerCase().contains(q) ||
                d['receiver'].toString().toLowerCase().contains(q))
            .toList();
    final toSend = _docs.where((d) => d['status'] == 'checked').length;
    final busy = _busy != null;

    Widget list;
    if (_tab == 1 && _sent.isEmpty) {
      list = _empty(Icons.cloud_done_outlined, 'Отправленных за 7 дней нет');
    } else if (_tab == 0 && _docs.isEmpty) {
      list = _noSettings
          ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              _empty(Icons.settings_outlined, 'Сначала укажите адрес 1С и склад'),
              if (widget.onSettings != null)
                FilledButton.icon(
                    onPressed: _openSettings, icon: const Icon(Icons.settings), label: const Text('Настройки')),
            ])
          : _empty(Icons.inventory_2_outlined, 'Накладных на сегодня нет.\nНажмите «Загрузить накладные».');
    } else {
      list = ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: visible.length,
        itemBuilder: (ctx, i) => _card(visible[i], busy),
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _EdgeSwipeBack(
        child: SafeArea(
          child: Column(children: [
            // ── header ──
            Container(
              width: double.infinity,
              color: scheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Перемещения', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    Text(
                      [
                        if (_warehouseName.isNotEmpty) _warehouseName,
                        'сегодня',
                      ].join(' · '),
                      style: const TextStyle(fontSize: 13, color: Colors.black54),
                    ),
                  ]),
                ),
                if (widget.onSettings != null)
                  IconButton(
                      tooltip: 'Настройки', icon: const Icon(Icons.settings), onPressed: busy ? null : _openSettings),
              ]),
            ),
            // ── main action ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: busy ? null : _download,
                  icon: const Icon(Icons.cloud_download, size: 26),
                  label: const Text('Загрузить накладные', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                [
                  _lastLoad.isEmpty ? 'Ещё не загружали' : 'Загружено ${_time(_lastLoad)}',
                  if (_catalogCount > 0) 'каталог $_catalogCount',
                ].join(' · '),
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(children: [
                  const LinearProgressIndicator(),
                  Padding(padding: const EdgeInsets.all(4), child: Text(_busy!)),
                ]),
              ),
            if (_error != null) _banner(_error!, Colors.red.shade50, Colors.red.shade800, Icons.error_outline),
            if (_warning != null && _error == null)
              _banner(_warning!, Colors.orange.shade50, Colors.orange.shade900, Icons.info_outline),
            if (toSend > 0 && !busy)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.cloud_upload_outlined, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Проверено и не отправлено: $toSend')),
                  FilledButton(onPressed: () => _sendAll(), child: const Text('Отправить')),
                ]),
              ),
            // ── tabs ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 0, label: Text('К проверке ${_docs.length}')),
                    ButtonSegment(value: 1, label: Text('Отправленные ${_sent.length}')),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _tab = v.first),
                ),
              ),
            ),
            if (source.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Номер или магазин',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
            Expanded(child: list),
          ]),
        ),
      ),
    );
  }

  Widget _empty(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Colors.black26),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.black54)),
          ]),
        ),
      );

  Widget _banner(String text, Color bg, Color fg, IconData icon) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: fg))),
        ]),
      );

  Widget _card(Map<String, dynamic> d, bool busy) {
    final status = (d['status'] ?? 'new').toString();
    final failedPost = d['postError'] != null;
    final s = _status[status] ?? _status['new']!;
    final color = failedPost ? const Color(0xFFC62828) : s.$3;
    final lines = (d['lines'] as List?)?.length ?? (d['linesCount'] as num?)?.toInt() ?? 0;
    final sub = status == 'sent'
        ? 'отправлен ${_time((d['sentAt'] ?? '').toString())}${failedPost ? ' · НЕ ПРОВЕДЁН' : ''}'
        : (d['error'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: busy ? null : () => _open(d),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 6, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    (d['receiver'] ?? '').toString().isEmpty ? '№ ${d['number']}' : d['receiver'].toString(),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '№ ${d['number']} · ${_time(d['date'].toString())} · строк $lines'
                    '${d['posted'] == true ? ' · проведён' : ''}',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Icon(failedPost ? Icons.error_outline : s.$2, size: 16, color: color),
                    const SizedBox(width: 4),
                    Text(failedPost ? 'Не проведён' : s.$1,
                        style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('· $sub',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      ),
                    ],
                  ]),
                ]),
              ),
            ),
            const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.chevron_right)),
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
