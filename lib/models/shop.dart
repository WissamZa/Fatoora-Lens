import 'invoice.dart';

class Shop {
  const Shop({
    this.id,
    required this.nameAr,
    this.nameEn = '',
    this.displayName = '',
    required this.vatNumber,
    required this.note,
    required this.invoices,
  });

  final int? id;

  /// Arabic name as it came from the invoice QR codes.
  final String nameAr;

  /// English name, either separated automatically from the QR name or
  /// completed later from another invoice of the same shop.
  final String nameEn;

  /// Custom name set by the user; takes priority over the QR names.
  final String displayName;

  /// The VAT number is the shop's identity: invoices sharing it belong to
  /// the same shop even when their seller names differ.
  final String vatNumber;
  final String note;
  final List<Invoice> invoices;

  String get name => displayName.isNotEmpty
      ? displayName
      : (nameAr.isNotEmpty ? nameAr : nameEn);

  bool get hasCustomName => displayName.isNotEmpty;

  double get totalAmount =>
      invoices.fold<double>(0, (sum, invoice) => sum + invoice.totalAmount);

  double get totalTax =>
      invoices.fold<double>(0, (sum, invoice) => sum + invoice.vatAmount);

  /// The custom display name of the invoice's shop, when one is set.
  /// Shops are matched by VAT number first, falling back to the seller
  /// name for invoices without a VAT number.
  static String? displayNameForInvoice(Iterable<Shop> shops, Invoice invoice) {
    final vat = invoice.vatNumber.trim();
    for (final shop in shops) {
      if (vat.isNotEmpty) {
        if (shop.vatNumber == vat && shop.hasCustomName) {
          return shop.displayName;
        }
      } else if (shop.vatNumber.isEmpty &&
          shop.nameAr == invoice.sellerName.trim() &&
          shop.hasCustomName) {
        return shop.displayName;
      }
    }
    return null;
  }
}
