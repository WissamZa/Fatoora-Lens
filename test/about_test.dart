import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/screens/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('about dialog shows the platform version, not a hardcoded one', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'fatoora_lens',
      packageName: 'com.fatooralens.app',
      version: '9.9.9',
      buildNumber: '9000009',
      buildSignature: 'mock',
    );

    // The settings UI never touches the database in this test, so an
    // uninitialized instance is enough to satisfy the dependency.
    final database = DatabaseService(
      databasePath: '/tmp/about_test_settings.db',
      databaseFactory: databaseFactoryFfi,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: SettingsTab(
            database: database,
            darkMode: false,
            onToggleTheme: () {},
            onToggleLanguage: () {},
            onExportCsv: () {},
            onBackup: () {},
            onRestore: () {},
            onPdf: () {},
          ),
        ),
      ),
    );

    // The about card sits below the sync entries added in v1.1.x, so the
    // list must be scrolled (progressively, for the lazy ListView) before
    // the card is hittable in the test viewport.
    await tester.scrollUntilVisible(
      find.text('حول التطبيق'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('حول التطبيق'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حول التطبيق'));
    await tester.pumpAndSettle();

    expect(find.text('الإصدار 9.9.9'), findsOneWidget);
    expect(find.text('WissamZa'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
