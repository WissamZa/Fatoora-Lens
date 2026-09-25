import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqflite/sqflite.dart';

import 'sync_preferences.dart';

/// Per-peer, per-table high-water mark so syncs are deltas, not full
/// re-sends. Tombstones always travel regardless of the cursor.
const String kTableInvoices = 'invoices';
const String kTableShopProfiles = 'shop_profiles';

/// Everything the initiator needs to send for one sync session.
class SyncOutboundPayload {
  const SyncOutboundPayload({
    required this.invoices,
    required this.profiles,
    required this.mediaHashes,
  });

  /// JSON-safe rows (Invoice.toMap shape).
  final List<Map<String, Object?>> invoices;
  final List<Map<String, Object?>> profiles;

  /// Hashes of media files referenced by the outbound invoices; the media
  /// pipeline transfers only the ones the peer reports missing.
  final List<String> mediaHashes;
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

/// Builds outbound payloads according to the user's [SyncPreferences] and
/// merges inbound rows with non-destructive last-write-wins semantics.
class SyncRepository {
  SyncRepository(this.database);

  final Database database;

  // ---- outbound ---------------------------------------------------------

  /// Selects the rows to send to [peerId] given the stored cursor and the
  /// user's scope. Tombstones are always included; live rows honor both
  /// the cursor and the optional date filter.
  Future<SyncOutboundPayload> buildOutboundPayload(
    String peerId,
    SyncPreferences preferences,
  ) async {
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
        invoices.add(_jsonSafe(row));
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
        profiles.add(_jsonSafe(row));
      }
    }

    return SyncOutboundPayload(
      invoices: invoices,
      profiles: profiles,
      mediaHashes: mediaHashes.toList(),
    );
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
    await database.transaction((txn) async {
      for (final rawRow in rows) {
        final row = _jsonSafe(rawRow);
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
          final duplicate = await txn.rawQuery(
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
              await txn.update(
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
            await _log(txn, 'inbound', 'invoices', id, 'duplicate-skipped',
                'payload $payloadSha already stored');
            continue;
          }
        }

        final existing = await txn.query(
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
            await _log(txn, 'inbound', 'invoices', id, 'kept-local',
                'local row is newer');
            continue;
          }
          await txn.insert(
            'invoices',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          result.overwritten++;
        } else {
          await txn.insert('invoices', row);
          result.applied++;
        }
        if (!isDeleted && incomingSha.isNotEmpty) {
          mediaCandidates.add(incomingSha);
        }
      }
    });
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
    await database.transaction((txn) async {
      for (final rawRow in rows) {
        final row = _jsonSafe(rawRow);
        final key = row['key'] as String?;
        if (key == null || key.isEmpty) continue;
        final existing = await txn.query(
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
          await txn.insert(
            'shop_profiles',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          result.overwritten++;
          continue;
        }
        await txn.insert('shop_profiles', row);
        result.applied++;
      }
    });
    return result;
  }

  // ---- cursors and logging ----------------------------------------------

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
  /// acknowledged sync round.
  Future<void> advanceCursors(String peerId, int timestamp) async {
    await updateSyncCursor(peerId, kTableInvoices, timestamp);
    await updateSyncCursor(peerId, kTableShopProfiles, timestamp);
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
