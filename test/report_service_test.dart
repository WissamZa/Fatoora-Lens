import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:fatoora_lens/services/report_service.dart';

Invoice _invoice({
  required DateTime issuedAt,
  double amount = 115,
  String vat = '300000000000003',
  String name = 'متجر',
  String? methodId,
}) =>
    Invoice(
      sellerName: name,
      vatNumber: vat,
      issuedAt: issuedAt,
      totalAmount: amount,
      vatAmount: amount * 0.15,
      rawPayload: 'payload',
      paymentMethodId: methodId,
    );

void main() {
  group('PeriodRange.containing', () {
    test('day range spans exactly one local day', () {
      final range = PeriodRange.containing(
        ReportPeriod.day,
        DateTime(2026, 9, 29, 18, 30),
      );
      expect(range.start, DateTime(2026, 9, 29));
      expect(range.endExclusive, DateTime(2026, 9, 30));
    });

    test('week starts on Saturday (ar_SA convention)', () {
      // 2026-09-29 is a Tuesday; its week starts Saturday 2026-09-26.
      final range = PeriodRange.containing(
        ReportPeriod.week,
        DateTime(2026, 9, 29, 9),
      );
      expect(range.start, DateTime(2026, 9, 26));
      expect(range.endExclusive, DateTime(2026, 10, 3));
      expect(range.start.weekday, DateTime.saturday);
      // A Saturday itself starts its own week.
      final ownWeek = PeriodRange.containing(
        ReportPeriod.week,
        DateTime(2026, 9, 26),
      );
      expect(ownWeek.start, DateTime(2026, 9, 26));
    });

    test('month and year ranges are calendar-accurate', () {
      final month = PeriodRange.containing(
        ReportPeriod.month,
        DateTime(2026, 9, 29),
      );
      expect(month.start, DateTime(2026, 9, 1));
      expect(month.endExclusive, DateTime(2026, 10, 1));

      final year = PeriodRange.containing(
        ReportPeriod.year,
        DateTime(2026, 9, 29),
      );
      expect(year.start, DateTime(2026, 1, 1));
      expect(year.endExclusive, DateTime(2027, 1, 1));
    });

    test('previous() and next() step one unit and round-trip', () {
      final week = PeriodRange.containing(ReportPeriod.week, DateTime(2026, 9, 29));
      expect(week.previous().start, DateTime(2026, 9, 19));
      expect(week.next().start, DateTime(2026, 10, 3));

      final month = PeriodRange.containing(ReportPeriod.month, DateTime(2026, 9, 29));
      expect(month.previous().start, DateTime(2026, 8, 1));
      expect(month.next().start, DateTime(2026, 10, 1));

      final year = PeriodRange.containing(ReportPeriod.year, DateTime(2026, 9, 29));
      expect(year.previous().start, DateTime(2025, 1, 1));
      expect(year.next().start, DateTime(2027, 1, 1));

      // next().previous() returns to the original range.
      expect(week.next().previous(), week);
    });

    test('end bound is exclusive', () {
      final range = PeriodRange.containing(
        ReportPeriod.day,
        DateTime(2026, 9, 29),
      );
      expect(range.contains(DateTime(2026, 9, 29, 23, 59, 59)), isTrue);
      expect(range.contains(DateTime(2026, 9, 30)), isFalse);
    });

    test('buckets: week and month are daily, year is monthly', () {
      final week = PeriodRange.containing(ReportPeriod.week, DateTime(2026, 9, 29));
      final weekBuckets = week.buckets();
      expect(weekBuckets, hasLength(7));
      expect(weekBuckets.first.start, DateTime(2026, 9, 26));
      expect(weekBuckets.last.start, DateTime(2026, 10, 2));

      final month = PeriodRange.containing(ReportPeriod.month, DateTime(2026, 9, 29));
      expect(month.buckets(), hasLength(30));

      final year = PeriodRange.containing(ReportPeriod.year, DateTime(2026, 9, 29));
      final yearBuckets = year.buckets();
      expect(yearBuckets, hasLength(12));
      expect(yearBuckets.first.period, ReportPeriod.month);
      expect(yearBuckets.first.start, DateTime(2026, 1, 1));
    });
  });

  group('PeriodTotals', () {
    test('sums count, amount, tax and average', () {
      final totals = PeriodTotals.of([
        _invoice(issuedAt: DateTime(2026, 9, 1), amount: 100),
        _invoice(issuedAt: DateTime(2026, 9, 2), amount: 200),
      ]);
      expect(totals.count, 2);
      expect(totals.amount, 300);
      expect(totals.average, 150);
    });

    test('changeOver compares against the previous period', () {
      const current = PeriodTotals(count: 1, amount: 125, tax: 0);
      const previous = PeriodTotals(count: 1, amount: 100, tax: 0);
      expect(current.changeOver(previous), closeTo(25, 0.001));
      const empty = PeriodTotals(count: 0, amount: 0, tax: 0);
      expect(current.changeOver(empty), isNull);
    });
  });

  group('period filtering and aggregation', () {
    const categories = [
      ShopCategory(id: 'cat-market', name: 'سوبرماركت', nameEn: 'Supermarket'),
      ShopCategory(id: 'cat-barber', name: 'حلاق', nameEn: 'Barber'),
    ];
    const methods = [
      PaymentMethod(id: 'pm-mada', name: 'شبكة', nameEn: 'Mada'),
      PaymentMethod(id: 'pm-cash', name: 'نقدي', nameEn: 'Cash'),
    ];
    const shops = [
      Shop(
        id: 1,
        nameAr: 'بندة',
        displayName: 'بندة ماركت',
        vatNumber: '300111111111113',
        note: '',
        categoryId: 'cat-market',
        invoices: [],
      ),
      Shop(
        id: 2,
        nameAr: 'صالون الأناقة',
        vatNumber: '300222222222223',
        note: '',
        categoryId: 'cat-barber',
        invoices: [],
      ),
      Shop(
        id: 3,
        nameAr: 'محل بلا تصنيف',
        vatNumber: '',
        note: '',
        invoices: [],
      ),
    ];

    test('invoicesIn filters by range and sorts newest first', () {
      final invoices = [
        _invoice(issuedAt: DateTime(2026, 9, 1, 10)),
        _invoice(issuedAt: DateTime(2026, 9, 3, 12), name: 'أحدث'),
        _invoice(issuedAt: DateTime(2026, 8, 30, 9)),
      ];
      final september = PeriodRange.containing(ReportPeriod.month, DateTime(2026, 9, 15));
      final inSeptember = september.invoicesIn(invoices);
      expect(inSeptember, hasLength(2));
      expect(inSeptember.first.sellerName, 'أحدث');
    });

    test('totalsByCategory joins through the shop identity', () {
      final invoices = [
        _invoice(
          issuedAt: DateTime(2026, 9, 1),
          vat: '300111111111113',
          amount: 100,
        ),
        _invoice(
          issuedAt: DateTime(2026, 9, 2),
          vat: '300222222222223',
          name: 'صالون الأناقة',
          amount: 50,
        ),
        _invoice(
          issuedAt: DateTime(2026, 9, 3),
          vat: '',
          name: 'محل بلا تصنيف',
          amount: 25,
        ),
      ];
      final slices = totalsByCategory(
        invoices: invoices,
        shops: shops,
        categories: categories,
        uncategorizedLabel: 'غير مصنّف',
        english: false,
      );
      expect(slices.map((s) => s.label).toList(), ['سوبرماركت', 'حلاق', 'غير مصنّف']);
      expect(slices.map((s) => s.total).toList(), [100, 50, 25]);

      final englishSlices = totalsByCategory(
        invoices: invoices,
        shops: shops,
        categories: categories,
        uncategorizedLabel: 'Uncategorized',
        english: true,
      );
      expect(englishSlices.first.label, 'Supermarket');
    });

    test('a shop whose category was deleted lands in uncategorized', () {
      final invoices = [
        _invoice(issuedAt: DateTime(2026, 9, 1), vat: '300111111111113'),
      ];
      final slices = totalsByCategory(
        invoices: invoices,
        shops: shops,
        categories: const [], // category rows are gone
        uncategorizedLabel: 'غير مصنّف',
        english: false,
      );
      expect(slices.single.label, 'غير مصنّف');
      expect(slices.single.total, 115);
    });

    test('totalsByPaymentMethod groups by method name, tombstoned methods '
        'fall into unspecified, and empty unspecified is dropped', () {
      final invoices = [
        _invoice(issuedAt: DateTime(2026, 9, 1), methodId: 'pm-mada', amount: 100),
        _invoice(issuedAt: DateTime(2026, 9, 2), methodId: 'pm-mada', amount: 60),
        _invoice(issuedAt: DateTime(2026, 9, 3), methodId: 'pm-cash', amount: 40),
        _invoice(issuedAt: DateTime(2026, 9, 4), methodId: 'pm-gone', amount: 20),
        _invoice(issuedAt: DateTime(2026, 9, 5), amount: 5),
      ];
      final slices = totalsByPaymentMethod(
        invoices: invoices,
        methods: methods,
        unspecifiedLabel: 'غير محددة',
        english: false,
      );
      expect(
        slices.map((s) => s.label).toList(),
        ['شبكة', 'نقدي', 'غير محددة'],
      );
      expect(slices.first.total, 160);
      expect(slices.last.total, 25);

      // Only cash invoices: nothing unspecified → no slice at all.
      final cashOnly = totalsByPaymentMethod(
        invoices: [invoices[2]],
        methods: methods,
        unspecifiedLabel: 'غير محددة',
        english: false,
      );
      expect(cashOnly.map((s) => s.label), ['نقدي']);
    });

    test('topShopsInPeriod aggregates by VAT and reuses display names', () {
      final invoices = [
        _invoice(issuedAt: DateTime(2026, 9, 1), vat: '300111111111113', amount: 100),
        _invoice(issuedAt: DateTime(2026, 9, 2), vat: '300111111111113', amount: 50),
        _invoice(issuedAt: DateTime(2026, 9, 3), vat: '300222222222223', name: 'صالون الأناقة', amount: 200),
        _invoice(issuedAt: DateTime(2026, 9, 4), vat: '', name: 'مقهى جديد', amount: 10),
      ];
      final top = topShopsInPeriod(invoices: invoices, shops: shops);
      expect(top.map((s) => s.name).toList(), ['صالون الأناقة', 'بندة ماركت', 'مقهى جديد']);
      expect(top[1].invoices, hasLength(2));
      expect(top[1].totalAmount, 150);
      expect(top[2].categoryId, isNull);

      final limited = topShopsInPeriod(invoices: invoices, shops: shops, limit: 2);
      expect(limited, hasLength(2));
    });
  });
}
