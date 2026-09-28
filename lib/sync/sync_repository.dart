import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqflite/sqflite.dart';

import 'sync_preferences.dart';

/// Per-peer, per-table high-water mark so syncs are deltas, not full
/// re-sends. Tombstones always travel regardless of the cursor.
const String kTableInvoices = 'invoices';
const String kTableShopProfiles = 'shop_profiles';
const String kTableShopCategories = 'shop_categories';
const String kTablePaymentMethods = 'payment_methods';
const String kTablePaymentCards = 'payment_cards';

/// The sync protocol this build speaks. Peers advertise their version in
/// the session handshake; version 1 = legacy builds, which must never
/// receive the v8 catalog tables (they would treat unknown row kinds as
/// invoices) nor the v8 columns (their INSERT would fail on the missing
/// columns). Rows bound for a legacy peer are filtered down to the exact
/// v7 column set.
const int kSyncProto = 2;

/// The invoices columns as schema v7 knew them; the wire shape legacy
/// peers can consume.
const Set<String> _legacyInvoiceColumns = {
  'id',
  'device_id',
  'seller_name',
  'seller_name_en',
  'vat_number',
  'issued_at',
  'total_amount',
  'vat_amount',
  'raw_payload',
  'payload_sha256',
  'invoice_number',
  'note',
  'image_path',
  'image_sha256',
  'updated_at',
  'is_synced',
  'is_deleted',
  'created_at',
};

/// The shop_profiles columns as schema v7 knew them.
const Set<String> _legacyProfileColumns = {
  'key',
  'name_ar',
  'name_en',
  'display_name',
  'note',
  'updated_at',
  'is_synced',
  'is_deleted',
};

/// Everything the initiator needs to send for one sync session.
class SyncOutboundPayload {
  const SyncOutboundPayload({
    required this.invoices,
    required this.profiles,
    required this.mediaHashes,
    this.categories = const [],
    this.paymentMethods = const [],
    this.cards = const [],
  });

  /// JSON-safe rows (Invoice.toMap shape).
  final List<Map<String, Object?>> invoices;
  final List<Map<String, Object?>> profiles;

  /// Hashes of media files referenced by the outbound invoices; the media
  /// pipeline transfers only the ones the peer reports missing.
  final List<String> mediaHashes;

  /// v8 catalog rows; only built when the peer speaks proto >= 2.
  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> paymentMethods;
  final List<Map<String, Object?>> cards;
}

/// Outcome of merging one inbound batch.
class SyncMergeResult {
  int applied = 0;
  int overwritten = 0;
  int keptLocal = 0;
  int duplicatesSkipped = 0;
  final List<String> mediaNeeded = <String>[];

  Map<String, Object?> toSummary() => {
        'applied': applied,
        'overwritten': overwritten,
        'keptLocal': keptLocal,
        'duplicatesSkipped': duplicatesSkipped,
        'mediaNeeded': mediaNeeded.length,
      };
}

/// Builds outbound payloads according to the user's [SyncPreferences]
/// and the peer's protocol version, and merges inbound rows with
/// non-destructive last-write-wins semantics.
class SyncRepository {
  SyncRepository(this.database);

  final Database database;

  /// Column names of the local [table], resolved once per instance.
  /// Inbound rows are filtered down to these, so a future peer sending
  /// columns this build does not know yet can never break the INSERT.
  Future<Set<String>> _localColumns(String table) async {
    final cached = _columnsCache[table];
    if (cached != null) return cached;
    final info = await database.rawQuery('PRAGMA table_info($table)');
    final columns = {
      for (final row in info) (row['name'] as String?) ?? '',
    };
    _columnsCache[table] = columns;
    return columns;
  }

  final Map<String, Set<String>> _columnsCache = {};

  // ---- outbound ---------------------------------------------------------

