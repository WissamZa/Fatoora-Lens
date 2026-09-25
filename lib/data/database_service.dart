import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/invoice.dart';
import '../models/shop.dart';
import '../models/shop_profile.dart';
import '../services/seller_name_splitter.dart';

class DatabaseService {
  DatabaseService({this.databasePath, this.databaseFactory});

  final String? databasePath;
  final DatabaseFactory? databaseFactory;
  Database? _database;
  String? _baseDirectoryPath;
  String? _mediaDirectoryPath;
  String? _deviceId;

  /// Schema 7 re-keyed invoices on UUID v4, added sync bookkeeping
  /// (device_id / updated_at / is_synced / is_deleted), moved user shop
  /// metadata into shop_profiles, and added media/sync_state/sync_log.
  static const int _schemaVersion = 7;
  static const String _deviceIdSettingKey = 'device_id';

  Future<void> initialize() async {
    if (_database != null) return;

    final Directory baseDirectory;
    if (databasePath == null) {
      baseDirectory = await getApplicationDocumentsDirectory();
    } else {
      baseDirectory = File(databasePath!).parent;
    }
    _baseDirectoryPath = baseDirectory.path;
    _mediaDirectoryPath = '${baseDirectory.path}${p.separator}media';
    final path = databasePath ?? '${baseDirectory.path}/zakat_invoices.db';
    try {
      final options = OpenDatabaseOptions(
        version: _schemaVersion,
        onCreate: (database, version) => _ensureSchema(database),
        onUpgrade: (database, oldVersion, newVersion) =>
            _ensureSchema(database),
      );
      _database = databaseFactory == null
          ? await openDatabase(
              path,
              version: options.version,
              onCreate: options.onCreate,
              onUpgrade: options.onUpgrade,
            )
          : await databaseFactory!.openDatabase(path, options: options);
      await _ensureSchema(_database!);
      _deviceId = await _ensureDeviceId(_database!);
    } catch (_) {
      _database = null;
      rethrow;
    }
  }

  static const String _invoicesDdl = '''
    CREATE TABLE IF NOT EXISTS invoices (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL DEFAULT '',
      seller_name TEXT NOT NULL,
      seller_name_en TEXT NOT NULL DEFAULT '',
      vat_number TEXT NOT NULL DEFAULT '',
      issued_at TEXT NOT NULL,
      total_amount REAL NOT NULL,
      vat_amount REAL NOT NULL,
      raw_payload TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL DEFAULT '',
      invoice_number TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      image_path TEXT,
      image_sha256 TEXT,
      updated_at INTEGER NOT NULL DEFAULT 0,
      is_synced INTEGER NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''';

  static const String _shopsDdl = '''
    CREATE TABLE IF NOT EXISTS shops (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vat_number TEXT UNIQUE,
      name_ar TEXT NOT NULL DEFAULT '',
      name_en TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''';

