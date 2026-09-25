import 'package:uuid/uuid.dart';

/// A single ZATCA invoice row.
///
/// Since schema v7 the row carries sync metadata: a device-scoped UUID
/// primary key, the normalized payload hash used to detect the same paper
/// invoice scanned on two devices, and last-write-wins bookkeeping.
class Invoice {
  const Invoice({
    this.id,
    this.deviceId = '',
    this.payloadSha256 = '',
    this.imageSha256,
    this.updatedAt,
    this.isSynced = false,
    this.isDeleted = false,
    required this.sellerName,
    this.sellerNameEn = '',
    required this.vatNumber,
    required this.issuedAt,
    required this.totalAmount,
    required this.vatAmount,
    required this.rawPayload,
    this.invoiceNumber = '',
    this.note = '',
    this.imagePath,
    this.createdAt,
  });

  /// Generates a fresh UUID v4 primary key.
  static String newId() => const Uuid().v4();

  final String? id;
  final String deviceId;
  final String payloadSha256;

  /// SHA-256 of the attached image, the sync identity of the media file.
  /// [imagePath] stays a per-device local path and is never synced.
  final String? imageSha256;

  /// Last local modification, Unix epoch milliseconds.
  final int? updatedAt;
  final bool isSynced;
  final bool isDeleted;

  final String sellerName;
  final String sellerNameEn;
  final String vatNumber;
  final DateTime issuedAt;
  final double totalAmount;
  final double vatAmount;
  final String rawPayload;
  final String invoiceNumber;
  final String note;
  final String? imagePath;
  final DateTime? createdAt;

  Invoice copyWith({
    String? id,
    String? deviceId,
    String? payloadSha256,
    String? imageSha256,
    bool clearImageSha256 = false,
    int? updatedAt,
    bool? isSynced,
    bool? isDeleted,
    String? sellerName,
    String? sellerNameEn,
    String? vatNumber,
    double? totalAmount,
    double? vatAmount,
    String? invoiceNumber,
    String? note,
    String? imagePath,
    bool clearImage = false,
  }) => Invoice(
        id: id ?? this.id,
        deviceId: deviceId ?? this.deviceId,
        payloadSha256: payloadSha256 ?? this.payloadSha256,
        imageSha256: clearImageSha256 ? null : (imageSha256 ?? this.imageSha256),
        updatedAt: updatedAt ?? this.updatedAt,
        isSynced: isSynced ?? this.isSynced,
        isDeleted: isDeleted ?? this.isDeleted,
        sellerName: sellerName ?? this.sellerName,
        sellerNameEn: sellerNameEn ?? this.sellerNameEn,
        vatNumber: vatNumber ?? this.vatNumber,
        issuedAt: issuedAt,
        totalAmount: totalAmount ?? this.totalAmount,
        vatAmount: vatAmount ?? this.vatAmount,
        rawPayload: rawPayload,
        invoiceNumber: invoiceNumber ?? this.invoiceNumber,
        note: note ?? this.note,
        imagePath: clearImage ? null : (imagePath ?? this.imagePath),
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'device_id': deviceId,
        'seller_name': sellerName,
        'seller_name_en': sellerNameEn,
        'vat_number': vatNumber,
        'issued_at': issuedAt.toIso8601String(),
        'total_amount': totalAmount,
        'vat_amount': vatAmount,
        'raw_payload': rawPayload,
        'payload_sha256': payloadSha256,
        'invoice_number': invoiceNumber,
        'note': note,
        'image_path': imagePath,
        'image_sha256': imageSha256,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  factory Invoice.fromMap(Map<String, Object?> map) {
    // Legacy backups stored integer auto-increment ids; those are dropped
    // here so a fresh UUID is assigned when the row is written again.
    final rawId = map['id'];
    final deviceId = (map['device_id'] as String?) ?? '';
    final updatedRaw = map['updated_at'];
    final imageSha = (map['image_sha256'] as String?);
    return Invoice(
      id: rawId is String && rawId.isNotEmpty ? rawId : null,
      deviceId: deviceId,
      payloadSha256: (map['payload_sha256'] as String?) ?? '',
      imageSha256: imageSha,
      updatedAt: updatedRaw is int
          ? updatedRaw
          : int.tryParse('$updatedRaw'),
      isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
      isDeleted: ((map['is_deleted'] as num?) ?? 0) != 0,
      sellerName: (map['seller_name'] as String?) ?? '',
      sellerNameEn: (map['seller_name_en'] as String?) ?? '',
      vatNumber: (map['vat_number'] as String?) ?? '',
      issuedAt: DateTime.parse(map['issued_at'] as String),
      totalAmount: (map['total_amount'] as num).toDouble(),
      vatAmount: (map['vat_amount'] as num).toDouble(),
      rawPayload: (map['raw_payload'] as String?) ?? '',
      invoiceNumber: (map['invoice_number'] as String?) ?? '',
      note: (map['note'] as String?) ?? '',
      imagePath: map['image_path'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
    );
  }
}
