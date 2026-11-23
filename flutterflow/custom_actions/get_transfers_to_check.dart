// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/actions/index.dart'; // Imports other custom actions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Unposted transfers from [warehouseKey] for the last [daysBack] days that
/// were not checked by the TSD yet (no «Проверено ТСД» mark in the comment).
///
/// Returns a JSON list for a ListView, newest first:
/// `[{key, number, date, receiver, lines, comment}]`.
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

  final filter = "Склад_Key eq guid'${warehouseKey.trim()}' and Posted eq false "
      "and DeletionMark eq false and Date ge datetime'$sinceStr'";
  final params = <String, String>{
    r'$format': 'json',
    r'$filter': filter,
    r'$expand': 'СкладПолучатель',
    r'$select': 'Ref_Key,Number,Date,Комментарий,Товары,СкладПолучатель/Description',
    r'$orderby': 'Date desc',
  };
  final query = params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  final uri = Uri.parse(
      '$root/odata/standard.odata/${Uri.encodeComponent('Document_ПеремещениеТоваров')}?$query');

  final auth = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  http.Response resp;
  try {
    resp = await http.get(uri, headers: {
      'Authorization': auth,
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 30));
  } catch (e) {
    throw 'Нет связи с 1С ($root): $e';
  }
  if (resp.statusCode == 401) throw '1С: неверный логин или пароль';
  if (resp.statusCode != 200) {
    throw '1С: HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}';
  }

  final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  final rows = (data['value'] as List?) ?? const [];
  final result = <dynamic>[];
  for (final row in rows) {
    final m = row as Map<String, dynamic>;
    final comment = (m['Комментарий'] ?? '').toString();
    if (comment.contains(checkedMark)) continue;
    final receiver = m['СкладПолучатель'];
    result.add({
      'key': m['Ref_Key'],
      'number': m['Number'],
      'date': m['Date'],
      'receiver': receiver is Map ? (receiver['Description'] ?? '') : '',
      'lines': (m['Товары'] as List?)?.length ?? 0,
      'comment': comment,
    });
  }
  return result;
}