  /// Selects the rows to send to [peerId] given the stored cursor, the
  /// user's scope and the peer's protocol version. Tombstones are always
  /// included; live rows honor both the cursor and the optional date
  /// filter. The v8 catalog tables only travel to proto >= 2 peers.
  Future<SyncOutboundPayload> buildOutboundPayload(
    String peerId,
    SyncPreferences preferences, {
    int peerProto = kSyncProto,
  }) async {
    final peerIsLegacy = peerProto < 2;
    final invoices = <Map<String, Object?>>[];
    final mediaHashes = <String>{};

    if (preferences.syncInvoices) {
      final cursor = await syncCursor(peerId, kTableInvoices);
      final filters = <String>['updated_at > ?'];
      final args = <Object?>[cursor];
      if (preferences.issuedAtFrom != null) {
        // The date scope only limits live rows; tombstones bypass it.
        filters.add('(is_deleted = 1 OR issued_at >= ?)');
        args.add(preferences.issuedAtFrom!
            .toUtc()
            .toIso8601String());
      }
      final rows = await database.query(
        'invoices',
        where: filters.join(' AND '),
        whereArgs: args,
        orderBy: 'updated_at ASC',
      );
      for (final row in rows) {
        final outgoing = _jsonSafe(row);
        // image_path is a per-device local path and is meaningless to the
        // peer; the media pipeline addresses files by hash only.
        outgoing['image_path'] = null;
        invoices.add(
          peerIsLegacy
              ? _filteredRow(outgoing, _legacyInvoiceColumns)
              : outgoing,
        );
        final sha = row['image_sha256'] as String?;
        if (preferences.syncImages &&
            sha != null &&
            sha.isNotEmpty &&
            (row['is_deleted'] as int? ?? 0) == 0) {
          mediaHashes.add(sha);
        }
      }
    }

    final profiles = <Map<String, Object?>>[];
    if (preferences.syncShopProfiles) {
      final cursor = await syncCursor(peerId, kTableShopProfiles);
      final rows = await database.query(
        'shop_profiles',
        where: 'updated_at > ?',
        whereArgs: [cursor],
        orderBy: 'updated_at ASC',
      );
      for (final row in rows) {
        final outgoing = _jsonSafe(row);
        profiles.add(
          peerIsLegacy
              ? _filteredRow(outgoing, _legacyProfileColumns)
              : outgoing,
        );
      }
    }

    var categories = <Map<String, Object?>>[];
    var methods = <Map<String, Object?>>[];
    var cards = <Map<String, Object?>>[];
    if (!peerIsLegacy) {
      categories = await _rowsSince(peerId, kTableShopCategories);
      methods = await _rowsSince(peerId, kTablePaymentMethods);
      cards = await _rowsSince(peerId, kTablePaymentCards);
    }

    return SyncOutboundPayload(
      invoices: invoices,
      profiles: profiles,
      mediaHashes: mediaHashes.toList(),
      categories: categories,
      paymentMethods: methods,
      cards: cards,
    );
  }

  /// Delta query for one catalog table: rows newer than the peer's
  /// cursor. Tombstones carry a fresh updated_at, so deletions travel.
  Future<List<Map<String, Object?>>> _rowsSince(
    String peerId,
    String table,
  ) async {
    final cursor = await syncCursor(peerId, table);
    final rows = await database.query(
      table,
      where: 'updated_at > ?',
      whereArgs: [cursor],
      orderBy: 'updated_at ASC',
    );
    return rows.map(_jsonSafe).toList();
  }

  // ---- inbound ----------------------------------------------------------

