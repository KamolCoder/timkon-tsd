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

/// Settings page of the TSD app, stored on the device (SharedPreferences
/// `tsd_settings`) and read by TransferListWidget / TransferCheckWidget.
/// Sections: 1C (address, login, warehouse picked from 1C), Stock API (goods
/// catalog with photos: address + read-only API key), storekeeper name.
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
  static const _defaultStock = 'https://stock.timkon.uz';

  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _checker = TextEditingController();
  final _stockUrl = TextEditingController();
  final _stockKey = TextEditingController();

  String _warehouseKey = '';
  String _warehouseName = '';
  List<MapEntry<String, String>> _warehouses = [];

  bool _busy1c = false, _busyStock = false;
  bool _showPass = false, _showKey = false;
  String? _status1c, _statusStock;
  bool _ok1c = false, _okStock = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    for (final c in [_url, _user, _pass, _checker, _stockUrl, _stockKey]) {
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
      _warehouseKey = (m['warehouseKey'] ?? '').toString();
      _warehouseName = (m['warehouseName'] ?? '').toString();
      _stockUrl.text = (m['stockUrl'] ?? '').toString();
      _stockKey.text = (m['stockKey'] ?? '').toString();
    } catch (_) {}
    if (_url.text.isEmpty) _url.text = 'http://';
    if (_stockUrl.text.isEmpty) _stockUrl.text = _defaultStock;
    if (mounted) setState(() {});
  }

  String get _root => _url.text.trim().replaceAll(RegExp(r'/+$'), '');
  String get _stockRoot => _stockUrl.text.trim().replaceAll(RegExp(r'/+$'), '');

  /// Loads Catalog_Склады — also the connection test of 1C.
  Future<void> _test1c() async {
    setState(() {
      _busy1c = true;
      _status1c = null;
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
      _status1c = 'Связь с 1С есть ✓ Выберите склад ниже.';
      _ok1c = true;
    } catch (e) {
      _status1c = e is String ? e : 'Нет связи с 1С: $e';
      _ok1c = false;
    }
    if (mounted) setState(() => _busy1c = false);
  }

  Future<void> _testStock() async {
    setState(() {
      _busyStock = true;
      _statusStock = null;
    });
    try {
      final resp = await http.get(Uri.parse('$_stockRoot/api/stock/me'),
          headers: {'X-API-Key': _stockKey.text.trim(), 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401 || resp.statusCode == 403) throw 'Неверный ключ Stock API';
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      _statusStock = 'Каталог подключён ✓';
      _okStock = true;
    } catch (e) {
      _statusStock = e is String ? e : 'Нет связи со Stock API (нужен интернет): $e';
      _okStock = false;
    }
    if (mounted) setState(() => _busyStock = false);
  }

  Future<void> _save() async {
    String? problem;
    if (_root.length < 10 || _user.text.trim().isEmpty) problem = 'Заполните адрес и пользователя 1С';
    if (problem == null && _warehouseKey.isEmpty) problem = 'Выберите склад («Проверить связь с 1С»)';
    if (problem != null) {
      setState(() {
        _status1c = problem;
        _ok1c = false;
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
          'stockUrl': _stockRoot,
          'stockKey': _stockKey.text.trim(),
        }));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Настройки сохранены ✓')));
    if (widget.onSaved != null) {
      await widget.onSaved!();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, TextInputType? type, bool obscure = false, Widget? suffix, IconData? icon}) {
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
          prefixIcon: icon == null ? null : Icon(icon),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _status(String? text, bool ok) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline,
                size: 18, color: ok ? Colors.green.shade700 : Colors.red.shade700),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: TextStyle(color: ok ? Colors.green.shade800 : Colors.red.shade700))),
          ]),
        );

  Widget _testButton(String label, bool busy, VoidCallback onTap) => OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        icon: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.wifi_tethering),
        label: Text(label),
      );

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
                const Text('Настройки', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(12), children: [
                _section('1С', Icons.storage, [
                  _field(_url, 'Адрес 1С', hint: 'http://192.168.1.10/tbase', type: TextInputType.url, icon: Icons.link),
                  _field(_user, 'Пользователь 1С', icon: Icons.person_outline),
                  _field(_pass, 'Пароль 1С',
                      icon: Icons.lock_outline,
                      obscure: !_showPass,
                      suffix: IconButton(
                        icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPass = !_showPass),
                      )),
                  _testButton('Проверить связь с 1С', _busy1c, _test1c),
                  _status(_status1c, _ok1c),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Склад-отправитель',
                      prefixIcon: const Icon(Icons.warehouse_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _warehouseKey.isEmpty ? null : _warehouseKey,
                        isExpanded: true,
                        isDense: true,
                        hint: const Text('Сначала «Проверить связь с 1С»'),
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
                ]),
                _section('Каталог и фото (Stock API)', Icons.photo_library_outlined, [
                  const Text('Названия и фото всех товаров — чтобы узнать товар не из накладной. '
                      'Нужен интернет при загрузке.',
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 10),
                  _field(_stockUrl, 'Адрес Stock API', type: TextInputType.url, icon: Icons.link),
                  _field(_stockKey, 'Ключ API (только чтение)',
                      icon: Icons.key_outlined,
                      obscure: !_showKey,
                      suffix: IconButton(
                        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      )),
                  _testButton('Проверить каталог', _busyStock, _testStock),
                  _status(_statusStock, _okStock),
                ]),
                _section('Кладовщик', Icons.badge_outlined, [
                  _field(_checker, 'ФИО (пишется в комментарий 1С)', icon: Icons.person),
                ]),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Сохранить', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Swipe from the left edge → back (Navigator.maybePop).
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
