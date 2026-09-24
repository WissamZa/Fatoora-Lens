import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../models/shop.dart';
import '../widgets/sar_symbol.dart';

enum ChartType { bar, line, pie }

class AnalysisTab extends StatelessWidget {
  const AnalysisTab({required this.shops, super.key});

  final List<Shop> shops;

  @override
  Widget build(BuildContext context) {
    if (shops.isEmpty) {
      return Center(child: Text(tr(context, 'noData')));
    }
    final ordered = [...shops]..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
    final chartShops = ordered.take(8).toList();
    final total = shops.fold<double>(0, (sum, shop) => sum + shop.totalAmount);
    final tax = shops.fold<double>(0, (sum, shop) => sum + shop.totalTax);
    final count = shops.fold<int>(0, (sum, shop) => sum + shop.invoices.length);
    final colors = chartColors(context);
    final monthlyEntries = monthlyTotals(shops);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
      children: [
        Text(tr(context, 'expensesAnalysis'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _Metric(label: tr(context, 'allShopsTotal'), amount: total, icon: Icons.payments_outlined)),
            const SizedBox(width: 10),
            Expanded(child: _Metric(label: tr(context, 'totalTax'), amount: tax, icon: Icons.receipt_long_outlined)),
          ],
        ),
        const SizedBox(height: 10),
        _Metric(label: tr(context, 'totalInvoices'), value: '$count', icon: Icons.grid_view_rounded),
        const SizedBox(height: 18),
        _ChartCard(
          title: tr(context, 'byShop'),
          onTap: () => _openChart(context, ChartType.bar),
          child: SizedBox(
            height: 245,
            child: ShopBarChart(shops: chartShops),
          ),
        ),
        const SizedBox(height: 14),
        _ChartCard(
          title: tr(context, 'monthlyTrend'),
          onTap: () => _openChart(context, ChartType.line),
          child: SizedBox(
            height: 220,
            child: monthlyEntries.length < 2
                ? Center(child: Text(tr(context, 'noData')))
                : MonthlyLineChart(entries: monthlyEntries),
          ),
        ),
        const SizedBox(height: 14),
        _ChartCard(
          title: tr(context, 'shopShare'),
          onTap: () => _openChart(context, ChartType.pie),
          child: Row(
            children: [
              ShopPieChart(shops: chartShops, total: total, colors: colors),
              const SizedBox(width: 12),
              Expanded(
                child: _PieLegend(
                  shops: chartShops,
                  total: total,
                  colors: colors,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, 'summary'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                ...ordered.map((shop) => _ShopProgress(shop: shop, total: total)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openChart(BuildContext context, ChartType type) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ChartFullscreenPage(type: type, shops: shops),
      ),
    );
  }
}

List<Color> chartColors(BuildContext context) => [
      Theme.of(context).colorScheme.primary,
      Theme.of(context).colorScheme.tertiary,
      Colors.orange.shade700,
      Colors.indigo.shade400,
      Colors.pink.shade400,
      Colors.cyan.shade700,
      Colors.brown.shade400,
      Colors.deepPurple.shade400,
    ];

List<MapEntry<DateTime, double>> monthlyTotals(List<Shop> shops) {
  final monthly = <DateTime, double>{};
  for (final invoice in shops.expand((shop) => shop.invoices)) {
    final month = DateTime(invoice.issuedAt.year, invoice.issuedAt.month);
    monthly[month] = (monthly[month] ?? 0) + invoice.totalAmount;
  }
  return monthly.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.onTap, required this.child});

  final String title;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Tooltip(
                    message: tr(context, 'tapToExpand'),
                    child: Icon(
                      Icons.open_in_full_rounded,
                      size: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Fullscreen landscape view of a single chart with all the data visible.
class ChartFullscreenPage extends StatefulWidget {
  const ChartFullscreenPage({required this.type, required this.shops, super.key});

  final ChartType type;
  final List<Shop> shops;

  @override
  State<ChartFullscreenPage> createState() => _ChartFullscreenPageState();
}

class _ChartFullscreenPageState extends State<ChartFullscreenPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ordered = [...widget.shops]
      ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
    final total = ordered.fold<double>(0, (sum, shop) => sum + shop.totalAmount);
    final colors = chartColors(context);
    final monthlyEntries = monthlyTotals(widget.shops);
    final title = switch (widget.type) {
      ChartType.bar => tr(context, 'byShop'),
      ChartType.line => tr(context, 'monthlyTrend'),
      ChartType.pie => tr(context, 'shopShare'),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: tr(context, 'close'),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (widget.type) {
            ChartType.bar => _fullscreenBar(context, ordered),
            ChartType.line => monthlyEntries.length < 2
                ? Center(child: Text(tr(context, 'noData')))
                : MonthlyLineChart(entries: monthlyEntries, labelFontSize: 11),
            ChartType.pie => _fullscreenPie(context, ordered, total, colors),
          },
        ),
      ),
    );
  }

  Widget _fullscreenBar(BuildContext context, List<Shop> ordered) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const widthPerShop = 92.0;
        final chartWidth = math.max(constraints.maxWidth, ordered.length * widthPerShop);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            height: constraints.maxHeight,
            width: chartWidth,
            child: ShopBarChart(shops: ordered, barWidth: 28, labelWidth: 76),
          ),
        );
      },
    );
  }

  Widget _fullscreenPie(
    BuildContext context,
    List<Shop> ordered,
    double total,
    List<Color> colors,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxHeight, 320.0).clamp(200.0, 320.0);
        return Row(
          children: [
            ShopPieChart(
              shops: ordered,
              total: total,
              colors: colors,
              size: side,
              centerRadius: side * 0.16,
            ),
            const SizedBox(width: 20),
            Expanded(
              child: _PieLegend(
                shops: ordered,
                total: total,
                colors: colors,
                showAmounts: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

class ShopBarChart extends StatelessWidget {
  const ShopBarChart({
    required this.shops,
    this.barWidth = 22,
    this.labelWidth = 66,
    super.key,
  });

  /// Shops already ordered by total amount, not truncated.
  final List<Shop> shops;
  final double barWidth;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final max = shops.fold<double>(0, (value, shop) => math.max(value, shop.totalAmount));
    return BarChart(
      BarChartData(
        maxY: max == 0 ? 10 : max * 1.25,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        barTouchData: const BarTouchData(enabled: true),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 42)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= shops.length) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: SizedBox(
                    width: labelWidth,
                    child: Text(
                      shops[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var index = 0; index < shops.length; index++)
            BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: shops[index].totalAmount,
                  width: barWidth,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class MonthlyLineChart extends StatelessWidget {
  const MonthlyLineChart({required this.entries, this.labelFontSize = 9, super.key});

  final List<MapEntry<DateTime, double>> entries;
  final double labelFontSize;

  @override
  Widget build(BuildContext context) {
    final monthlyMax = entries.fold<double>(0, (value, entry) => math.max(value, entry.value));
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (entries.length - 1).toDouble(),
        minY: 0,
        maxY: monthlyMax == 0 ? 10 : monthlyMax * 1.25,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: true),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 42)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (value, meta) {
                final index = value.round();
                if (index < 0 || index >= entries.length) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    DateFormat('MM/yy').format(entries[index].key),
                    style: TextStyle(fontSize: labelFontSize),
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var index = 0; index < entries.length; index++)
                FlSpot(index.toDouble(), entries[index].value),
            ],
            isCurved: true,
            barWidth: 3,
            color: Theme.of(context).colorScheme.primary,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class ShopPieChart extends StatelessWidget {
  const ShopPieChart({
    required this.shops,
    required this.total,
    required this.colors,
    this.size = 190,
    this.centerRadius = 38,
    super.key,
  });

  final List<Shop> shops;
  final double total;
  final List<Color> colors;
  final double size;
  final double centerRadius;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: PieChart(
        PieChartData(
          centerSpaceRadius: centerRadius,
          sectionsSpace: 2,
          sections: [
            for (var index = 0; index < shops.length; index++)
              PieChartSectionData(
                value: shops[index].totalAmount,
                title: total == 0 ? '0%' : '${(shops[index].totalAmount / total * 100).round()}%',
                color: colors[index % colors.length],
                radius: (size - centerRadius) / 2 - 2,
                titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

class _PieLegend extends StatelessWidget {
  const _PieLegend({
    required this.shops,
    required this.total,
    required this.colors,
    this.showAmounts = false,
  });

  final List<Shop> shops;
  final double total;
  final List<Color> colors;
  final bool showAmounts;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < shops.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[index % colors.length], shape: BoxShape.circle)),
                  const SizedBox(width: 7),
                  Expanded(child: Text(shops[index].name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (showAmounts) ...[
                    const SizedBox(width: 8),
                    Text(
                      total == 0 ? '0%' : '${(shops[index].totalAmount / total * 100).round()}%',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                    const SizedBox(width: 10),
                    SarAmount(
                      amount: shops[index].totalAmount,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      symbolSize: 11,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    this.value,
    this.amount,
    required this.icon,
  });

  final String label;
  final String? value;
  final double? amount;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 3),
                    if (amount != null)
                      SarAmount(
                        amount: amount!,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                        symbolSize: 13,
                      )
                    else
                      Text(value ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _ShopProgress extends StatelessWidget {
  const _ShopProgress({required this.shop, required this.total});

  final Shop shop;
  final double total;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : (shop.totalAmount / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(shop.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              SarAmount(
                amount: shop.totalAmount,
                style: const TextStyle(fontWeight: FontWeight.w700),
                symbolSize: 12,
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: ratio, minHeight: 8)),
        ],
      ),
    );
  }
}