  static const String _shopProfilesDdl = '''
    CREATE TABLE IF NOT EXISTS shop_profiles (
      key TEXT PRIMARY KEY,
      name_ar TEXT NOT NULL DEFAULT '',
      name_en TEXT NOT NULL DEFAULT '',
      display_name TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      updated_at INTEGER NOT NULL DEFAULT 0,
      is_synced INTEGER NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const String _mediaDdl = '''
    CREATE TABLE IF NOT EXISTS media (
      sha256 TEXT PRIMARY KEY,
      bytes INTEGER NOT NULL DEFAULT 0,
      mime TEXT NOT NULL DEFAULT 'image/jpeg',
      local_path TEXT,
      updated_at INTEGER NOT NULL DEFAULT 0,
      is_synced INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const String _syncStateDdl = '''
    CREATE TABLE IF NOT EXISTS sync_state (
      peer_id TEXT NOT NULL,
      table_name TEXT NOT NULL,
      last_synced_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (peer_id, table_name)
    )
  ''';

  static const String _syncLogDdl = '''
    CREATE TABLE IF NOT EXISTS sync_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL DEFAULT '',
      direction TEXT NOT NULL DEFAULT '',
      entity TEXT NOT NULL DEFAULT '',
      entity_id TEXT NOT NULL DEFAULT '',
      action TEXT NOT NULL DEFAULT '',
      detail TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''';

  Future<void> _ensureSchema(DatabaseExecutor database) async {
    final invoiceColumns = await database.rawQuery('PRAGMA table_info(invoices)');
    if (invoiceColumns.isEmpty) {
      await database.execute(_invoicesDdl);
    } else {
      final idColumn = invoiceColumns.firstWhere(
        (row) => row['name'] == 'id',
      );
      final idType = '${idColumn['type'] ?? ''}'.toUpperCase();
      if (idType != 'TEXT') {
        // Pre-7 layout: integer auto-increment ids. One-time conversion.
        await _migrateInvoicesTableToV7(database);
      } else {
        await _ensureInvoiceColumns(database, invoiceColumns);
      }
    }
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_seller ON invoices(seller_name)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_vat ON invoices(vat_number)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_updated ON invoices(updated_at)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_payload ON invoices(payload_sha256)',
    );

    // Shop metadata tables must exist before the shops migration writes
    // user notes/display names into shop_profiles.
    await database.execute(_shopProfilesDdl);
    await database.execute(_mediaDdl);
    await database.execute(_syncStateDdl);
    await database.execute(_syncLogDdl);
    await _migrateShopsTable(database);

    await database.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // Shops are derived from invoices; this also separates mixed-script
    // seller names stored by older versions and re-links shops by VAT.
    await _syncShops(database);
  }

  /// Adds any v7 column missing from an already-migrated invoices table
  /// (defensive, mirrors the pre-7 idempotent column policy).
  Future<void> _ensureInvoiceColumns(
    DatabaseExecutor database,
    List<Map<String, Object?>> columns,
  ) async {
    Future<void> addIfMissing(String name, String ddl) async {
      if (!columns.any((row) => row['name'] == name)) {
        await database.execute('ALTER TABLE invoices ADD COLUMN $ddl');
      }
    }

    await addIfMissing(
      'device_id',
      "device_id TEXT NOT NULL DEFAULT ''",
    );
    await addIfMissing(
      'payload_sha256',
      "payload_sha256 TEXT NOT NULL DEFAULT ''",
    );
    await addIfMissing('image_sha256', 'image_sha256 TEXT');
    await addIfMissing('updated_at', 'updated_at INTEGER NOT NULL DEFAULT 0');
    await addIfMissing('is_synced', 'is_synced INTEGER NOT NULL DEFAULT 0');
    await addIfMissing('is_deleted', 'is_deleted INTEGER NOT NULL DEFAULT 0');
  }

