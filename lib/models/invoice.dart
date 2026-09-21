class Invoice {
  const Invoice({
    this.id,
    required this.sellerName,
    required this.vatNumber,
    required this.issuedAt,
    required this.totalAmount,
    required this.vatAmount,
    required this.rawPayload,
    this.note = '',
    this.imagePath,
    this.createdAt,
  });

  final int? id;
  final String sellerName;
  final String vatNumber;
  final DateTime issuedAt;
  final double totalAmount;
  final double vatAmount;
  final String rawPayload;
  final String note;
  final String? imagePath;
  final DateTime? createdAt;

  Invoice copyWith({
    String? sellerName,
    String? vatNumber,
    double? totalAmount,
    double? vatAmount,
    String? note,
    String? imagePath,
    bool clearImage = false,
  }) => Invoice(
        id: id,
        sellerName: sellerName ?? this.sellerName,
        vatNumber: vatNumber ?? this.vatNumber,
        issuedAt: issuedAt,
        totalAmount: totalAmount ?? this.totalAmount,
        vatAmount: vatAmount ?? this.vatAmount,
        rawPayload: rawPayload,
        note: note ?? this.note,
        imagePath: clearImage ? null : (imagePath ?? this.imagePath),
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'seller_name': sellerName,
        'vat_number': vatNumber,
        'issued_at': issuedAt.toIso8601String(),
        'total_amount': totalAmount,
        'vat_amount': vatAmount,
        'raw_payload': rawPayload,
        'note': note,
        'image_path': imagePath,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  factory Invoice.fromMap(Map<String, Object?> map) => Invoice(
        id: map['id'] as int?,
        sellerName: map['seller_name'] as String,
        vatNumber: (map['vat_number'] as String?) ?? '',
        issuedAt: DateTime.parse(map['issued_at'] as String),
        totalAmount: (map['total_amount'] as num).toDouble(),
        vatAmount: (map['vat_amount'] as num).toDouble(),
        rawPayload: map['raw_payload'] as String,
        note: (map['note'] as String?) ?? '',
        imagePath: map['image_path'] as String?,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      );
}
