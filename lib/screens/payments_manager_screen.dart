import 'package:flutter/material.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/payment_method.dart';
import '../widgets/catalog_pickers.dart';
import '../widgets/picker_icons.dart';

/// Manage payment methods and saved cards. Cards hold only a name, a
/// description and the last 4 digits — never a full card number.
class PaymentsManagerScreen extends StatefulWidget {
  const PaymentsManagerScreen({required this.database, super.key});

  final DatabaseService database;

  @override
  State<PaymentsManagerScreen> createState() => _PaymentsManagerScreenState();
}

class _PaymentsManagerScreenState extends State<PaymentsManagerScreen> {
  late Future<List<PaymentMethod>> _methodsFuture;
  late Future<List<PaymentCard>> _cardsFuture;

  @override
  void initState() {
    super.initState();
    _methodsFuture = widget.database.getPaymentMethods();
    _cardsFuture = widget.database.getPaymentCards();
  }

  void _reload() {
    setState(() {
      _methodsFuture = widget.database.getPaymentMethods();
      _cardsFuture = widget.database.getPaymentCards();
    });
  }

  Future<void> _addMethod() async {
    final created = await showPaymentMethodEditDialog(context);
    if (created == null) return;
    await widget.database.upsertPaymentMethod(created);
    _reload();
  }

  Future<void> _editMethod(PaymentMethod method) async {
    final updated =
        await showPaymentMethodEditDialog(context, method: method);
    if (updated == null) return;
    await widget.database.upsertPaymentMethod(updated);
    _reload();
  }

  Future<void> _deleteMethod(PaymentMethod method) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteMethodQ')),
        content: Text(tr(context, 'deleteMethodConfirm')),
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
    await widget.database.deletePaymentMethod(method.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'deleted'))),
    );
    _reload();
  }

  Future<void> _addCard() async {
    final created = await showCardEditDialog(context);
    if (created == null) return;
    await widget.database.upsertPaymentCard(created);
    _reload();
  }

  Future<void> _editCard(PaymentCard card) async {
    final updated = await showCardEditDialog(context, card: card);
    if (updated == null) return;
    await widget.database.upsertPaymentCard(updated);
    _reload();
  }

  Future<void> _deleteCard(PaymentCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${tr(context, 'delete')} ${card.name}؟'),
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
    await widget.database.deletePaymentCard(card.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'deleted'))),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final english = AppL10n.isEnglish(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'managePaymentMethods'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr(context, 'selectPaymentMethod'),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'addPaymentMethod'),
                onPressed: _addMethod,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FutureBuilder<List<PaymentMethod>>(
            future: _methodsFuture,
            builder: (context, snapshot) {
              final methods = snapshot.data ?? const <PaymentMethod>[];
              return Column(
                children: [
                  for (final method in methods)
                    Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(
                            catalogIcon(
                              method.icon,
                              fallback: Icons.payments_outlined,
                            ),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          method.displayName(english: english),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          method.requiresCard
                              ? tr(context, 'requiresCard')
                              : (method.nameEn.isNotEmpty
                                  ? method.name
                                  : tr(context, 'none')),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editMethod(method),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              onPressed: () => _deleteMethod(method),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr(context, 'savedCards'),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'addCard'),
                onPressed: _addCard,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FutureBuilder<List<PaymentCard>>(
            future: _cardsFuture,
            builder: (context, snapshot) {
              final cards = snapshot.data;
              if (cards != null && cards.isEmpty) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tr(context, 'noCardsYet'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final card in cards ?? const <PaymentCard>[])
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.credit_card_outlined),
                        title: Text(
                          card.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: card.description.isEmpty
                            ? null
                            : Text(card.description),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '•••• ${card.last4}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editCard(card),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              onPressed: () => _deleteCard(card),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
