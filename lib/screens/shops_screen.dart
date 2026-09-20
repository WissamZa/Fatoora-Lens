import 'package:flutter/material.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/shop.dart';
import '../widgets/invoice_tile.dart';
import '../widgets/invoice_editor.dart';

class ShopsTab extends StatelessWidget {
  const ShopsTab({required this.database, required this.shops, required this.onChanged, super.key});

  final DatabaseService database;
  final List<Shop> shops;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (shops.isEmpty) {
      return Center(child: Text(tr(context, 'noInvoices')));
    }
    final currency = AppL10n.isEnglish(context) ? 'SAR' : 'ر.س';
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
      itemCount: shops.length,
      separatorBuilder: (_, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final shop = shops[index];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            leading: CircleAvatar(
              radius: 25,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(Icons.storefront_rounded, color: Theme.of(context).colorScheme.primary),
            ),
            title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shop.vatNumber.isNotEmpty)
                  Text('${tr(context, 'vatNumber')}: ${shop.vatNumber}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text('${shop.invoices.length} ${shop.invoices.length == 1 ? tr(context, 'invoice') : tr(context, 'invoices')}  •  ${shop.totalAmount.toStringAsFixed(2)} $currency'),
                if (shop.note.isNotEmpty)
                  Text('${tr(context, 'note')}: ${shop.note}', maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ShopDetailsScreen(database: database, shop: shop),
                ),
              );
              onChanged();
            },
          ),
        );
      },
    );
  }
}

class ShopDetailsScreen extends StatefulWidget {
  const ShopDetailsScreen({required this.database, required this.shop, super.key});

  final DatabaseService database;
  final Shop shop;

  @override
  State<ShopDetailsScreen> createState() => _ShopDetailsScreenState();
}

class _ShopDetailsScreenState extends State<ShopDetailsScreen> {
  late Shop _shop;

  @override
  void initState() {
    super.initState();
    _shop = widget.shop;
  }

  Future<void> _editInvoice(int index) async {
    final updated = await showInvoiceEditor(context, _shop.invoices[index]);
    if (updated == null) return;
    await widget.database.updateInvoice(updated);
    await _reload();
  }

  Future<void> _deleteInvoice(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteInvoice')),
        content: Text(tr(context, 'deleteConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'delete'))),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = _shop.invoices[index].id;
    if (id != null) await widget.database.deleteInvoice(id);
    await _reload();
  }

  Future<void> _editNote() async {
    final controller = TextEditingController(text: _shop.note);
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'shopNote')),
        content: TextField(controller: controller, maxLines: 4, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr(context, 'save'))),
        ],
      ),
    );
    controller.dispose();
    if (note == null) return;
    await widget.database.updateShopNote(_shop.name, note);
    await _reload();
  }

  Future<void> _reload() async {
    final shops = await widget.database.getShops();
    final updated = shops.where((shop) => shop.name == _shop.name).firstOrNull;
    if (!mounted || updated == null) return;
    setState(() => _shop = updated);
  }

  @override
  Widget build(BuildContext context) {
    final currency = AppL10n.isEnglish(context) ? 'SAR' : 'ر.س';
    return Scaffold(
      appBar: AppBar(title: Text(_shop.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shop.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  if (_shop.vatNumber.isNotEmpty)
                    Text('${tr(context, 'vatNumber')}: ${_shop.vatNumber}', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _Stat(label: tr(context, 'invoices'), value: '${_shop.invoices.length}')),
                      Expanded(child: _Stat(label: tr(context, 'shopTotal'), value: '${_shop.totalAmount.toStringAsFixed(2)} $currency')),
                      Expanded(child: _Stat(label: tr(context, 'tax'), value: '${_shop.totalTax.toStringAsFixed(2)} $currency')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(onPressed: _editNote, icon: const Icon(Icons.note_alt_outlined), label: Text(tr(context, 'shopNote'))),
                  if (_shop.note.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_shop.note, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(tr(context, 'oldestFirst'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          ..._shop.invoices.asMap().entries.map(
                (entry) => InvoiceTile(
                  invoice: entry.value,
                  onEdit: () => _editInvoice(entry.key),
                  onDelete: () => _deleteInvoice(entry.key),
                ),
              ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      );
}

extension on Iterable<Shop> {
  Shop? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
