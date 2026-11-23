// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Offline-first list of transfers on the TSD.
///
/// «Загрузить» downloads unposted «Перемещение товаров» of the warehouse with
/// their lines + names/units/barcodes of the goods (stored on the TSD). The
/// check itself (TransferCheckWidget) works without network. Checked documents
/// are sent to 1C here: automatically after returning from the check page and
/// with the «Отправить» button. A document changed / posted in 1C after the
/// download is never overwritten (status «конфликт»).
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
    this.daysBack,
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
  final int? daysBack;

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
///  tsd_doc_KEY         — {key, number, date, receiver, dataVersion, lines, status,
///                         progress, result, error, loadedAt}
///                         status: new | work | checked | conflict | sent
///                         (sent: lines dropped, kept 7 days as history)
///  tsd_prod_PRODUCT    — {name, article, weight, base, units, codes, ts}
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

  /// Keep only products of documents still on the TSD; drop old-format keys
  /// and sent documents older than 7 days.
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

  Future<dynamic> post(String path, Map<String, dynamic> body) =>
      _send(() => http.post(_uri(path, const {}), headers: _headers, body: jsonEncode(body)));
}

// ───────────────────────────── widget ─────────────────────────────

const _zeroGuid = '00000000-0000-0000-0000-000000000000';
const _checkedMark = 'Проверено ТСД';

class _TransferListWidgetState extends State<TransferListWidget> {
  List<Map<String, dynamic>> _docs = []; // to check: new / work / checked / conflict
  List<Map<String, dynamic>> _sent = []; // history
  int _tab = 0;
  String _search = '';
  String? _busy; // text of the running operation
  String? _error;

  // resolved settings
  String _root = '';
  String _user = '';
  String _pass = '';
  String _warehouse = '';
  String _warehouseName = '';
  int _days = 7;

