import 'package:flutter/material.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/shop.dart';
import '../widgets/invoice_tile.dart';
import '../widgets/invoice_editor.dart';
import '../widgets/sar_symbol.dart';

class ShopsTab extends StatelessWidget {
  const ShopsTab({
    required this.database,
    required this.shops,
    required this.onChanged,
    super.key,
  });

  final DatabaseService database;
  final List<Shop> shops;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (shops.isEmpty) {
      return Center(child: Text(tr(context, 'noInvoices')));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
      itemCount: shops.length,
      separatorBuilder: (_, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final shop = shops[index];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 7,
            ),
            leading: CircleAvatar(
              radius: 25,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.storefront_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            title: Text(
              shop.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shop.hasCustomName && shop.nameAr.isNotEmpty)
                  Text(
                    '${tr(context, 'shopNameInInvoice')}: ${shop.nameAr}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (shop.nameEn.isNotEmpty && shop.nameEn != shop.name)
                  Text(
                    shop.nameEn,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (shop.vatNumber.isNotEmpty)
                  Text(
                    '${tr(context, 'vatNumber')}: ${shop.vatNumber}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${shop.invoices.length} ${shop.invoices.length == 1 ? tr(context, 'invoice') : tr(context, 'invoices')}  •  ',
                    ),
                    SarAmount(
                      amount: shop.totalAmount,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      symbolSize: 12,
                    ),
                  ],
                ),
                if (shop.note.isNotEmpty)
                  Text(
                    '${tr(context, 'note')}: ${shop.note}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ShopDetailsScreen(database: database, shop: shop),
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
  const ShopDetailsScreen({
    required this.database,
    required this.shop,
    super.key,
  });

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
    final previous = _shop.invoices[index];
    final updated = await showInvoiceEditor(context, previous);
    if (updated == null) return;
    await widget.database.updateInvoice(updated);
    await deleteReplacedInvoiceImage(previous, updated);
    await _reload();
  }

  Future<void> _deleteInvoice(int index) async {
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
    final id = _shop.invoices[index].id;
    if (id != null) await widget.database.deleteInvoice(id);
    await _reload();
  }

  Future<void> _editShop() async {
    final nameController = TextEditingController(text: _shop.displayName);
    final noteController = TextEditingController(text: _shop.note);
    final result = await showDialog<({String displayName, String note})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'editShop')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr(context, 'customShopName'),
                hintText: _shop.nameAr.isNotEmpty ? _shop.nameAr : _shop.nameEn,
                prefixIcon: const Icon(Icons.storefront_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: tr(context, 'shopNote'),
                prefixIcon: const Icon(Icons.note_alt_outlined),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              (
                displayName: nameController.text,
                note: noteController.text,
              ),
            ),
            child: Text(tr(context, 'save')),
          ),
        ],
      ),
    );
    nameController.dispose();
    noteController.dispose();
    if (result == null) return;
    await widget.database.updateShopProfile(
      shopId: _shop.id!,
      displayName: result.displayName,
      note: result.note,
    );
    await _reload();
  }

  Future<void> _reload() async {
    final shops = await widget.database.getShops();
    final updated = shops.where((shop) => shop.id == _shop.id).firstOrNull;
    if (!mounted) return;
    if (updated == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _shop = updated);
  }

  @override
  Widget build(BuildContext context) {
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
                  Text(
                    _shop.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (_shop.hasCustomName && _shop.nameAr.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${tr(context, 'shopNameInInvoice')}: ${[
                        _shop.nameAr,
                        if (_shop.nameEn.isNotEmpty) _shop.nameEn,
                      ].join(' | ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else if (_shop.nameEn.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _shop.nameEn,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                  if (_shop.vatNumber.isNotEmpty)
                    Text(
                      '${tr(context, 'vatNumber')}: ${_shop.vatNumber}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _Stat(
                          label: tr(context, 'invoices'),
                          value: '${_shop.invoices.length}',
                        ),
                      ),
                      Expanded(
                        child: _Stat(
                          label: tr(context, 'shopTotal'),
                          amount: _shop.totalAmount,
                        ),
                      ),
                      Expanded(
                        child: _Stat(
                          label: tr(context, 'tax'),
                          amount: _shop.totalTax,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _editShop,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(tr(context, 'editShop')),
                  ),
                  if (_shop.note.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _shop.note,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr(context, 'oldestFirst'),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
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
  const _Stat({required this.label, this.value, this.amount});

  final String label;
  final String? value;
  final double? amount;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 3),
      if (amount != null)
        SarAmount(
          amount: amount!,
          style: const TextStyle(fontWeight: FontWeight.w800),
          symbolSize: 12,
        )
      else
        Text(value ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
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
