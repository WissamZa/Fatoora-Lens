import 'package:flutter/material.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/invoice.dart';
import '../models/shop.dart';
import '../widgets/invoice_editor.dart';
import '../widgets/invoice_tile.dart';

class AllInvoicesScreen extends StatefulWidget {
  const AllInvoicesScreen({
    required this.database,
    required this.invoices,
    required this.onChanged,
    super.key,
  });

  final DatabaseService database;
  final List<Invoice> invoices;
  final VoidCallback onChanged;

  @override
  State<AllInvoicesScreen> createState() => _AllInvoicesScreenState();
}

class _AllInvoicesScreenState extends State<AllInvoicesScreen> {
  final TextEditingController _searchController = TextEditingController();
  late List<Invoice> _invoices;
  List<Shop> _shops = const [];
  String _sortKey = 'newest';

  @override
  void initState() {
    super.initState();
    _invoices = widget.invoices;
    _loadShops();
  }

  Future<void> _loadShops() async {
    final shops = await widget.database.getShops();
    if (!mounted) return;
    setState(() => _shops = shops);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Invoice> get _visible {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _invoices.where((invoice) {
      if (query.isEmpty) return true;
      return invoice.sellerName.toLowerCase().contains(query) ||
          invoice.sellerNameEn.toLowerCase().contains(query) ||
          invoice.vatNumber.toLowerCase().contains(query) ||
          invoice.invoiceNumber.toLowerCase().contains(query);
    }).toList();
    switch (_sortKey) {
      case 'oldest':
        filtered.sort((a, b) {
          final date = a.issuedAt.compareTo(b.issuedAt);
          return date == 0 ? (a.id ?? '').compareTo(b.id ?? '') : date;
        });
      case 'amountHigh':
        filtered.sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
      case 'amountLow':
        filtered.sort((a, b) => a.totalAmount.compareTo(b.totalAmount));
      case 'shopName':
        filtered.sort(
          (a, b) => (Shop.displayNameForInvoice(_shops, a) ?? a.sellerName)
              .toLowerCase()
              .compareTo(
                (Shop.displayNameForInvoice(_shops, b) ?? b.sellerName)
                    .toLowerCase(),
              ),
        );
      default:
        filtered.sort((a, b) {
          final date = b.issuedAt.compareTo(a.issuedAt);
          return date == 0 ? (b.id ?? '').compareTo(a.id ?? '') : date;
        });
    }
    return filtered;
  }

  Future<void> _reload() async {
    final invoices = await widget.database.getInvoices();
    if (!mounted) return;
    setState(() => _invoices = invoices);
    await _loadShops();
    widget.onChanged();
  }

  Future<void> _editInvoice(Invoice invoice) async {
    final updated = await showInvoiceEditor(context, invoice);
    if (updated == null) return;
    await widget.database.updateInvoice(updated);
    await deleteReplacedInvoiceImage(invoice, updated);
    await _reload();
    if (mounted) _message(tr(context, 'saved'));
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
    if (confirmed != true || invoice.id == null) return;
    await widget.database.deleteInvoice(invoice.id!);
    await _reload();
    if (mounted) _message(tr(context, 'deleted'));
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'allInvoices'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: tr(context, 'search'),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${visible.length} ${tr(context, 'invoices')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _sortKey,
                    borderRadius: BorderRadius.circular(14),
                    icon: const Icon(Icons.sort_rounded),
                    items: [
                      ('newest', 'sortNewest', Icons.event_available_rounded),
                      ('oldest', 'sortOldest', Icons.history_rounded),
                      ('amountHigh', 'sortAmountHigh', Icons.arrow_downward_rounded),
                      ('amountLow', 'sortAmountLow', Icons.arrow_upward_rounded),
                      ('shopName', 'sortShopName', Icons.storefront_outlined),
                    ]
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.$1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(item.$3, size: 18),
                                const SizedBox(width: 8),
                                Text(tr(context, item.$2)),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _sortKey = value);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _invoices.isEmpty
                          ? tr(context, 'noInvoices')
                          : tr(context, 'noSearchResults'),
                      textAlign: TextAlign.center,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final invoice = visible[index];
                        return InvoiceTile(
                          invoice: invoice,
                          shopName: Shop.displayNameForInvoice(_shops, invoice),
                          onEdit: () => _editInvoice(invoice),
                          onDelete: () => _deleteInvoice(invoice),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
