import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:fatoora_lens/screens/period_report_screen.dart';

class _FakeDatabase extends DatabaseService {
  _FakeDatabase(this.invoices);

  final List<Invoice> invoices;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Invoice>> getInvoices({String? search}) async => invoices;

  @override
  Future<List<Shop>> getShops() async => const [];

  @override
  Future<List<ShopCategory>> getShopCategories() async => const [];

  @override
  Future<List<PaymentMethod>> getPaymentMethods() async => const [];

  @override
  Future<List<PaymentCard>> getPaymentCards() async => const [];

  @override
  Future<String?> getSetting(String key) async => null;
}

Widget _wrap(DatabaseService database) => MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: PeriodReportScreen(database: database),
      ),
    );

void main() {
  testWidgets('renders the period selector and empty state on first open',
      (tester) async {
    await tester.pumpWidget(_wrap(_FakeDatabase(const [])));
    await tester.pumpAndSettle();

    expect(find.text('تقارير الفترات'), findsOneWidget);
    expect(find.text('يومي'), findsOneWidget);
    expect(find.text('أسبوعي'), findsOneWidget);
    expect(find.text('شهري'), findsOneWidget);
    expect(find.text('سنوي'), findsOneWidget);
    expect(find.text('فواتير الفترة'), findsOneWidget);
    expect(find.text('لا توجد فواتير في هذه الفترة.'), findsOneWidget);
    expect(find.text('مقارنة بالفترة السابقة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to a period with invoices shows totals and the '
      'invoice list', (tester) async {
    final now = DateTime.now();
    final database = _FakeDatabase([
      Invoice(
        sellerName: 'سوبرماركت الحي',
        vatNumber: '300555444333003',
        issuedAt: now.subtract(const Duration(hours: 2)),
        totalAmount: 115,
        vatAmount: 15,
        rawPayload: 'manual:one',
      ),
      Invoice(
        sellerName: 'مقهى الركن',
        vatNumber: '300777777777773',
        issuedAt: now.subtract(const Duration(days: 400)),
        totalAmount: 999,
        vatAmount: 99,
        rawPayload: 'manual:two',
      ),
    ]);
    await tester.pumpWidget(_wrap(database));
    await tester.pumpAndSettle();

    // The current month holds the first invoice only; the year view
    // excludes the 400-day-old one as well, but the day view shows the
    // invoice of "today" only when it is still within the current day.
    expect(find.text('سوبرماركت الحي'), findsOneWidget);
    expect(find.text('مقهى الركن'), findsNothing);

    // Switch to the yearly period via its segment.
    await tester.tap(find.text('سنوي'));
    await tester.pumpAndSettle();
    expect(find.text('سوبرماركت الحي'), findsOneWidget);

    // Switch to the daily period and navigate back and forth.
    await tester.tap(find.text('يومي'));
    await tester.pumpAndSettle();
    expect(find.text('سوبرماركت الحي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
