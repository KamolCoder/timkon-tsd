// Automatic FlutterFlow imports
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Settings page of the TSD app. Stored on the device (SharedPreferences key
/// `tsd_settings`) and read by TransferListWidget / TransferCheckWidget, so
/// FlutterFlow needs no App State. The warehouse is picked from 1C.
class TsdSettingsWidget extends StatefulWidget {
  const TsdSettingsWidget({
    super.key,
    this.width,
    this.height,
    this.onSaved,
  });

  final double? width;
  final double? height;

  /// After «Сохранить». Default: go back (Navigator.maybePop).
  final Future Function()? onSaved;

  @override
  State<TsdSettingsWidget> createState() => _TsdSettingsWidgetState();
}

class _TsdSettingsWidgetState extends State<TsdSettingsWidget> {
  static const _prefsKey = 'tsd_settings';

  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _checker = TextEditingController();
  final _days = TextEditingController(text: '7');

  String _warehouseKey = '';
  String _warehouseName = '';
  List<MapEntry<String, String>> _warehouses = [];

  bool _busy = false;
  bool _showPass = false;
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    for (final c in [_url, _user, _pass, _checker, _days]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final m = jsonDecode(prefs.getString(_prefsKey) ?? '{}') as Map<String, dynamic>;
      _url.text = (m['baseUrl'] ?? '').toString();
      _user.text = (m['username'] ?? '').toString();
      _pass.text = (m['password'] ?? '').toString();
      _checker.text = (m['checkerName'] ?? '').toString();
      _days.text = (m['daysBack'] ?? 7).toString();
      _warehouseKey = (m['warehouseKey'] ?? '').toString();
      _warehouseName = (m['warehouseName'] ?? '').toString();
    } catch (_) {}
    if (_url.text.isEmpty) _url.text = 'http://';
    if (mounted) setState(() {});
  }

  String get _root => _url.text.trim().replaceAll(RegExp(r'/+$'), '');

  /// Loads Catalog_Склады — also serves as the connection test.
  Future<void> _loadWarehouses() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final q = {r'$format': 'json', r'$select': 'Ref_Key,Description,IsFolder,DeletionMark'}
          .entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final uri = Uri.parse('$_root/odata/standard.odata/${Uri.encodeComponent('Catalog_Склады')}?$q');
      final resp = await http.get(uri, headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('${_user.text}:${_pass.text}'))}',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401) throw 'Неверный логин или пароль 1С';
      if (resp.statusCode == 404) throw 'Не найдено: проверьте адрес (http://IP/имя_публикации)';
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final rows = ((jsonDecode(utf8.decode(resp.bodyBytes))['value'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((r) => r['IsFolder'] != true && r['DeletionMark'] != true)
          .map((r) => MapEntry(r['Ref_Key'].toString(), (r['Description'] ?? '').toString()))
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      _warehouses = rows;
      _status = 'Связь есть, складов: ${rows.length}';
      _statusOk = true;
    } catch (e) {
      _status = e is String ? e : 'Нет связи с 1С: $e';
      _statusOk = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    if (_root.length < 10 || _user.text.trim().isEmpty) {
      setState(() {
        _status = 'Заполните адрес и пользователя 1С';
        _statusOk = false;
      });
      return;
    }
    if (_warehouseKey.isEmpty) {
      setState(() {
        _status = 'Выберите склад (кнопка «Проверить связь»)';
        _statusOk = false;
      });
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey,
        jsonEncode({
          'baseUrl': _root,
          'username': _user.text.trim(),
          'password': _pass.text,
          'warehouseKey': _warehouseKey,
          'warehouseName': _warehouseName,
          'checkerName': _checker.text.trim(),
          'daysBack': int.tryParse(_days.text.trim()) ?? 7,
        }));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Настройки сохранены')));
    if (widget.onSaved != null) {
      await widget.onSaved!();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, TextInputType? type, bool obscure = false, Widget? suffix}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: type,
        obscureText: obscure,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [..._warehouses];
    if (_warehouseKey.isNotEmpty && !items.any((e) => e.key == _warehouseKey)) {
      items.insert(0, MapEntry(_warehouseKey, _warehouseName.isEmpty ? _warehouseKey : _warehouseName));
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
            child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
              const Text('Настройки', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(12), children: [
              _field(_url, 'Адрес 1С', hint: 'http://192.168.1.10/tbase', type: TextInputType.url),
              _field(_user, 'Пользователь 1С'),
              _field(_pass, 'Пароль 1С',
                  obscure: !_showPass,
                  suffix: IconButton(
                    icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPass = !_showPass),
                  )),
              OutlinedButton.icon(
                onPressed: _busy ? null : _loadWarehouses,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Проверить связь и загрузить склады'),
              ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_status!,
                      style: TextStyle(color: _statusOk ? Colors.green.shade800 : Colors.red.shade700)),
                ),
              const SizedBox(height: 8),
              InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Склад-отправитель', isDense: true, border: OutlineInputBorder()),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _warehouseKey.isEmpty ? null : _warehouseKey,
                    isExpanded: true,
                    isDense: true,
                    hint: const Text('Нажмите «Проверить связь»'),
                    items: [
                      for (final e in items)
                        DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() {
                      _warehouseKey = v ?? '';
                      _warehouseName =
                          items.firstWhere((e) => e.key == v, orElse: () => const MapEntry('', '')).value;
                    }),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _field(_checker, 'Кладовщик (ФИО для комментария в 1С)'),
              _field(_days, 'Показывать перемещения за дней', type: TextInputType.number),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Сохранить')),
            ),
          ),
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
