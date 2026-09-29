import '../models/invoice.dart';
import '../models/payment_method.dart';
import '../models/shop.dart';
import '../models/shop_category.dart';

/// The granularity of a period report.
enum ReportPeriod { day, week, month, year }

/// A half-open date range `[start, endExclusive)` for one report period.
/// All math is local-time; weeks start on Saturday, matching the Arabic
/// (ar_SA) calendar convention.
class PeriodRange {
  const PeriodRange(this.period, this.start, this.endExclusive);

  final ReportPeriod period;
  final DateTime start;

  /// Exclusive bound: the first moment AFTER the period.
  final DateTime endExclusive;

  /// The range containing any [anchor] moment inside it.
  static PeriodRange containing(ReportPeriod period, DateTime anchor) {
    switch (period) {
      case ReportPeriod.day:
        final day = DateTime(anchor.year, anchor.month, anchor.day);
        return PeriodRange(period, day, day.add(const Duration(days: 1)));
      case ReportPeriod.week:
        final day = DateTime(anchor.year, anchor.month, anchor.day);
        // DateTime.weekday: Mon=1..Sun=7; shift back to this week's Saturday.
        final daysSinceSaturday = (day.weekday - DateTime.saturday) % 7;
        final start = day.subtract(Duration(days: daysSinceSaturday));
        return PeriodRange(period, start, start.add(const Duration(days: 7)));
      case ReportPeriod.month:
        return PeriodRange(
          period,
          DateTime(anchor.year, anchor.month),
          DateTime(anchor.year, anchor.month + 1),
        );
      case ReportPeriod.year:
        return PeriodRange(period, DateTime(anchor.year), DateTime(anchor.year + 1));
    }
  }

  /// The range immediately before this one, same length semantics.
  PeriodRange previous() {
    switch (period) {
      case ReportPeriod.day:
        return PeriodRange(period, start.subtract(const Duration(days: 1)), start);
      case ReportPeriod.week:
        return PeriodRange(period, start.subtract(const Duration(days: 7)), start);
      case ReportPeriod.month:
        return PeriodRange(
          period,
          DateTime(start.year, start.month - 1),
          start,
        );
      case ReportPeriod.year:
        return PeriodRange(period, DateTime(start.year - 1), start);
    }
  }

  /// The range immediately after this one.
  PeriodRange next() {
    switch (period) {
      case ReportPeriod.day:
        return PeriodRange(
          period,
          endExclusive,
          endExclusive.add(const Duration(days: 1)),
        );
      case ReportPeriod.week:
        return PeriodRange(
          period,
          endExclusive,
          endExclusive.add(const Duration(days: 7)),
        );
      case ReportPeriod.month:
        return PeriodRange(
          period,
          endExclusive,
          DateTime(endExclusive.year, endExclusive.month + 1),
        );
      case ReportPeriod.year:
        return PeriodRange(period, endExclusive, DateTime(endExclusive.year + 1));
    }
  }

  bool contains(DateTime moment) =>
      !moment.isBefore(start) && moment.isBefore(endExclusive);

  @override
  bool operator ==(Object other) =>
      other is PeriodRange &&
      other.period == period &&
      other.start == start &&
      other.endExclusive == endExclusive;

  @override
  int get hashCode => Object.hash(period, start, endExclusive);

  /// Invoices whose issue date falls inside this range, newest first.
  List<Invoice> invoicesIn(List<Invoice> invoices) {
    final inRange =
        invoices.where((invoice) => contains(invoice.issuedAt)).toList();
    inRange.sort((a, b) {
      final date = b.issuedAt.compareTo(a.issuedAt);
      return date == 0 ? (b.id ?? '').compareTo(a.id ?? '') : date;
    });
    return inRange;
  }

  /// Trend buckets inside the range: consecutive daily buckets for the
  /// week and month periods, monthly buckets for a year. A single-day
  /// period has no meaningful trend and returns just itself.
  List<PeriodRange> buckets() {
    switch (period) {
      case ReportPeriod.day:
        return [this];
      case ReportPeriod.week:
      case ReportPeriod.month:
        return [
          for (var cursor = DateTime(start.year, start.month, start.day);
              cursor.isBefore(endExclusive);
              cursor = cursor.add(const Duration(days: 1)))
            PeriodRange(
              ReportPeriod.day,
              cursor,
              cursor.add(const Duration(days: 1)),
            ),
        ];
      case ReportPeriod.year:
        return [
          for (var month = 1; month <= 12; month++)
            PeriodRange(
              ReportPeriod.month,
              DateTime(start.year, month),
              DateTime(start.year, month + 1),
            ),
        ];
    }
  }
}

/// One aggregated slice (a category, a payment method, a shop...).
class NamedTotal {
  const NamedTotal(this.label, this.total, {this.id, this.icon = ''});

  final String label;
  final double total;
  final String? id;
  final String icon;

  double shareOf(double grandTotal) =>
      grandTotal == 0 ? 0 : total / grandTotal;
}

/// Totals of one period at a glance.
class PeriodTotals {
  const PeriodTotals({
    required this.count,
    required this.amount,
    required this.tax,
  });

