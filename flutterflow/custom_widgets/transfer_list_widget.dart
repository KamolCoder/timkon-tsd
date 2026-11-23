// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import '/custom_code/actions/index.dart'; // Imports custom actions
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// List of unposted «Перемещение товаров» from the warehouse that the TSD has
/// not checked yet (no «Проверено ТСД» in the comment). Tap → [onOpen] with
/// the document Ref_Key; the list reloads when that action finishes (i.e.
/// after Navigate Back from the check page).
class TransferListWidget extends StatefulWidget {
  const TransferListWidget({
    super.key,
    this.width,
    this.height,
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.warehouseKey,
    this.daysBack = 7,
    this.onOpen,
  });

  final double? width;
  final double? height;

  /// e.g. http://192.168.1.10/tbase
  final String baseUrl;
  final String username;
  final String password;

  /// Ref_Key of the sender warehouse (Склад_Key)
  final String warehouseKey;
  final int daysBack;

  /// Action with one String parameter: transferKey → navigate to the check page
  final Future Function(String transferKey)? onOpen;

  @override
  State<TransferListWidget> createState() => _TransferListWidgetState();
}

class _TransferRow {
  _TransferRow(this.key, this.number, this.date, this.receiver, this.started);
  final String key;
  final String number;
  final DateTime? date;
  final String receiver;

  /// a check of this document was started on this TSD (local progress exists)
  final bool started;
}

class _TransferListWidgetState extends State<TransferListWidget> {
  static const _checkedMark = 'Проверено ТСД';

  bool _loading = true;
  String? _error;
  List<_TransferRow> _rows = [];
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TransferListWidget old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl ||
        old.warehouseKey != widget.warehouseKey ||
        old.username != widget.username ||
        old.password != widget.password ||
        old.daysBack != widget.daysBack) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.baseUrl.trim().isEmpty || widget.warehouseKey.trim().isEmpty) {
        throw 'Заполните в настройках адрес 1С и склад';
      }
      final root = widget.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final since = DateTime.now().subtract(Duration(days: widget.daysBack < 0 ? 0 : widget.daysBack));
      String two(int v) => v.toString().padLeft(2, '0');
      final sinceStr = '${since.year}-${two(since.month)}-${two(since.day)}T00:00:00';

      // Minimal request: no lines, no $expand — store names come from the local cache.
      final docs = await _get(root, 'Document_ПеремещениеТоваров', {
        r'$filter': "Склад_Key eq guid'${widget.warehouseKey.trim()}' and Posted eq false "
            "and DeletionMark eq false and Date ge datetime'$sinceStr'",
        r'$select': 'Ref_Key,Number,Date,Комментарий,СкладПолучатель_Key',
        r'$orderby': 'Date desc',
      });
      final pending = docs.where((m) => !(m['Комментарий'] ?? '').toString().contains(_checkedMark)).toList();

      final prefs = await SharedPreferences.getInstance();
      final names = await _warehouseNames(
          prefs, root, pending.map((m) => (m['СкладПолучатель_Key'] ?? '').toString()).toSet());

      _rows = [
        for (final m in pending)
          _TransferRow(
            m['Ref_Key'].toString(),
            (m['Number'] ?? '').toString(),
            DateTime.tryParse((m['Date'] ?? '').toString()),
            names[(m['СкладПолучатель_Key'] ?? '').toString()] ?? '',
            prefs.containsKey('tsdcheck_${m['Ref_Key']}'),
          )
      ];
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<List<Map<String, dynamic>>> _get(String root, String entity, Map<String, String> params) async {
    final query = {r'$format': 'json', ...params}
        .entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final uri = Uri.parse('$root/odata/standard.odata/${Uri.encodeComponent(entity)}?$query');
    http.Response resp;
    try {
      resp = await http.get(uri, headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('${widget.username}:${widget.password}'))}',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw 'Нет связи с 1С ($root): $e';
    }
    if (resp.statusCode == 401) throw '1С: неверный логин или пароль';
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode != 200) throw '1С: HTTP ${resp.statusCode} $body';
    return (((jsonDecode(body) as Map)['value'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Warehouse names cached on the TSD for 24 h; reloaded (≈30 rows) only
  /// when the cache is old or a store is missing in it.
  Future<Map<String, String>> _warehouseNames(SharedPreferences prefs, String root, Set<String> needed) async {
    const key = 'tsdc_wh';
    Map<String, String> names = {};
    var fresh = false;
    try {
      final m = jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
      final ts = (m['ts'] as num?)?.toInt() ?? 0;
      fresh = DateTime.now().millisecondsSinceEpoch - ts < const Duration(hours: 24).inMilliseconds;
      names = (m['names'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {}
    final missing = needed.where((k) => k.isNotEmpty && !names.containsKey(k));
    if (fresh && missing.isEmpty) return names;
    try {
      final rows = await _get(root, 'Catalog_Склады', {r'$select': 'Ref_Key,Description'});
      names = {for (final r in rows) r['Ref_Key'].toString(): (r['Description'] ?? '').toString()};
      await prefs.setString(key, jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'names': names}));
    } catch (_) {
      // Names are cosmetic: show the list anyway.
    }
    return names;
  }

  Future<void> _open(_TransferRow row) async {
    if (widget.onOpen == null) return;
    await widget.onOpen!(row.key);
    if (mounted) await _load();
  }

  String _date(DateTime? d) {
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase();
    final visible = q.isEmpty
        ? _rows
        : _rows.where((r) => r.number.toLowerCase().contains(q) || r.receiver.toLowerCase().contains(q)).toList();

    Widget list;
    if (_loading) {
      list = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      list = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Повторить')),
          ]),
        ),
      );
    } else {
      list = RefreshIndicator(
        onRefresh: _load,
        child: visible.isEmpty
            ? ListView(children: const [
                SizedBox(height: 120),
                Center(child: Text('Нет перемещений для проверки')),
              ])
            : ListView.builder(
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  final r = visible[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    color: r.started ? const Color(0xFFFFF59D) : null,
                    child: ListTile(
                      onTap: () => _open(r),
                      title: Text(r.receiver.isEmpty ? '№ ${r.number}' : r.receiver,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('№ ${r.number} · ${_date(r.date)}'
                          '${r.started ? ' · проверка начата' : ''}'),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  );
                },
              ),
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(children: [
            Expanded(
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
            IconButton(tooltip: 'Обновить', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
          ]),
        ),
        Expanded(child: list),
      ]),
    );
  }
}
