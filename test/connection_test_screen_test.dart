import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/screens/connection_test_screen.dart';

void main() {
  testWidgets('connection test screen renders its three modes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: [Locale('en'), Locale('ar')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ConnectionTestScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Self test (no second device)'), findsOneWidget);
    expect(find.text('Host the test on this network'), findsOneWidget);
    expect(find.text('Connect to the hosting device'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