  bool get _noSettings => _root.isEmpty || _warehouse.isEmpty;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _readSettings();
    await _Store.cleanup(await SharedPreferences.getInstance()); // history older than 7 days
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
    _days = widget.daysBack ?? (m['daysBack'] is num ? (m['daysBack'] as num).toInt() : 7);
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
      _busy = 'Загрузка накладных…';
      _error = null;
    });
    try {
      final od = _od;
      final prefs = await SharedPreferences.getInstance();
      final since = DateTime.now().subtract(Duration(days: _days < 0 ? 0 : _days));
      String two(int v) => v.toString().padLeft(2, '0');
      final sinceStr = '${since.year}-${two(since.month)}-${two(since.day)}T00:00:00';

      final remote = await od.getList(_OData.entity('Document_ПеремещениеТоваров'), {
        r'$filter': "Склад_Key eq guid'$_warehouse' and Posted eq false "
            "and DeletionMark eq false and Date ge datetime'$sinceStr'",
        r'$select': 'Ref_Key,Number,Date,DataVersion,Комментарий,СкладПолучатель_Key,Товары',
        r'$orderby': 'Date desc',
      });
      final names =
          await _warehouseNames(prefs, od, remote.map((m) => (m['СкладПолучатель_Key'] ?? '').toString()).toSet());

      var added = 0, updated = 0, removed = 0, conflicts = 0;
      final remoteKeys = <String>{};
      for (final m in remote) {
        final key = m['Ref_Key'].toString();
        remoteKeys.add(key);
        final checkedElsewhere = (m['Комментарий'] ?? '').toString().contains(_checkedMark);
        final local = _Store.doc(prefs, key);
        final status = (local?['status'] ?? '').toString();
        if (status == 'sent') continue; // history, already in 1C

        if (checkedElsewhere) {
          if (local == null) continue;
          if (status == 'new') {
            await _Store.removeDoc(prefs, key);
            removed++;
          } else if (status != 'conflict') {
            local['status'] = 'conflict';
            local['error'] = 'Уже проверен на другом ТСД';
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

      // Local documents no longer among the unposted ones in 1C.
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
          d['error'] = 'Проведён, удалён или вне периода в 1С';
          await _Store.putDoc(prefs, d);
          conflicts++;
        }
      }

      if (mounted) setState(() => _busy = 'Загрузка товаров…');
      await _loadProducts(prefs, od);
      await _Store.cleanup(prefs);

      _toast('Загружено: новых $added, обновлено $updated, убрано $removed'
          '${conflicts > 0 ? ', конфликтов $conflicts' : ''}');
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _busy = null);
    await _refreshLocal();
  }

  Map<String, dynamic> _fromRemote(Map<String, dynamic> m, Map<String, String> names) => {
        'key': m['Ref_Key'].toString(),
        'number': (m['Number'] ?? '').toString(),
        'date': (m['Date'] ?? '').toString(),
        'receiver': names[(m['СкладПолучатель_Key'] ?? '').toString()] ?? '',
        'dataVersion': m['DataVersion'],
        'lines': [
          for (final row in ((m['Товары'] as List?) ?? const []).cast<Map<String, dynamic>>())
            {for (final e in row.entries) if (!e.key.contains('@')) e.key: e.value},
        ],
        'status': 'new',
        'loadedAt': DateTime.now().toIso8601String(),
      };

  /// Names, units and barcodes of all goods in the local documents
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
    for (final p in await od.getByKeys('Catalog_Номенклатура', 'Ref_Key', keys,
        'Ref_Key,Description,Артикул,Весовой,ЕдиницаИзмерения_Key')) {
      final e = fresh[p['Ref_Key'].toString()];
      if (e == null) continue;
      e['name'] = (p['Description'] ?? '').toString();
      e['article'] = (p['Артикул'] ?? '').toString();
      e['weight'] = p['Весовой'] == true;
      e['base'] = (p['ЕдиницаИзмерения_Key'] ?? _zeroGuid).toString();
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

  /// true = sent and removed from the TSD; false = 1C refused (status saved);
  /// throws _ODataError(network: true) when there is no connection.
  Future<bool> _sendOne(SharedPreferences prefs, Map<String, dynamic> d) async {
    final key = d['key'].toString();
    final od = _od;
    try {
      Map<String, dynamic> fresh;
      try {
        fresh = await od.getOne(_OData.entity('Document_ПеремещениеТоваров', key),
            {r'$select': 'Posted,DeletionMark,DataVersion,Комментарий'});
      } on _ODataError catch (e) {
        if (e.status == 404) throw _ODataError('Документ удалён в 1С', status: 409);
        rethrow;
      }
      if (fresh['Posted'] == true) throw _ODataError('Документ уже проведён в 1С', status: 409);
      if (fresh['DeletionMark'] == true) throw _ODataError('Документ помечен на удаление в 1С', status: 409);
      if (fresh['DataVersion'] != d['dataVersion']) {
        throw _ODataError('Изменён в 1С после загрузки', status: 409);
      }

      final result = d['result'] as Map<String, dynamic>;
      final old = (fresh['Комментарий'] ?? '').toString().trim();
      final log = result['log'].toString();
      await od.patch(_OData.entity('Document_ПеремещениеТоваров', key), {
        'Товары': result['rows'],
        'Комментарий': old.isEmpty ? log : '$old\n$log',
      });
      // Keep a light record for the «Отправленные» tab (no lines / goods).
      await _Store.putDoc(prefs, {
        'key': key,
        'number': d['number'],
        'date': d['date'],
        'receiver': d['receiver'],
        'status': 'sent',
        'sentAt': DateTime.now().toIso8601String(),
        'linesCount': (result['rows'] as List?)?.length ?? 0,
        'log': log,
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
    if (offline) {
      _toast('Нет связи с 1С — проверенные документы ждут отправки', error: true);
    } else if (failed > 0) {
      _toast('Отправлено $sent, не принято $failed (см. список)', error: true);
    } else {
      _toast('Отправлено в 1С: $sent. Проведите документы в 1С.');
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
        title: Text('№ ${d['number']}: конфликт'),
        content: Text('${d['error'] ?? ''}\n\nРезультат проверки с ТСД нельзя записать в 1С. '
            'Удалите документ с ТСД и нажмите «Загрузить», чтобы получить актуальную версию.'),
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
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('№ ${d['number']} · ${d['receiver'] ?? ''}'),
        content: SingleChildScrollView(
          child: Text('Отправлено в 1С: ${_date((d['sentAt'] ?? '').toString())}\n'
              'Строк: ${d['linesCount'] ?? 0}\n\n${(d['log'] ?? '').toString().replaceAll('; ', '\n')}\n\n'
              'Документ не проведён — проведите его в 1С.'),
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
    if (mounted) setState(() {});
  }

  // ── UI ──

  static const _statusText = {
    'new': 'новый',
    'work': 'в работе',
    'checked': 'проверен, ждёт отправки',
    'conflict': 'конфликт',
    'sent': 'отправлен в 1С',
  };

  static const _statusColor = {
    'work': Color(0xFFFFF59D),
    'checked': Color(0xFFC8E6C9),
    'conflict': Color(0xFFFFCDD2),
  };

  String _date(String s) {
    final d = DateTime.tryParse(s);
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase();
    final source = _tab == 0 ? _docs : _sent;
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
      list = const Center(child: Text('Отправленных за 7 дней нет'));
    } else if (_tab == 0 && _docs.isEmpty) {
      list = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              _noSettings ? 'Укажите в настройках адрес 1С и склад' : 'На ТСД нет накладных.\nНажмите «Загрузить».',
              textAlign: TextAlign.center,
            ),
            if (_noSettings && widget.onSettings != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: _openSettings, icon: const Icon(Icons.settings), label: const Text('Настройки')),
            ],
          ]),
        ),
      );
    } else {
      list = ListView.builder(
        itemCount: visible.length,
        itemBuilder: (ctx, i) {
          final d = visible[i];
          final status = (d['status'] ?? 'new').toString();
          final lines = (d['lines'] as List?)?.length ?? (d['linesCount'] as num?)?.toInt() ?? 0;
          final err = status == 'sent'
              ? _date((d['sentAt'] ?? '').toString())
              : (d['error'] ?? '').toString();
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            color: _statusColor[status],
            child: ListTile(
              onTap: busy ? null : () => _open(d),
              title: Text(
                  (d['receiver'] ?? '').toString().isEmpty ? '№ ${d['number']}' : d['receiver'].toString(),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('№ ${d['number']} · ${_date(d['date'].toString())} · строк: $lines\n'
                  '${_statusText[status] ?? status}${err.isEmpty ? '' : ' · $err'}'),
              isThreeLine: true,
              trailing: Icon(status == 'conflict'
                  ? Icons.warning_amber
                  : status == 'sent'
                      ? Icons.cloud_done
                      : Icons.chevron_right),
            ),
          );
        },
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _EdgeSwipeBack(
        child: SafeArea(
          child: Column(children: [
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.only(left: 12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _warehouseName.isEmpty ? 'Перемещения' : 'Перемещения · $_warehouseName',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onSettings != null)
                  IconButton(
                      tooltip: 'Настройки',
                      icon: const Icon(Icons.settings),
                      onPressed: busy ? null : _openSettings),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _download,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Загрузить'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy || toSend == 0 ? null : () => _sendAll(),
                    icon: const Icon(Icons.cloud_upload),
                    label: Text('Отправить ($toSend)'),
                  ),
                ),
              ]),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(children: [
                  const LinearProgressIndicator(),
                  Padding(padding: const EdgeInsets.all(4), child: Text(_busy!)),
                ]),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 0, label: Text('К проверке (${_docs.length})')),
                    ButtonSegment(value: 1, label: Text('Отправленные (${_sent.length})')),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _tab = v.first),
                ),
              ),
            ),
            if (source.length > 5)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Номер или магазин',
                    border: OutlineInputBorder(),
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
