import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models/invoice.dart';
import '../models/shop.dart';

class PdfExportScreen extends StatefulWidget {
  const PdfExportScreen({required this.invoices, this.shops = const [], super.key});

  final List<Invoice> invoices;
  final List<Shop> shops;

  @override
  State<PdfExportScreen> createState() => _PdfExportScreenState();
}

class _PdfExportScreenState extends State<PdfExportScreen> {
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.invoices.map(_keyFor).toSet();
  }

  int _keyFor(Invoice invoice) => invoice.id ?? invoice.hashCode;

  void _toggleAll() {
    setState(() {
      if (_selected.length == widget.invoices.length) {
        _selected.clear();
      } else {
        _selected.addAll(widget.invoices.map(_keyFor));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'chooseInvoices')),
        actions: [
          TextButton(onPressed: _toggleAll, child: Text(_selected.length == widget.invoices.length ? tr(context, 'deselectAll') : tr(context, 'selectAll'))),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
        itemCount: widget.invoices.length,
        itemBuilder: (context, index) {
          final invoice = widget.invoices[index];
          final key = _keyFor(invoice);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: CheckboxListTile(
              value: _selected.contains(key),
              onChanged: (value) => setState(() => value == true ? _selected.add(key) : _selected.remove(key)),
              title: Text(
                Shop.displayNameForInvoice(widget.shops, invoice) ?? invoice.sellerName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('${invoice.issuedAt.toLocal()}  •  ${invoice.totalAmount.toStringAsFixed(2)}'),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, widget.invoices.where((invoice) => _selected.contains(_keyFor(invoice))).toList()),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: Text('${tr(context, 'generatePdf')} (${_selected.length})'),
        ),
      ),
    );
  }
}
