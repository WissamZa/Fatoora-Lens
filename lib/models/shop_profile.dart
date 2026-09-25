/// User-authored shop metadata (custom display name and note), synced
/// separately from the derived `shops` table. The key is the shop's
/// business identity: `v:<vat number>` when known, otherwise `n:<name>`,
/// so both devices agree on which shop a profile belongs to.
class ShopProfile {
  const ShopProfile({
    required this.key,
    this.nameAr = '',
    this.nameEn = '',
    this.displayName = '',
    this.note = '',
    this.updatedAt,
    this.isSynced = false,
    this.isDeleted = false,
  });

  final String key;
  final String nameAr;
  final String nameEn;
  final String displayName;
  final String note;
  final int? updatedAt;
  final bool isSynced;
  final bool isDeleted;

  /// Builds the business key for a shop identified by VAT number when
  /// available, falling back to the exact seller name.
  static String keyFor({required String vatNumber, required String nameAr}) {
    final vat = vatNumber.trim();
    return vat.isNotEmpty ? 'v:$vat' : 'n:${nameAr.trim()}';
  }

  ShopProfile copyWith({
    String? nameAr,
    String? nameEn,
    String? displayName,
    String? note,
    int? updatedAt,
    bool? isSynced,
    bool? isDeleted,
  }) => ShopProfile(
        key: key,
        nameAr: nameAr ?? this.nameAr,
        nameEn: nameEn ?? this.nameEn,
        displayName: displayName ?? this.displayName,
        note: note ?? this.note,
        updatedAt: updatedAt ?? this.updatedAt,
        isSynced: isSynced ?? this.isSynced,
        isDeleted: isDeleted ?? this.isDeleted,
      );

  Map<String, Object?> toMap() => {
        'key': key,
        'name_ar': nameAr,
        'name_en': nameEn,
        'display_name': displayName,
        'note': note,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
      };

  factory ShopProfile.fromMap(Map<String, Object?> map) => ShopProfile(
        key: (map['key'] as String?) ?? '',
        nameAr: (map['name_ar'] as String?) ?? '',
        nameEn: (map['name_en'] as String?) ?? '',
        displayName: (map['display_name'] as String?) ?? '',
        note: (map['note'] as String?) ?? '',
        updatedAt: map['updated_at'] is int ? map['updated_at'] as int : null,
        isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
        isDeleted: ((map['is_deleted'] as num?) ?? 0) != 0,
      );
}

/// Metadata of a syncable media file, keyed by its SHA-256 so both devices
/// address the same content without shipping absolute paths.
class MediaRecord {
  const MediaRecord({
    required this.sha256,
    this.bytes = 0,
    this.mime = 'image/jpeg',
    this.localPath,
    this.updatedAt,
    this.isSynced = false,
  });

  final String sha256;
  final int bytes;
  final String mime;

  /// Where the file lives on THIS device; never synced as identity.
  final String? localPath;
  final int? updatedAt;
  final bool isSynced;

  Map<String, Object?> toMap() => {
        'sha256': sha256,
        'bytes': bytes,
        'mime': mime,
        'local_path': localPath,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
      };

  factory MediaRecord.fromMap(Map<String, Object?> map) => MediaRecord(
        sha256: (map['sha256'] as String?) ?? '',
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        mime: (map['mime'] as String?) ?? 'image/jpeg',
        localPath: map['local_path'] as String?,
        updatedAt: map['updated_at'] is int ? map['updated_at'] as int : null,
        isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
      );
}
