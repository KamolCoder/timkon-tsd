import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/settings_page.dart';
import 'screens/transfer_check_page.dart';
import 'screens/transfer_list_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const TsdApp());
}

class TsdApp extends StatelessWidget {
  const TsdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ТСД Timkon',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF11796F)),
        useMaterial3: true,
      ),
      home: const _ListPage(),
    );
  }
}

/// Each page = one full-screen widget (as on the FlutterFlow pages, no AppBar).
class _ListPage extends StatelessWidget {
  const _ListPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TransferListWidget(
        width: double.infinity,
        height: double.infinity,
        onOpen: (key) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: TransferCheckWidget(width: double.infinity, height: double.infinity, transferKey: key),
          ),
        )),
        onSettings: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: TsdSettingsWidget(width: double.infinity, height: double.infinity),
          ),
        )),
      ),
    );
  }
}