  /// Merges inbound invoice rows with last-write-wins semantics:
  /// a row is applied only when it is strictly newer than the local one
  /// (ties broken deterministically by device id). Inbound rows for a
  /// different physical invoice that shares the same QR payload hash are
  /// counted as duplicates and skipped, so a paper receipt scanned on two
  /// devices is never counted twice.
  Future<SyncMergeResult> mergeInvoices(
    List<Map<String, Object?>> rows,
  ) async {
    final result = SyncMergeResult();
    final mediaCandidates = <String>{};
    // Rows are applied one by one without wrapping the batch in a
    // transaction: each statement is atomic on its own, and long-lived
    // transactions have been observed to deadlock the sqflite method
    // channel on some Android devices. A crash mid-batch simply leaves
    // rows unmerged for the next sync - never a corrupted state.
    for (final rawRow in rows) {
        // Defensive: drop keys this build's table does not know, so a
        // newer peer can never break the local INSERT.
        final row = _filteredRow(
          _jsonSafe(rawRow),
          await _localColumns('invoices'),
        );
        final id = row['id'] as String?;
        if (id == null || id.isEmpty) continue; // Malformed; ignore.
        final isDeleted = ((row['is_deleted'] as num?) ?? 0) != 0;
        var payloadSha = ((row['payload_sha256'] as String?) ?? '').trim();
        final rawPayload = ((row['raw_payload'] as String?) ?? '').trim();
        if (payloadSha.isEmpty && rawPayload.isNotEmpty) {
          // Rows written before schema v7 may lack the hash; compute it so
          // duplicate detection keeps working for them.
          payloadSha =
              crypto.sha256.convert(utf8.encode(rawPayload)).toString();
          row['payload_sha256'] = payloadSha;
        }
        final incomingSha = ((row['image_sha256'] as String?) ?? '').trim();

        if (!isDeleted && payloadSha.isNotEmpty) {
          final duplicate = await database.rawQuery(
            'SELECT id, image_sha256, note FROM invoices '
            'WHERE payload_sha256 = ? AND is_deleted = 0 AND id != ? LIMIT 1',
            [payloadSha, id],
          );
          if (duplicate.isNotEmpty) {
            result.duplicatesSkipped++;
            // Same physical receipt: keep the local row but adopt any
            // missing metadata from the twin (image hash, note).
            final local = duplicate.first;
            final updates = <String, Object?>{};
            final localSha = ((local['image_sha256'] as String?) ?? '').trim();
            if (localSha.isEmpty && incomingSha.isNotEmpty) {
              updates['image_sha256'] = incomingSha;
            }
            final localNote = ((local['note'] as String?) ?? '').trim();
            final incomingNote = ((row['note'] as String?) ?? '').trim();
            if (localNote.isEmpty && incomingNote.isNotEmpty) {
              updates['note'] = incomingNote;
            }
            if (updates.isNotEmpty) {
              final localId = local['id'] as String;
              await database.update(
                'invoices',
                updates,
                where: 'id = ?',
                whereArgs: [localId],
              );
              if (incomingSha.isNotEmpty) {
                // The twin carried an image this device lacks: request it
                // through the media pipeline.
                mediaCandidates.add(incomingSha);
              }
            }
            await _log(database, 'inbound', 'invoices', id, 'duplicate-skipped',
                'payload $payloadSha already stored');
            continue;
          }
        }

        final existing = await database.query(
          'invoices',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final incomingUpdatedAt = (row['updated_at'] as num?)?.toInt() ?? 0;
          final localUpdatedAt =
              (existing.first['updated_at'] as num?)?.toInt() ?? 0;
          final incomingDevice = ((row['device_id'] as String?) ?? '');
          final localDevice =
              ((existing.first['device_id'] as String?) ?? '');
          final incomingWins = incomingUpdatedAt > localUpdatedAt ||
              (incomingUpdatedAt == localUpdatedAt &&
                  incomingDevice.compareTo(localDevice) > 0);
          if (!incomingWins) {
            result.keptLocal++;
            await _log(database, 'inbound', 'invoices', id, 'kept-local',
                'local row is newer');
            continue;
          }
          await database.insert(
            'invoices',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          result.overwritten++;
        } else {
          await database.insert('invoices', row);
          result.applied++;
        }
        if (!isDeleted && incomingSha.isNotEmpty) {
          mediaCandidates.add(incomingSha);
        }
    }
    // Media bookkeeping runs outside the write transaction on purpose:
    // file probes have no business holding the database lock.
    for (final sha in mediaCandidates) {
      var localPath = await _mediaLocalPath(sha);
      if (localPath == null) {
        // Fall back to the path recorded on the invoice row itself.
        final rowsWithSha = await database.query(
          'invoices',
          columns: ['image_path'],
          where: 'image_sha256 = ? AND is_deleted = 0',
          whereArgs: [sha],
          limit: 1,
        );
        if (rowsWithSha.isNotEmpty) {
          localPath = rowsWithSha.first['image_path'] as String?;
        }
      }
      final hasFile = localPath != null &&
          localPath.isNotEmpty &&
          File(localPath).existsSync();
      if (!hasFile) {
        if (!result.mediaNeeded.contains(sha)) result.mediaNeeded.add(sha);
      } else {
        await database.execute(
          "UPDATE invoices SET image_path = ? WHERE image_sha256 = ? "
          "AND (image_path IS NULL OR image_path = '')",
          [localPath, sha],
        );
      }
    }
    return result;
  }

  /// Merges inbound shop profiles with the same last-write-wins rule.
  Future<SyncMergeResult> mergeShopProfiles(
    List<Map<String, Object?>> rows,
  ) async {
    final result = SyncMergeResult();
    final columns = await _localColumns('shop_profiles');
    for (final rawRow in rows) {
        final row = _filteredRow(_jsonSafe(rawRow), columns);
        final key = row['key'] as String?;
        if (key == null || key.isEmpty) continue;
        final existing = await database.query(
          'shop_profiles',
          where: 'key = ?',
          whereArgs: [key],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final incomingUpdatedAt = (row['updated_at'] as num?)?.toInt() ?? 0;
          final localUpdatedAt =
              (existing.first['updated_at'] as num?)?.toInt() ?? 0;
          if (incomingUpdatedAt <= localUpdatedAt) {
            result.keptLocal++;
            continue;
          }
          await database.insert(
            'shop_profiles',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          result.overwritten++;
          continue;
        }
        await database.insert('shop_profiles', row);
        result.applied++;
    }
    return result;
  }

  // ---- cursors and logging ----------------------------------------------

  /// Merges inbound v8 catalog rows (shop categories, payment methods,
  /// cards) with the same last-write-wins rule as invoices, including the
  /// device-id tiebreak for identical timestamps.
  Future<SyncMergeResult> mergeCatalogRows(
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    final result = SyncMergeResult();
    final columns = await _localColumns(table);
    for (final rawRow in rows) {
      final row = _filteredRow(_jsonSafe(rawRow), columns);
      final id = row['id'] as String?;
      if (id == null || id.isEmpty) continue; // Malformed; ignore.
      final existing = await database.query(
        table,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final incomingUpdatedAt = (row['updated_at'] as num?)?.toInt() ?? 0;
        final localUpdatedAt =
            (existing.first['updated_at'] as num?)?.toInt() ?? 0;
        final incomingDevice = ((row['device_id'] as String?) ?? '');
        final localDevice = ((existing.first['device_id'] as String?) ?? '');
        final incomingWins = incomingUpdatedAt > localUpdatedAt ||
            (incomingUpdatedAt == localUpdatedAt &&
                incomingDevice.compareTo(localDevice) > 0);
        if (!incomingWins) {
          result.keptLocal++;
          await _log(database, 'inbound', table, id, 'kept-local',
              'local row is newer');
          continue;
        }
        await database.insert(
          table,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        result.overwritten++;
      } else {
        await database.insert(table, row);
        result.applied++;
      }
    }
    return result;
  }

  Future<SyncMergeResult> mergeShopCategories(
    List<Map<String, Object?>> rows,
  ) =>
      mergeCatalogRows(kTableShopCategories, rows);

  Future<SyncMergeResult> mergePaymentMethods(
    List<Map<String, Object?>> rows,
  ) =>
      mergeCatalogRows(kTablePaymentMethods, rows);

  Future<SyncMergeResult> mergePaymentCards(
    List<Map<String, Object?>> rows,
  ) =>
      mergeCatalogRows(kTablePaymentCards, rows);

  Future<int> syncCursor(String peerId, String table) async {
    final rows = await database.query(
      'sync_state',
      where: 'peer_id = ? AND table_name = ?',
      whereArgs: [peerId, table],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['last_synced_at'] as num?)?.toInt() ?? 0;
  }

  Future<void> updateSyncCursor(
    String peerId,
    String table,
    int timestamp,
  ) async {
    await database.insert(
      'sync_state',
      {
        'peer_id': peerId,
        'table_name': table,
        'last_synced_at': timestamp,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Advances every table cursor for [peerId] to [timestamp] after a fully
  /// acknowledged sync round. The v8 catalog cursors only advance when
  /// this session actually shipped those tables ([includeExtras]); legacy
  /// peers keep them at 0 so nothing is lost once they upgrade.
  Future<void> advanceCursors(
    String peerId,
    int timestamp, {
    bool includeExtras = true,
  }) async {
    await updateSyncCursor(peerId, kTableInvoices, timestamp);
    await updateSyncCursor(peerId, kTableShopProfiles, timestamp);
    if (includeExtras) {
      await updateSyncCursor(peerId, kTableShopCategories, timestamp);
      await updateSyncCursor(peerId, kTablePaymentMethods, timestamp);
      await updateSyncCursor(peerId, kTablePaymentCards, timestamp);
    }
  }

  /// Clears every per-peer cursor so the next session re-sends the full
  /// payload. Used when a peer's advertised protocol version changes: rows
  /// that were column-filtered for the older version then travel in full
  /// (safe — the LWW merge is idempotent).
  Future<void> resetCursors(String peerId) async {
    await database.delete(
      'sync_state',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  Future<void> _log(
    DatabaseExecutor executor,
    String direction,
    String entity,
    String entityId,
    String action,
    String detail,
  ) async {
    await executor.insert('sync_log', {
      'session_id': '',
      'direction': direction,
      'entity': entity,
      'entity_id': entityId,
      'action': action,
      'detail': detail,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// The local path of a stored media file, or null when this device has
  /// no record (or the file disappeared).
  Future<String?> _mediaLocalPath(String sha) async {
    final rows = await database.query(
      'media',
      columns: ['local_path'],
      where: 'sha256 = ?',
      whereArgs: [sha],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['local_path'] as String?;
  }
}

/// Returns a JSON-safe copy of a database row (ints/strings/num only).
Map<String, Object?> _jsonSafe(Map<String, Object?> row) =>
    Map<String, Object?>.of(row);

/// Copies [row], keeping only the keys in [columns] — used to shape rows
/// for legacy peers and to defend inbound merges against unknown columns.
Map<String, Object?> _filteredRow(
  Map<String, Object?> row,
  Set<String> columns,
) =>
    Map<String, Object?>.from({
      for (final entry in row.entries)
        if (columns.contains(entry.key)) entry.key: entry.value,
    });
