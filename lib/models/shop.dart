import 'invoice.dart';

class Shop {
  const Shop({
    required this.name,
    required this.vatNumber,
    required this.note,
    required this.invoices,
  });

  final String name;
  final String vatNumber;
  final String note;
  final List<Invoice> invoices;

  double get totalAmount =>
      invoices.fold<double>(0, (sum, invoice) => sum + invoice.totalAmount);

  double get totalTax =>
      invoices.fold<double>(0, (sum, invoice) => sum + invoice.vatAmount);
}
