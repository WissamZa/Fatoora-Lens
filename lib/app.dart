import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/database_service.dart';
import 'screens/home_screen.dart';

class FatooraLensApp extends StatefulWidget {
  const FatooraLensApp({required this.database, super.key});

  final DatabaseService database;

  @override
  State<FatooraLensApp> createState() => _FatooraLensAppState();
}

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({required this.error, this.stackTrace, super.key});

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0A7A67)),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('عدسة فاتورة')),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 64, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    const Text('تعذر تشغيل قاعدة البيانات', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    SelectableText('$error', textAlign: TextAlign.center),
                    if (stackTrace != null) ...[
                      const SizedBox(height: 14),
                      ExpansionTile(title: const Text('تفاصيل الخطأ'), children: [SelectableText('$stackTrace')]),
                    ],
                    const SizedBox(height: 18),
                    const Text('أغلق التطبيق وافتحه مرة أخرى. إذا استمر الخطأ أرسل تفاصيل الخطأ الظاهرة أعلاه.', textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FatooraLensAppState extends State<FatooraLensApp> {
  bool _darkMode = false;
  bool _english = false;
  bool _settingsLoaded = false;
  String? _settingsError;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final dark = await widget.database.getSetting('dark_mode');
      final language = await widget.database.getSetting('language');
      if (!mounted) return;
      setState(() {
        _darkMode = dark == 'true';
        _english = language == 'en';
        _settingsLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsError = '$error';
        _settingsLoaded = true;
      });
    }
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
      title: _english ? 'Fatoora Lens' : 'عدسة فاتورة',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      locale: locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: !_settingsLoaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _settingsError != null
              ? InitializationErrorPage(error: _settingsError!)
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

class InitializationErrorPage extends StatelessWidget {
  const InitializationErrorPage({required this.error, super.key});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('عدسة فاتورة')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 64, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text('تعذر تحميل إعدادات التطبيق', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                SelectableText(error, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                const Text('أرسل نص الخطأ الظاهر للمطور بدل ظهور صفحة فارغة.', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
