import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models/invoice.dart';
import '../services/zatca_qr_parser.dart';

class InvoiceTile extends StatelessWidget {
  const InvoiceTile({
    required this.invoice,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final Invoice invoice;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final currency = AppL10n.isEnglish(context) ? 'SAR' : 'ر.س';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(Icons.receipt_long_rounded, color: Theme.of(context).colorScheme.primary),
        ),
        title: Text(invoice.sellerName, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (invoice.vatNumber.isNotEmpty)
              Text('${tr(context, 'vatNumber')}: ${invoice.vatNumber}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 3),
            Text('${ZatcaQrParser.formatDate(invoice.issuedAt)}  •  ${ZatcaQrParser.formatTime(invoice.issuedAt)}'),
            if (invoice.note.isNotEmpty)
              Text(
                '${tr(context, 'note')}: ${invoice.note}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${invoice.totalAmount.toStringAsFixed(2)} $currency', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text('${tr(context, 'tax')}: ${invoice.vatAmount.toStringAsFixed(2)}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') onEdit();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'edit', child: Text(tr(context, 'edit'))),
                PopupMenuItem(value: 'delete', child: Text(tr(context, 'delete'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
