import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/invoice.dart';
import '../models/payment_method.dart';
import '../models/shop.dart';
import '../models/shop_category.dart';
import '../services/report_service.dart';
import '../widgets/invoice_editor.dart';
import '../widgets/invoice_tile.dart';
import '../widgets/picker_icons.dart';
import '../widgets/sar_symbol.dart';
import 'analysis_screen.dart';

/// Daily / weekly / monthly / yearly report: the invoices of the selected
/// period with its totals, a comparison against the previous period, and
/// breakdown analytics (by shop category, by payment method, top shops,
/// and the spending trend inside the period).
class PeriodReportScreen extends StatefulWidget {
  const PeriodReportScreen({required this.database, super.key});

  final DatabaseService database;

  @override
  State<PeriodReportScreen> createState() => _PeriodReportScreenState();
}

class _PeriodReportScreenState extends State<PeriodReportScreen> {
  ReportPeriod _period = ReportPeriod.month;
  DateTime _anchor = DateTime.now();

  List<Invoice> _invoices = const [];
  List<Shop> _shops = const [];
  List<ShopCategory> _categories = const [];
  List<PaymentMethod> _methods = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Named DateFormat patterns (MMMM, EEEE) need the locale data; the
    // embedded loader populates it synchronously.
    initializeDateFormatting('ar');
    initializeDateFormatting('en');
    _reload();
  }

  Future<void> _reload() async {
    final invoices = await widget.database.getInvoices();
    final shops = await widget.database.getShops();
    final categories = await widget.database.getShopCategories();
    final methods = await widget.database.getPaymentMethods();
    if (!mounted) return;
    setState(() {
      _invoices = invoices;
      _shops = shops;
      _categories = categories;
      _methods = methods;
      _loading = false;
    });
  }

  PeriodRange get _range => PeriodRange.containing(_period, _anchor);

  String _localeCode() => AppL10n.isEnglish(context) ? 'en' : 'ar';

  String _periodLabel(PeriodRange range) {
    final locale = _localeCode();
    switch (_period) {
      case ReportPeriod.day:
        return DateFormat('EEEE, d MMMM y', locale).format(range.start);
      case ReportPeriod.week:
        final lastDay = range.endExclusive.subtract(const Duration(days: 1));
        return '${DateFormat('d MMM', locale).format(range.start)}'
            ' – ${DateFormat('d MMM y', locale).format(lastDay)}';
      case ReportPeriod.month:
        return DateFormat('MMMM y', locale).format(range.start);
      case ReportPeriod.year:
        return DateFormat('y', locale).format(range.start);
    }
  }

  void _shift(int direction) {
    final next = direction < 0 ? _range.previous() : _range.next();
    setState(() => _anchor = next.start);
  }

  /// Chevron direction that matches the ambient text direction.
  IconData _navIcon(BuildContext context, {required bool backward}) {
    final rtl = Directionality.of(context) == ui.TextDirection.rtl;
    final rightward = backward == rtl;
    return rightward
        ? Icons.chevron_right_rounded
        : Icons.chevron_left_rounded;
  }

  Future<void> _editInvoice(Invoice invoice) async {
    final updated = await showInvoiceEditor(
      context,
      invoice,
      database: widget.database,
    );
    if (updated == null) return;
    await widget.database.updateInvoice(updated);
    await deleteReplacedInvoiceImage(invoice, updated);
    await _reload();
  }

  Future<void> _deleteInvoice(Invoice invoice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteInvoice')),
        content: Text(tr(context, 'deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = invoice.id;
    if (id != null) await widget.database.deleteInvoice(id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final currentInvoices = range.invoicesIn(_invoices);
    final totals = PeriodTotals.of(currentInvoices);
    final previousTotals =
        PeriodTotals.of(range.previous().invoicesIn(_invoices));
    final change = totals.changeOver(previousTotals);
    final english = AppL10n.isEnglish(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'periodReports'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
                children: [
                  _buildPeriodSelector(context),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: MetricCard(
                          label: tr(context, 'totalAmount'),
                          amount: totals.amount,
                          icon: Icons.payments_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: MetricCard(
                          label: tr(context, 'totalTax'),
                          amount: totals.tax,
                          icon: Icons.receipt_long_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: MetricCard(
                          label: tr(context, 'totalInvoices'),
                          value: '${totals.count}',
                          icon: Icons.grid_view_rounded,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: MetricCard(
                          label: tr(context, 'avgInvoice'),
                          amount: totals.average,
                          icon: Icons.calculate_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildComparison(context, totals, previousTotals, change),
                  const SizedBox(height: 14),
                  _buildInvoiceList(context, currentInvoices, totals),
                  if (currentInvoices.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildCategoryChart(context, currentInvoices, english),
                    const SizedBox(height: 14),
                    _buildPaymentChart(context, currentInvoices, english),
                    const SizedBox(height: 14),
                    _buildTopShops(context, currentInvoices),
                    const SizedBox(height: 14),
                    _buildTrend(context, currentInvoices),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildPeriodSelector(BuildContext context) {
    final today = DateTime.now();
    final isCurrentPeriod = _range.contains(today);
    final segments = <ButtonSegment<ReportPeriod>>[
      ButtonSegment(value: ReportPeriod.day, label: Text(tr(context, 'periodDaily'))),
      ButtonSegment(value: ReportPeriod.week, label: Text(tr(context, 'periodWeekly'))),
      ButtonSegment(value: ReportPeriod.month, label: Text(tr(context, 'periodMonthly'))),
      ButtonSegment(value: ReportPeriod.year, label: Text(tr(context, 'periodYearly'))),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ReportPeriod>(
                segments: segments,
                selected: {_period},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _period = selection.first),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton(
                  tooltip: tr(context, 'previousPeriod'),
                  onPressed: () => _shift(-1),
                  icon: Icon(_navIcon(context, backward: true)),
                ),
                Expanded(
                  child: Text(
                    _periodLabel(_range),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'nextPeriod'),
                  onPressed: () => _shift(1),
                  icon: Icon(_navIcon(context, backward: false)),
                ),
              ],
            ),
            if (!isCurrentPeriod)
              TextButton.icon(
                onPressed: () => setState(() => _anchor = DateTime.now()),
                icon: const Icon(Icons.today_outlined, size: 18),
                label: Text(tr(context, 'today')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparison(
    BuildContext context,
    PeriodTotals totals,
    PeriodTotals previousTotals,
    double? change,
  ) {
    final theme = Theme.of(context);
    final Widget detail;
    if (change == null) {
      detail = Text(
        tr(context, 'comparisonNoData'),
        style: theme.textTheme.bodySmall,
      );
    } else {
      final up = change > 0;
      final flat = change.abs() < 0.05;
      final color = flat
          ? theme.colorScheme.onSurfaceVariant
          : (up ? theme.colorScheme.error : const Color(0xFF2E7D32));
      detail = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            flat
                ? Icons.trending_flat_rounded
                : (up ? Icons.trending_up_rounded : Icons.trending_down_rounded),
            color: color,
            size: 20,
          ),
          const SizedBox(width: 6),
          Text(
            '${change.abs().toStringAsFixed(1)}%',
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 10),
          Text(
            '${tr(context, 'previousPeriodTotal')}: ',
            style: theme.textTheme.bodySmall,
          ),
          SarAmount(
            amount: previousTotals.amount,
            style: theme.textTheme.bodySmall,
            symbolSize: 11,
          ),
        ],
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, 'comparisonTitle'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            detail,
          ],
        ),
      ),
    );
  }

  Widget _buildInvoiceList(
    BuildContext context,
    List<Invoice> currentInvoices,
    PeriodTotals totals,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, 'invoicesInPeriod'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                SarAmount(
                  amount: totals.amount,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                  symbolSize: 13,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (currentInvoices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    tr(context, 'noInvoicesInPeriod'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              )
            else
              ...currentInvoices.map(
                (invoice) => InvoiceTile(
                  invoice: invoice,
                  onEdit: () => _editInvoice(invoice),
                  onDelete: () => _deleteInvoice(invoice),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChart(
    BuildContext context,
    List<Invoice> currentInvoices,
    bool english,
  ) {
    final slices = totalsByCategory(
      invoices: currentInvoices,
      shops: _shops,
      categories: _categories,
      uncategorizedLabel: tr(context, 'uncategorized'),
      english: english,
    );
    if (slices.isEmpty) return const SizedBox.shrink();
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.total);
    return ChartCard(
      title: tr(context, 'byCategory'),
      onTap: null,
      child: Row(
        children: [
          LabeledPieChart(
            slices: [
              for (final slice in slices) (label: slice.label, value: slice.total),
            ],
            total: total,
            colors: chartColors(context),
            size: 160,
            centerRadius: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PieLegend(
              slices: [
                for (final slice in slices) (label: slice.label, value: slice.total),
              ],
              total: total,
              colors: chartColors(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentChart(
    BuildContext context,
    List<Invoice> currentInvoices,
    bool english,
  ) {
    final slices = totalsByPaymentMethod(
      invoices: currentInvoices,
      methods: _methods,
      unspecifiedLabel: tr(context, 'unspecifiedPayment'),
      english: english,
    );
    if (slices.isEmpty) return const SizedBox.shrink();
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.total);
    final icons = {
      for (final method in _methods)
        method.displayName(english: english):
            catalogIcon(method.icon, fallback: Icons.payments_outlined),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, 'byPayment'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            for (final slice in slices)
              ShareProgress(
                label: slice.label,
                amount: slice.total,
                total: total,
                icon: icons[slice.label],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopShops(BuildContext context, List<Invoice> currentInvoices) {
    final shops = topShopsInPeriod(
      invoices: currentInvoices,
      shops: _shops,
    );
    if (shops.isEmpty) return const SizedBox.shrink();
    return ChartCard(
      title: tr(context, 'topShopsPeriod'),
      onTap: null,
      child: SizedBox(
        height: 220,
        child: ShopBarChart(shops: shops),
      ),
    );
  }

  Widget _buildTrend(BuildContext context, List<Invoice> currentInvoices) {
    final buckets = _range.buckets();
    if (buckets.length < 2) return const SizedBox.shrink();
    final entries = [
      for (final bucket in buckets)
        MapEntry(
          bucket.start,
          PeriodTotals.of(bucket.invoicesIn(currentInvoices)).amount,
        ),
    ];
    return ChartCard(
      title: tr(context, 'trendInPeriod'),
      onTap: null,
      child: SizedBox(
        height: 200,
        child: MonthlyLineChart(
          entries: entries,
          labelFormat: _period == ReportPeriod.year ? 'MMM' : 'd/M',
          labelFontSize: 8,
        ),
      ),
    );
  }
}