  /// Converts the pre-7 invoices table (integer auto-increment ids) to the
  /// UUID-keyed v7 layout. Every old row keeps its data and gains sync
  /// bookkeeping; images are hashed into the media table in place.
  Future<void> _migrateInvoicesTableToV7(DatabaseExecutor database) async {
    final rows = await database.query('invoices');
    await database.execute('ALTER TABLE invoices RENAME TO invoices_v6_legacy');
    await database.execute(_invoicesDdl);
    final deviceId = await _ensureDeviceId(database);
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final rawRow in rows) {
      final row = Map<String, Object?>.from(rawRow);
      final imagePath = row['image_path'] as String?;
      final imageSha = await _hashImageFile(imagePath);
      if (imageSha != null) {
        await _recordMedia(database, imageSha, imagePath);
      }
      final payload = ((row['raw_payload'] as String?) ?? '').trim();
      await database.insert('invoices', {
        'id': const Uuid().v4(),
        'device_id': deviceId,
        'seller_name': row['seller_name'],
        'seller_name_en': row['seller_name_en'] ?? '',
        'vat_number': row['vat_number'] ?? '',
        'issued_at': row['issued_at'],
        'total_amount': row['total_amount'],
        'vat_amount': row['vat_amount'],
        'raw_payload': row['raw_payload'],
        'payload_sha256': payload.isEmpty ? '' : crypto.sha256.convert(utf8.encode(payload)).toString(),
        'invoice_number': row['invoice_number'] ?? '',
        'note': row['note'] ?? '',
        'image_path': imagePath,
        'image_sha256': imageSha,
        'updated_at': now,
        'is_synced': 0,
        'is_deleted': 0,
        'created_at': row['created_at'] ?? DateTime.now().toIso8601String(),
      });
    }
    await database.execute('DROP TABLE invoices_v6_legacy');
  }

  /// The shops table changed shape twice: v5 keyed rows by seller name,
  /// v6 by id with display/note columns. In v7 the table is purely derived
  /// (names only) and user metadata lives in shop_profiles.
  Future<void> _migrateShopsTable(DatabaseExecutor database) async {
    final columns = await database.rawQuery('PRAGMA table_info(shops)');
    if (columns.isEmpty) {
      await database.execute(_shopsDdl);
      return;
    }
    final hasDisplayName = columns.any((row) => row['name'] == 'display_name');
    final hasSellerName = columns.any((row) => row['name'] == 'seller_name');
    if (!hasDisplayName && !hasSellerName) return;

    final legacyRows = await database.query('shops');
    final legacyNotes = <String, Map<String, String>>{};
    for (final row in legacyRows) {
      final note = ((row['note'] as String?) ?? '').trim();
      final displayName = ((row['display_name'] as String?) ?? '').trim();
      if (note.isEmpty && displayName.isEmpty) continue;
      final name = ((row['seller_name'] as String?) ?? '').trim();
      final vat = ((row['vat_number'] as String?) ?? '').trim();
      final key = ShopProfile.keyFor(vatNumber: vat, nameAr: name);
      legacyNotes[key] = {'note': note, 'display_name': displayName};
    }
    await database.execute('DROP TABLE shops');
    await database.execute(_shopsDdl);
    for (final entry in legacyNotes.entries) {
      await database.insert(
        'shop_profiles',
        ShopProfile(
          key: entry.key,
          note: entry.value['note'] ?? '',
          displayName: entry.value['display_name'] ?? '',
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<String> _ensureDeviceId(DatabaseExecutor database) async {
    final rows = await database.query(
      'settings',
      where: 'key = ?',
      whereArgs: [_deviceIdSettingKey],
      limit: 1,
    );
    final existing = rows.isEmpty ? null : rows.first['value'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await database.insert('settings', {
      'key': _deviceIdSettingKey,
      'value': id,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  }

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('Database is not initialized');
    }
    return database;
  }

  /// Rebuilds the derived shops table from the current invoice rows. The
  /// sync session calls this after merging rows straight into the
  /// invoices table, bypassing insertInvoice/updateInvoice.
  Future<void> refreshDerivedShops() => _syncShops(_db);

  /// Stores received media content after verifying its SHA-256, wires the
  /// local path into every invoice referencing the hash, and returns
  /// whether the file was accepted.
  Future<bool> storeMediaFile(String sha, List<int> bytes) async {
    if (!_isSha256Hex(sha)) return false;
    final computed = crypto.sha256.convert(bytes).toString();
    if (computed != sha) return false;
    final mediaDir = _mediaDirectoryPath;
    if (mediaDir == null) return false;
    final directory = Directory(mediaDir);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final partFile = File('$mediaDir${p.separator}$sha.part');
    await partFile.writeAsBytes(bytes, flush: true);
    final target = File('$mediaDir${p.separator}$sha');
    if (target.existsSync()) {
      await partFile.delete();
    } else {
      await partFile.rename(target.path);
    }
    await _db.insert(
      'media',
      MediaRecord(
        sha256: sha,
        bytes: bytes.length,
        localPath: target.path,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _db.update(
      'invoices',
      {'image_path': target.path},
      where: 'image_sha256 = ?',
      whereArgs: [sha],
    );
    return true;
  }

  /// The local path of a stored media file, or null when this device does
  /// not have it (no record or the file disappeared).
  Future<String?> mediaFilePath(String sha) async {
    final rows = await _db.query(
      'media',
      where: 'sha256 = ?',
      whereArgs: [sha],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final path = rows.first['local_path'] as String?;
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    return path;
  }

  /// The open database handle for the sync repositories, which run their
  /// own transactions against it.
  Database get syncDatabase => _db;

  /// This installation's sync identity (generated once, stored in settings).
  String? get deviceId => _deviceId;

  Future<List<Invoice>> getInvoices({String? search}) async {
    final rows = await _db.query(
      'invoices',
      where: search == null || search.trim().isEmpty
          ? 'is_deleted = 0'
          : '(is_deleted = 0) AND (seller_name LIKE ? OR seller_name_en LIKE ? OR vat_number LIKE ? OR invoice_number LIKE ?)',
      whereArgs: search == null || search.trim().isEmpty
          ? null
          : List.filled(4, '%${search.trim()}%'),
      orderBy: 'issued_at DESC, id DESC',
    );
    return rows.map(Invoice.fromMap).toList();
  }

  Future<List<Shop>> getShops() async {
    final rows = await _db.query('shops');
    final invoices = await getInvoices();
    final profiles = <String, Map<String, Object?>>{
      for (final row in await _db.query('shop_profiles'))
        (row['key'] as String?) ?? '': row,
    };
    final shops = <Shop>[];
    for (final row in rows) {
      final vat = ((row['vat_number'] as String?) ?? '').trim();
      final nameAr = ((row['name_ar'] as String?) ?? '').trim();
      final shopInvoices = invoices.where((invoice) {
        final invoiceVat = invoice.vatNumber.trim();
        if (vat.isNotEmpty) return invoiceVat == vat;
        return invoiceVat.isEmpty && invoice.sellerName.trim() == nameAr;
      }).toList()
        ..sort((a, b) {
          final date = a.issuedAt.compareTo(b.issuedAt);
          return date == 0
              ? (a.id ?? '').compareTo(b.id ?? '')
              : date;
        });
      if (shopInvoices.isEmpty) continue;
      final profile = profiles[ShopProfile.keyFor(vatNumber: vat, nameAr: nameAr)];
      final profileDeleted = profile != null && ((profile['is_deleted'] as num?) ?? 0) != 0;
      shops.add(
        Shop(
          id: row['id'] as int,
          nameAr: nameAr,
          nameEn: ((row['name_en'] as String?) ?? '').trim(),
          displayName: profileDeleted
              ? ''
              : ((profile?['display_name'] as String?) ?? '').trim(),
          vatNumber: vat,
          note: profileDeleted ? '' : ((profile?['note'] as String?) ?? '').trim(),
          invoices: shopInvoices,
        ),
      );
    }
    shops.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return shops;
  }

  Future<String> insertInvoice(Invoice invoice) async {
    return _db.transaction<String>((transaction) async {
      final imageSha = await _attachImage(transaction, invoice);
      final effective = imageSha == null
          ? invoice
          : invoice.copyWith(imageSha256: imageSha);
      final row = _normalizedInvoiceRow(effective);
      await transaction.insert('invoices', row);
      await _upsertShop(transaction, row: row);
      return row['id'] as String;
    });
  }

  Future<void> updateInvoice(Invoice invoice) async {
    await _db.transaction((transaction) async {
      final imageSha = await _attachImage(transaction, invoice);
      final effective = imageSha == null
          ? invoice
          : invoice.copyWith(imageSha256: imageSha);
      final row = _normalizedInvoiceRow(effective);
      await transaction.update(
        'invoices',
        row,
        where: 'id = ?',
        whereArgs: [invoice.id],
      );
      // Re-linking by the invoice's own VAT number/name automatically moves
      // it between shops; pruning then removes a shop left without invoices.
      await _upsertShop(transaction, row: row);
      await _pruneOrphanShops(transaction);
    });
  }

  /// Soft-deletes the invoice so the removal propagates to peers, while
  /// keeping the existing behaviour of removing the local image file.
  Future<void> deleteInvoice(String id) async {
    final rows = await _db.query(
      'invoices',
      columns: ['image_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final imagePath = rows.isEmpty ? null : rows.first['image_path'] as String?;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        await File(imagePath).delete();
      } catch (_) {
        // The database row should still be deleted if the image is already gone.
      }
    }
    await _db.transaction((transaction) async {
      await transaction.update(
        'invoices',
        {
          'is_deleted': 1,
          'is_synced': 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await _pruneOrphanShops(transaction);
    });
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  /// Writes the user's custom name/note for the shop identified by
  /// [shopId]; the profile is keyed by the shop's business identity so it
  /// follows the same shop on other devices.
  Future<void> updateShopProfile({
    required int shopId,
    String? displayName,
    String? note,
  }) async {
    final rows = await _db.query(
      'shops',
      where: 'id = ?',
      whereArgs: [shopId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final vat = ((rows.first['vat_number'] as String?) ?? '').trim();
    final nameAr = ((rows.first['name_ar'] as String?) ?? '').trim();
    final profile = ShopProfile(
      key: ShopProfile.keyFor(vatNumber: vat, nameAr: nameAr),
      nameAr: nameAr,
      displayName: (displayName ?? '').trim(),
      note: (note ?? '').trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      isSynced: false,
    );
    await _db.insert(
      'shop_profiles',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- backups -----------------------------------------------------------

  /// Builds a ZIP archive containing the database export plus every image
  /// referenced by the media table. Restores accept this format and the
  /// legacy plain-JSON backups.
  Future<File> createBackupArchive() async {
    final json = await createBackupJson();
    final baseDir = _baseDirectoryPath;
    if (baseDir == null) {
      throw StateError('Database is not initialized');
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final jsonFile = File('$baseDir${p.separator}backup_$stamp.json');
    await jsonFile.writeAsString(json, flush: true);

    final zipPath =
        '$baseDir${p.separator}fatoora_lens_backup_$stamp.zip';
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    try {
      encoder.addFileSync(jsonFile, 'backup.json');
      for (final row in await _db.query('media')) {
        final localPath = row['local_path'] as String?;
        final sha = (row['sha256'] as String?) ?? '';
        if (localPath == null || sha.isEmpty) continue;
        final file = File(localPath);
        if (!file.existsSync()) continue;
        encoder.addFileSync(file, 'media/$sha');
      }
    } finally {
      encoder.closeSync();
    }
    try {
      await jsonFile.delete();
    } catch (_) {
      // The temporary JSON is best-effort cleanup.
    }
    return File(zipPath);
  }

  Future<String> createBackupJson() async {
    final invoices = await getInvoices();
    final profiles = await _db.query('shop_profiles');
    final media = await _db.query('media');
    final settings = await _db.query('settings');
    return jsonEncode({
      'schemaVersion': _schemaVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'invoices': invoices.map((invoice) => invoice.toMap()).toList(),
      'shopProfiles': profiles,
      'media': media,
      'settings': settings,
    });
  }

  /// Restores a ZIP backup: the JSON export plus the media folder. Every
  /// media entry is hash-verified against its file name before use, and
  /// unsafe entry paths are rejected (zip-slip protection).
  Future<void> restoreBackupArchive(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? backupJson;
    final mediaFiles = <String, Uint8List>{};
    for (final entry in archive) {
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.contains('..')) {
        throw FormatException('Unsafe backup entry: ${entry.name}');
      }
      if (name == 'backup.json') {
        backupJson = utf8.decode(entry.content as List<int>);
        continue;
      }
      if (name.startsWith('media/')) {
        final sha = name.substring('media/'.length);
        if (!_isSha256Hex(sha)) {
          throw FormatException('Unexpected media entry in backup: $name');
        }
        final content = Uint8List.fromList(entry.content as List<int>);
        final actualSha = crypto.sha256.convert(content).toString();
        if (actualSha != sha) {
          throw FormatException('Corrupted media entry in backup: $name');
        }
        mediaFiles[sha] = content;
      }
    }
    if (backupJson == null) {
      throw const FormatException('Invalid backup format');
    }
    final decoded = jsonDecode(backupJson);
    if (decoded is! Map<String, dynamic> || decoded['invoices'] is! List) {
      throw const FormatException('Invalid backup format');
    }
    final schemaVersion = (decoded['schemaVersion'] as num?)?.toInt() ?? 0;
    if (schemaVersion >= 7) {
      await _restoreV7(
        decoded,
        mediaFiles: mediaFiles,
      );
    } else {
      await restoreBackupJson(backupJson);
    }
  }

  Future<void> restoreBackupJson(String value) async {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> || decoded['invoices'] is! List) {
      throw const FormatException('Invalid backup format');
    }
    await _restoreV7(decoded, mediaFiles: const {});
  }

  Future<void> _restoreV7(
    Map<String, dynamic> decoded, {
    required Map<String, Uint8List> mediaFiles,
  }) async {
    final invoiceMaps = (decoded['invoices'] as List)
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .map(Invoice.fromMap)
        .toList();
    final profileMaps = <ShopProfile>[
      for (final row in (decoded['shopProfiles'] as List? ?? const [])
          .whereType<Map>())
        ShopProfile.fromMap(Map<String, Object?>.from(row)),
      // Legacy backups carried shop metadata inside the shops table.
      for (final row in (decoded['shops'] as List? ?? const [])
          .whereType<Map>())
        ..._legacyShopRowToProfiles(Map<String, Object?>.from(row)),
    ];

    final mediaDir = _mediaDirectoryPath;
    final mediaRows = <MediaRecord>[];
    if (mediaFiles.isNotEmpty && mediaDir != null) {
      final directory = Directory(mediaDir);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      for (final entry in mediaFiles.entries) {
        final target = File('${directory.path}${p.separator}${entry.key}');
        await target.writeAsBytes(entry.value, flush: true);
        mediaRows.add(
          MediaRecord(
            sha256: entry.key,
            bytes: entry.value.length,
            localPath: target.path,
          ),
        );
      }
    }

    await _db.transaction((transaction) async {
      await transaction.delete('invoices');
      await transaction.delete('shop_profiles');
      await transaction.delete('media');
      for (final invoice in invoiceMaps) {
        final row = _normalizedInvoiceRow(invoice, preserveIdentity: true);
        // Point image_path at the restored local copy when we have it.
        final sha = row['image_sha256'] as String?;
        if (sha != null && sha.isNotEmpty) {
          final local = mediaFiles[sha];
          if (local != null && _mediaDirectoryPath != null) {
            row['image_path'] =
                '$_mediaDirectoryPath${p.separator}$sha';
          }
        }
        await transaction.insert('invoices', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final profile in profileMaps) {
        await transaction.insert('shop_profiles', profile.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final media in mediaRows) {
        await transaction.insert('media', media.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _syncShops(transaction);
    });
  }

  static bool _isSha256Hex(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

  /// Converts a legacy (pre-7) shops backup row into a shop profile when
  /// it carries user metadata.
  static List<ShopProfile> _legacyShopRowToProfiles(Map<String, Object?> row) {
    final note = ((row['note'] as String?) ?? '').trim();
    final displayName = ((row['display_name'] as String?) ?? '').trim();
    if (note.isEmpty && displayName.isEmpty) return const [];
    final name = ((row['seller_name'] as String?) ?? '').trim();
    final vat = ((row['vat_number'] as String?) ?? '').trim();
    return [
      ShopProfile(
        key: ShopProfile.keyFor(vatNumber: vat, nameAr: name),
        nameAr: name,
        displayName: displayName,
        note: note,
      ),
    ];
  }

  // ---- sync helpers ------------------------------------------------------

  /// Prepares the database row for an insert/update: assigns the UUID and
  /// device id, normalizes the seller name and payload hash, and (unless
  /// [preserveIdentity], used by restores) stamps the row as locally
  /// modified.
  Map<String, Object?> _normalizedInvoiceRow(
    Invoice invoice, {
    bool preserveIdentity = false,
  }) {
    final row = invoice.toMap();
    final existingId = row['id'];
    row['id'] =
        existingId is String && existingId.isNotEmpty ? existingId : Invoice.newId();
    row['device_id'] = _deviceId ?? (row['device_id'] as String? ?? '');

    final (name, english) = _separateNames(
      (row['seller_name'] as String?)?.trim() ?? '',
      ((row['seller_name_en'] as String?) ?? '').trim(),
    );
    row['seller_name'] = name;
    row['seller_name_en'] = english;

    final payload = ((row['raw_payload'] as String?) ?? '').trim();
    row['payload_sha256'] = payload.isEmpty
        ? ''
        : crypto.sha256.convert(utf8.encode(payload)).toString();

    if (!preserveIdentity) {
      row['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      row['is_synced'] = 0;
    }
    return row;
  }

  /// Hashes the invoice image (when present) into the media table and
  /// returns the hash, or null when there is no usable image.
  Future<String?> _attachImage(DatabaseExecutor executor, Invoice invoice) async {
    final path = invoice.imagePath;
    if (path == null || path.isEmpty) return null;
    var sha = invoice.imageSha256;
    if (sha == null || sha.isEmpty) {
      sha = await _hashImageFile(path);
      if (sha == null) return null;
    }
    await _recordMedia(executor, sha, path);
    return sha;
  }

  Future<String?> _hashImageFile(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final digest = await crypto.sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _recordMedia(
    DatabaseExecutor executor,
    String sha,
    String? localPath,
  ) async {
    int bytes = 0;
    if (localPath != null) {
      try {
        bytes = await File(localPath).length();
      } catch (_) {
        bytes = 0;
      }
    }
    await executor.insert(
      'media',
      MediaRecord(
        sha256: sha,
        bytes: bytes,
        localPath: localPath,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Separates a mixed-script seller name into its Arabic and English
  /// parts. An English name provided by the user always wins over the
  /// automatically extracted one.
  static (String, String) _separateNames(String name, String english) {
    if (!SellerNameSplitter.isMixedScript(name)) {
      return (name, english);
    }
    final parts = SellerNameSplitter.split(name);
    return (
      parts.arabic.isNotEmpty ? parts.arabic : name,
      english.isNotEmpty ? english : parts.english,
    );
  }

  /// Rebuilds the shops table from the live invoices. Shops are identified
  /// by their VAT number; invoices without one fall back to the exact
  /// seller name. Mixed-script seller names are separated here too, so
  /// data saved by older versions is cleaned up on open.
  Future<void> _syncShops(DatabaseExecutor database) async {
    final rows = await database.query(
      'invoices',
      where: 'is_deleted = 0',
      // Deterministic order: the shop's names come from its oldest
      // invoice, matching the pre-UUID "first scan wins" behavior.
      orderBy: 'created_at ASC, id ASC',
    );
    final seeds = <String, _ShopSeed>{};
    for (final row in rows) {
      final invoice = Invoice.fromMap(Map<String, Object?>.from(row));
      final originalName = invoice.sellerName.trim();
      var (nameAr, nameEn) = _separateNames(
        originalName,
        invoice.sellerNameEn.trim(),
      );
      if (nameAr != originalName ||
          nameEn != invoice.sellerNameEn.trim()) {
        await database.update(
          'invoices',
          {'seller_name': nameAr, 'seller_name_en': nameEn},
          where: 'id = ?',
          whereArgs: [invoice.id],
        );
      }
      if (nameEn.isEmpty &&
          nameAr.isNotEmpty &&
          !SellerNameSplitter.containsArabic(nameAr)) {
        // A Latin-only seller name doubles as the shop's English name.
        nameEn = nameAr;
      }
      final vat = invoice.vatNumber.trim();
      final key = vat.isNotEmpty ? 'v:$vat' : 'n:$nameAr';
      final existingSeed = seeds[key];
      if (existingSeed != null) {
        // Row order is UUID-random now; keep an Arabic spelling as the
        // shop's primary name when one shows up, otherwise first wins.
        if (existingSeed.nameAr != nameAr &&
            SellerNameSplitter.containsArabic(nameAr) &&
            !SellerNameSplitter.containsArabic(existingSeed.nameAr)) {
          existingSeed.nameAr = nameAr;
        }
        if (nameEn.isNotEmpty && existingSeed.nameEn.isEmpty) {
          existingSeed.nameEn = nameEn;
        }
        continue;
      }
      final seed = seeds.putIfAbsent(
        key,
        () => _ShopSeed(vatNumber: vat, nameAr: nameAr),
      );
      if (nameEn.isNotEmpty && seed.nameEn.isEmpty) seed.nameEn = nameEn;
      seed.legacyName ??= originalName;
    }

    for (final seed in seeds.values) {
      final existing = await _findShopRow(database, seed);
      if (existing == null) {
        await database.insert('shops', {
          'vat_number': seed.vatNumber.isEmpty ? null : seed.vatNumber,
          'name_ar': seed.nameAr,
          'name_en': seed.nameEn == seed.nameAr ? '' : seed.nameEn,
          'created_at': DateTime.now().toIso8601String(),
        });
        continue;
      }
      final shopId = existing['id'] as int;
      final existingNameAr = ((existing['name_ar'] as String?) ?? '').trim();
      if (seed.nameEn.isNotEmpty &&
          seed.nameEn != existingNameAr &&
          ((existing['name_en'] as String?) ?? '').trim().isEmpty) {
        await database.update(
          'shops',
          {'name_en': seed.nameEn},
          where: 'id = ?',
          whereArgs: [shopId],
        );
      }
      if (seed.nameAr.isNotEmpty && existingNameAr.isEmpty) {
        await database.update(
          'shops',
          {'name_ar': seed.nameAr},
          where: 'id = ?',
          whereArgs: [shopId],
        );
      }
    }

    await _pruneOrphanShops(database);
  }

  Future<Map<String, Object?>?> _findShopRow(
    DatabaseExecutor database,
    _ShopSeed seed,
  ) async {
    if (seed.vatNumber.isNotEmpty) {
      final rows = await database.query(
        'shops',
        where: 'vat_number = ?',
        whereArgs: [seed.vatNumber],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first;
    }
    final rows = await database.query(
      'shops',
      where: 'vat_number IS NULL AND name_ar = ?',
      whereArgs: [seed.nameAr],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Links the invoice to its shop: the VAT number is the shop identity
  /// when present; invoices without one fall back to the exact seller name.
  /// Only missing shop fields are filled, so user edits on the shop survive.
  Future<void> _upsertShop(
    DatabaseExecutor executor, {
    required Map<String, Object?> row,
  }) async {
    final nameAr = ((row['seller_name'] as String?) ?? '').trim();
    var nameEn = ((row['seller_name_en'] as String?) ?? '').trim();
    final vat = ((row['vat_number'] as String?) ?? '').trim();
    if (nameEn.isEmpty &&
        nameAr.isNotEmpty &&
        !SellerNameSplitter.containsArabic(nameAr)) {
      // A Latin-only seller name doubles as the shop's English name.
      nameEn = nameAr;
    }
    if (nameAr.isEmpty && nameEn.isEmpty && vat.isEmpty) return;

    final existing = await _findShopRow(
      executor,
      _ShopSeed(vatNumber: vat, nameAr: nameAr),
    );
    if (existing == null) {
      await executor.insert('shops', {
        'vat_number': vat.isEmpty ? null : vat,
        'name_ar': nameAr,
        'name_en': nameEn == nameAr ? '' : nameEn,
        'created_at': DateTime.now().toIso8601String(),
      });
      return;
    }
    final shopId = existing['id'] as int;
    final existingNameAr = ((existing['name_ar'] as String?) ?? '').trim();
    final fillNameEn = nameEn.isNotEmpty &&
        nameEn != existingNameAr &&
        ((existing['name_en'] as String?) ?? '').trim().isEmpty;
    if (fillNameEn) {
      await executor.update(
        'shops',
        {'name_en': nameEn},
        where: 'id = ?',
        whereArgs: [shopId],
      );
    }
    if (nameAr.isNotEmpty && existingNameAr.isEmpty) {
      await executor.update(
        'shops',
        {'name_ar': nameAr},
        where: 'id = ?',
        whereArgs: [shopId],
      );
    }
  }

  /// Removes shops that no longer have any live invoice. Tombstoned
  /// invoices do not keep their shop alive.
  Future<void> _pruneOrphanShops(DatabaseExecutor database) async {
    await database.rawDelete('''
      DELETE FROM shops WHERE NOT EXISTS (
        SELECT 1 FROM invoices i WHERE i.is_deleted = 0 AND (
          (shops.vat_number IS NOT NULL AND i.vat_number = shops.vat_number)
          OR (
            shops.vat_number IS NULL
            AND i.vat_number = ''
            AND i.seller_name = shops.name_ar
          )
        )
      )
    ''');
  }
}

/// Invoice data used to create or complete one shop row while syncing.
class _ShopSeed {
  _ShopSeed({required this.vatNumber, required this.nameAr});

  final String vatNumber;
  String nameAr;
  String nameEn = '';

  /// The seller name as stored before this sync, used to match notes from
  /// the pre-6 shops table that were keyed by the (possibly combined) name.
  String? legacyName;
}
