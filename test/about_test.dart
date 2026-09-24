import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/screens/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

    await tester.tap(find.text('حول التطبيق'));
    await tester.pumpAndSettle();

    expect(find.text('الإصدار 9.9.9'), findsOneWidget);
    expect(find.text('WissamZa'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
