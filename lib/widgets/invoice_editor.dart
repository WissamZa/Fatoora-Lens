import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models/invoice.dart';
import '../services/zatca_qr_parser.dart';

Future<Invoice?> showInvoiceEditor(
  BuildContext context,
  Invoice invoice, {
  bool review = false,
}) {
  return showDialog<Invoice>(
    context: context,
    builder: (_) => _InvoiceEditorDialog(invoice: invoice, review: review),
  );
}

class _InvoiceEditorDialog extends StatefulWidget {
  const _InvoiceEditorDialog({required this.invoice, required this.review});

  final Invoice invoice;
  final bool review;

  @override
  State<_InvoiceEditorDialog> createState() => _InvoiceEditorDialogState();
}

class _InvoiceEditorDialogState extends State<_InvoiceEditorDialog> {
  late final TextEditingController _sellerController;
  late final TextEditingController _vatController;
  late final TextEditingController _amountController;
  late final TextEditingController _taxController;
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    final invoice = widget.invoice;
    _sellerController = TextEditingController(text: invoice.sellerName);
    _vatController = TextEditingController(text: invoice.vatNumber);
    _amountController = TextEditingController(text: invoice.totalAmount.toStringAsFixed(2));
    _taxController = TextEditingController(text: invoice.vatAmount.toStringAsFixed(2));
    _noteController = TextEditingController(text: invoice.note);
  }

  @override
  void dispose() {
    _sellerController.dispose();
    _vatController.dispose();
    _amountController.dispose();
    _taxController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _save() {
    final seller = _sellerController.text.trim();
    final amount = double.tryParse(_amountController.text.trim().replaceAll(',', ''));
    final tax = double.tryParse(_taxController.text.trim().replaceAll(',', ''));
    if (seller.isEmpty || amount == null || tax == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.isEnglish(context) ? 'Check the required fields.' : 'تحقق من الحقول المطلوبة.')),
      );
      return;
    }
    Navigator.pop(
      context,
      widget.invoice.copyWith(
        sellerName: seller,
        vatNumber: _vatController.text.trim(),
        totalAmount: amount,
        vatAmount: tax,
        note: _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(context, widget.review ? 'invoiceData' : 'editInvoice')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _sellerController,
              decoration: InputDecoration(labelText: tr(context, 'shop')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _vatController,
              decoration: InputDecoration(labelText: tr(context, 'vatNumber')),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amountController,
                    decoration: InputDecoration(labelText: tr(context, 'amount')),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _taxController,
                    decoration: InputDecoration(labelText: tr(context, 'tax')),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: tr(context, 'note'),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                '${tr(context, 'date')}: ${ZatcaQrParser.formatDate(widget.invoice.issuedAt)}  •  ${ZatcaQrParser.formatTime(widget.invoice.issuedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'cancel')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.review ? tr(context, 'saveInvoice') : tr(context, 'save')),
        ),
      ],
    );
  }
}
