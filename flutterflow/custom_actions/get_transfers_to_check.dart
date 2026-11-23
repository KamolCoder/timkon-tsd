// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/actions/index.dart'; // Imports other custom actions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Unposted transfers from [warehouseKey] for the last [daysBack] days that
/// were not checked by the TSD yet (no «Проверено ТСД» mark in the comment).
///
/// Returns a JSON list for a ListView, newest first:
/// `[{key, number, date, receiver, comment}]`.
/// Throws a readable message (String) on connection / 1C errors.
Future<List<dynamic>> getTransfersToCheck(
  String baseUrl,
  String username,
  String password,
  String warehouseKey,
  int daysBack,
) async {
  const checkedMark = 'Проверено ТСД';
  final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final since = DateTime.now().subtract(Duration(days: daysBack < 0 ? 0 : daysBack));
  final sinceStr =
      '${since.year.toString().padLeft(4, '0')}-${since.month.toString().padLeft(2, '0')}-'
      '${since.day.toString().padLeft(2, '0')}T00:00:00';

  final auth = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Future<List<Map<String, dynamic>>> get(String entity, Map<String, String> params) async {
    final query = {r'$format': 'json', ...params}
        .entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final uri = Uri.parse('$root/odata/standard.odata/${Uri.encodeComponent(entity)}?$query');
    http.Response resp;
    try {
      resp = await http.get(uri, headers: {'Authorization': auth, 'Accept': 'application/json'})
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw 'Нет связи с 1С ($root): $e';
    }
    if (resp.statusCode == 401) throw '1С: неверный логин или пароль';
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode != 200) throw '1С: HTTP ${resp.statusCode} $body';
    return (((jsonDecode(body) as Map)['value'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  // Minimal request: no lines, no $expand.
  final docs = await get('Document_ПеремещениеТоваров', {
    r'$filter': "Склад_Key eq guid'${warehouseKey.trim()}' and Posted eq false "
        "and DeletionMark eq false and Date ge datetime'$sinceStr'",
    r'$select': 'Ref_Key,Number,Date,Комментарий,СкладПолучатель_Key',
    r'$orderby': 'Date desc',
  });
  final pending = docs.where((m) => !(m['Комментарий'] ?? '').toString().contains(checkedMark)).toList();

  // Store names: local cache for 24 h (shared with TransferListWidget).
  final prefs = await SharedPreferences.getInstance();
  Map<String, String> names = {};
  var fresh = false;
  try {
    final m = jsonDecode(prefs.getString('tsdc_wh') ?? '{}') as Map<String, dynamic>;
    fresh = DateTime.now().millisecondsSinceEpoch - ((m['ts'] as num?)?.toInt() ?? 0) <
        const Duration(hours: 24).inMilliseconds;
    names = (m['names'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {}
  final needReload = !fresh ||
      pending.any((m) {
        final k = (m['СкладПолучатель_Key'] ?? '').toString();
        return k.isNotEmpty && !names.containsKey(k);
      });
  if (needReload) {
    try {
      final rows = await get('Catalog_Склады', {r'$select': 'Ref_Key,Description'});
      names = {for (final r in rows) r['Ref_Key'].toString(): (r['Description'] ?? '').toString()};
      await prefs.setString('tsdc_wh', jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'names': names}));
    } catch (_) {}
  }

  return [
    for (final m in pending)
      {
        'key': m['Ref_Key'],
        'number': m['Number'],
        'date': m['Date'],
        'receiver': names[(m['СкладПолучатель_Key'] ?? '').toString()] ?? '',
        'comment': m['Комментарий'] ?? '',
      }
  ];
}
