import 'package:flutter/material.dart';

import 'data/database_service.dart';
import 'screens/home_screen.dart';

class ZakatInvoiceApp extends StatefulWidget {
  const ZakatInvoiceApp({required this.database, super.key});

  final DatabaseService database;

  @override
  State<ZakatInvoiceApp> createState() => _ZakatInvoiceAppState();
}

class _ZakatInvoiceAppState extends State<ZakatInvoiceApp> {
  bool _darkMode = false;
  bool _english = false;
  bool _settingsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final dark = await widget.database.getSetting('dark_mode');
    final language = await widget.database.getSetting('language');
    if (!mounted) return;
    setState(() {
      _darkMode = dark == 'true';
      _english = language == 'en';
      _settingsLoaded = true;
    });
  }

  Future<void> _toggleTheme() async {
    setState(() => _darkMode = !_darkMode);
    await widget.database.setSetting('dark_mode', _darkMode.toString());
  }

  Future<void> _toggleLanguage() async {
    setState(() => _english = !_english);
    await widget.database.setSetting('language', _english ? 'en' : 'ar');
  }

  ThemeData _theme(Brightness brightness) {
    const primary = Color(0xFF0A7A67);
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF101614)
          : const Color(0xFFF6F8F7),
      fontFamily: 'sans',
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: brightness == Brightness.dark ? const Color(0xFF19221F) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = Locale(_english ? 'en' : 'ar');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _english ? 'Zakat Invoices' : 'فواتير الزكاة',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      locale: locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      home: !_settingsLoaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : Directionality(
              textDirection: _english ? TextDirection.ltr : TextDirection.rtl,
              child: HomeScreen(
                database: widget.database,
                darkMode: _darkMode,
                onToggleTheme: _toggleTheme,
                onToggleLanguage: _toggleLanguage,
              ),
            ),
    );
  }
}