  final int count;
  final double amount;
  final double tax;

  double get average => count == 0 ? 0 : amount / count;

  static PeriodTotals of(List<Invoice> invoices) => PeriodTotals(
        count: invoices.length,
        amount: invoices
            .fold<double>(0, (sum, invoice) => sum + invoice.totalAmount),
        tax: invoices.fold<double>(0, (sum, invoice) => sum + invoice.vatAmount),
      );

  /// Percentage change of this period's amount over [previous]'s; null
  /// when the previous period had no spending (nothing to compare with).
  double? changeOver(PeriodTotals previous) {
    if (previous.amount == 0) return null;
    return (amount - previous.amount) / previous.amount * 100;
  }
}

Shop? _shopForInvoice(Invoice invoice, List<Shop> shops) {
  final vat = invoice.vatNumber.trim();
  for (final shop in shops) {
    if (vat.isNotEmpty) {
      if (shop.vatNumber == vat) return shop;
    } else if (shop.vatNumber.isEmpty &&
        shop.nameAr == invoice.sellerName.trim()) {
      return shop;
    }
  }
  return null;
}

List<NamedTotal> _sortedTotals(Map<String, double> totals) {
  final entries = [
    for (final entry in totals.entries) NamedTotal(entry.key, entry.value),
  ]..sort((a, b) => b.total.compareTo(a.total));
  return entries;
}

/// Spending grouped by the shop's category. Invoices reach a category
/// through their shop identity (VAT number, falling back to the seller
/// name — the same rule the shops list uses). Uncategorized shops and
/// shops whose category was deleted land in the [uncategorizedLabel]
/// slice, which is dropped when empty.
List<NamedTotal> totalsByCategory({
  required List<Invoice> invoices,
  required List<Shop> shops,
  required List<ShopCategory> categories,
  required String uncategorizedLabel,
  required bool english,
}) {
  final categoryById = {
    for (final category in categories) category.id: category,
  };
  final totals = <String, double>{};
  for (final invoice in invoices) {
    final shop = _shopForInvoice(invoice, shops);
    final categoryId = shop?.categoryId;
    final category =
        categoryId == null ? null : categoryById[categoryId];
    if (category == null) {
      totals[uncategorizedLabel] =
          (totals[uncategorizedLabel] ?? 0) + invoice.totalAmount;
    } else {
      final label = category.displayName(english: english);
      totals[label] = (totals[label] ?? 0) + invoice.totalAmount;
    }
  }
  if (totals[uncategorizedLabel] == 0) totals.remove(uncategorizedLabel);
  return _sortedTotals(totals);
}

/// Spending grouped by payment method. Invoices without a method (or
/// referencing a deleted one) land in [unspecifiedLabel], which is
/// dropped when it stays empty.
List<NamedTotal> totalsByPaymentMethod({
  required List<Invoice> invoices,
  required List<PaymentMethod> methods,
  required String unspecifiedLabel,
  required bool english,
}) {
  final methodById = {for (final method in methods) method.id: method};
  final totals = <String, double>{};
  for (final invoice in invoices) {
    final methodId = invoice.paymentMethodId;
    final method = methodId == null ? null : methodById[methodId];
    if (method == null) {
      totals[unspecifiedLabel] =
          (totals[unspecifiedLabel] ?? 0) + invoice.totalAmount;
    } else {
      final label = method.displayName(english: english);
      totals[label] = (totals[label] ?? 0) + invoice.totalAmount;
    }
  }
  if (totals[unspecifiedLabel] == 0) totals.remove(unspecifiedLabel);
  return _sortedTotals(totals);
}

/// The period's invoices grouped back into per-shop aggregates (VAT
/// number first, seller-name fallback — mirroring getShops), ordered by
/// total, for the "top shops" bar chart. Shop display names and
/// categories are reused when the shop exists in [shops].
List<Shop> topShopsInPeriod({
  required List<Invoice> invoices,
  required List<Shop> shops,
  int limit = 8,
}) {
  final grouped = <String, List<Invoice>>{};
  final order = <String>[];
  for (final invoice in invoices) {
    final vat = invoice.vatNumber.trim();
    final key = vat.isNotEmpty ? 'v:$vat' : 'n:${invoice.sellerName.trim()}';
    grouped.putIfAbsent(key, () => []).add(invoice);
    if (!order.contains(key)) order.add(key);
  }

  final aggregates = <Shop>[];
  for (final key in order) {
    final group = grouped[key]!;
    final existing = _shopForInvoice(group.first, shops);
    aggregates.add(
      Shop(
        id: existing?.id,
        nameAr: existing?.nameAr ?? group.first.sellerName,
        nameEn: existing?.nameEn ?? group.first.sellerNameEn,
        displayName: existing?.displayName ?? '',
        vatNumber: existing?.vatNumber ?? group.first.vatNumber,
        note: '',
        categoryId: existing?.categoryId,
        invoices: group,
      ),
    );
  }
  aggregates.sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
  return aggregates.take(limit).toList();
}
