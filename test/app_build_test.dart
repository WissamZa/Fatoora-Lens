import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/app.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:fatoora_lens/screens/home_screen.dart';

class _FakeDatabase extends DatabaseService {
  @override
  Future<void> initialize() async {}

  @override
  Future<List<Invoice>> getInvoices({String? search}) async => <Invoice>[];

  @override
  Future<List<Shop>> getShops() async => <Shop>[];

  @override
  Future<List<ShopCategory>> getShopCategories() async => <ShopCategory>[];

  @override
  Future<List<PaymentMethod>> getPaymentMethods() async => <PaymentMethod>[];

  @override
  Future<List<PaymentCard>> getPaymentCards() async => <PaymentCard>[];

  @override
  Future<String?> getSetting(String key) async => null;
}

void main() {
  testWidgets('renders FatooraLensApp without crashing', (tester) async {
    final db = _FakeDatabase();
    await tester.pumpWidget(FatooraLensApp(database: db));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders HomeScreen and finds all components', (tester) async {
    final db = _FakeDatabase();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeScreen(
            database: db,
            darkMode: false,
            onToggleTheme: () {},
            onToggleLanguage: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('عدسة فاتورة'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('الكاميرا'), findsOneWidget);
    expect(find.text('من صورة'), findsOneWidget);
    expect(find.text('إدخال يدوي (بدون باركود)'), findsOneWidget);
    expect(find.text('إجمالي الفواتير'), findsOneWidget);
    expect(find.text('إجمالي المبالغ'), findsOneWidget);
    expect(find.text('إجمالي الضريبة'), findsOneWidget);
    // The empty state sits below the fold; the lazy ListView only builds
    // it once it is scrolled into view.
    await tester.scrollUntilVisible(
      find.text('لا توجد فواتير محفوظة بعد'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('لا توجد فواتير محفوظة بعد'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
