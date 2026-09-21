import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models/shop.dart';
import '../widgets/sar_symbol.dart';

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
    final max = chartShops.fold<double>(0, (value, shop) => math.max(value, shop.totalAmount));

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
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 18, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, 'byShop'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 22),
                SizedBox(
                  height: 245,
                  child: BarChart(
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
                              if (index < 0 || index >= chartShops.length) return const SizedBox.shrink();
                              final name = chartShops[index].name;
                              return SideTitleWidget(
                                meta: meta,
                                child: SizedBox(
                                  width: 66,
                                  child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9)),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var index = 0; index < chartShops.length; index++)
                          BarChartGroupData(
                            x: index,
                            barRods: [
                              BarChartRodData(
                                toY: chartShops[index].totalAmount,
                                width: 22,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
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
