import 'dart:async';
import 'dart:collection';

import '../data/database_service.dart';
import 'security/sync_secure_channel.dart';
import 'sync_preferences.dart';
import 'sync_repository.dart';

/// Outcome of one sync session on this device.
class SyncSessionResult {
  String? peerDeviceId;
  int sentInvoices = 0;
  int sentProfiles = 0;
  int receivedInvoices = 0;
  int receivedProfiles = 0;
  int applied = 0;
  int overwritten = 0;
  int keptLocal = 0;
  int duplicatesSkipped = 0;
  final List<String> mediaNeeded = <String>[];
  bool success = false;
  String? error;

  Map<String, Object?> toSummary() => {
        'peer': peerDeviceId ?? '',
        'sentInvoices': sentInvoices,
        'sentProfiles': sentProfiles,
        'received': receivedInvoices + receivedProfiles,
        'applied': applied,
        'overwritten': overwritten,
        'keptLocal': keptLocal,
        'duplicatesSkipped': duplicatesSkipped,
        'mediaNeeded': mediaNeeded.length,
        'success': success,
      };
}

/// Drives one symmetric sync session over an established secure channel:
/// both devices exchange metadata, send their scoped payloads, merge
/// inbound rows non-destructively, and advance their per-peer cursors.
class SyncSessionEngine {
  SyncSessionEngine({
    required this.channel,
    required this.database,
    required this.preferences,
    this.batchSize = 100,
  });

  static const String _metaFrame = 'meta';
  static const String _rowsFrame = 'rows';
  static const String _dataEndFrame = 'data-end';
  static const String _summaryFrame = 'summary';
  static const String _byeFrame = 'bye';

  final SyncSecureChannel channel;
  final DatabaseService database;
  final SyncPreferences preferences;
  final int batchSize;

  int _seq = 0;
  int get _nextSeq => ++_seq;

  Future<SyncSessionResult> run({
    Duration timeout = const Duration(minutes: 5),
  }) {
    return runSession().timeout(timeout);
  }

  Future<SyncSessionResult> runSession() async {
    final result = SyncSessionResult();
    final repo = SyncRepository(database.syncDatabase);

    // Inbound pipe: subscribed before anything is sent so no frame is
    // dropped on carriers that discard un-listened events.
    final inboundMeta = Completer<Map<String, Object?>>();
    final inboundEnd = Completer<void>();
    final inboundSummary = Completer<Map<String, Object?>>();
    final inboundBye = Completer<void>();
    final pendingBatches = Queue<Map<String, Object?>>();
    var mergeChain = Future<void>.value();

    final subscription = channel.frames.listen(
      (frame) {
        switch (frame.type) {
          case _metaFrame:
            if (!inboundMeta.isCompleted) {
              inboundMeta.complete(Map<String, Object?>.from(frame.data));
            }
          case _rowsFrame:
            pendingBatches.add(Map<String, Object?>.from(frame.data));
          case _dataEndFrame:
            if (!inboundEnd.isCompleted) inboundEnd.complete();
          case _summaryFrame:
            if (!inboundSummary.isCompleted) {
              inboundSummary.complete(Map<String, Object?>.from(frame.data));
            }
          case _byeFrame:
            if (!inboundBye.isCompleted) inboundBye.complete();
          case 'error':
            if (!inboundEnd.isCompleted) {
              inboundEnd.completeError(
                StateError('${frame.data['message'] ?? 'peer error'}'),
              );
            }
        }
      },
      onError: (Object error) {
        if (!inboundEnd.isCompleted) inboundEnd.completeError(error);
        if (!inboundMeta.isCompleted) inboundMeta.completeError(error);
        if (!inboundSummary.isCompleted) inboundSummary.completeError(error);
      },
    );

    try {
      // 1. Exchange session metadata.
      await channel.sendControl(
        _metaFrame,
        seq: _nextSeq,
        data: {
          'deviceId': database.deviceId ?? '',
          'prefs': preferences.toJson(),
        },
      );
      final peerMeta = await inboundMeta.future;
      final peerId = (peerMeta['deviceId'] as String?) ?? '';
      result.peerDeviceId = peerId;

      // 2. Build and stream our outbound payload (scope = our own prefs).
      final payload = await repo.buildOutboundPayload(peerId, preferences);
      result.sentInvoices = payload.invoices.length;
      result.sentProfiles = payload.profiles.length;
      for (var i = 0; i < payload.invoices.length; i += batchSize) {
        await channel.sendControl(
          _rowsFrame,
          seq: _nextSeq,
          data: {
            'kind': 'invoices',
            'rows': payload.invoices.sublist(
              i,
              i + batchSize > payload.invoices.length
                  ? payload.invoices.length
                  : i + batchSize,
            ),
          },
        );
      }
      for (var i = 0; i < payload.profiles.length; i += batchSize) {
        await channel.sendControl(
          _rowsFrame,
          seq: _nextSeq,
          data: {
            'kind': 'profiles',
            'rows': payload.profiles.sublist(
              i,
              i + batchSize > payload.profiles.length
                  ? payload.profiles.length
                  : i + batchSize,
            ),
          },
        );
      }
      await channel.sendControl(_dataEndFrame, seq: _nextSeq);

      // 3. Merge inbound batches in arrival order.
      while (!inboundEnd.isCompleted || pendingBatches.isNotEmpty) {
        if (pendingBatches.isEmpty) {
          await inboundEnd.future;
          continue;
        }
        final batch = pendingBatches.removeFirst();
        final kind = batch['kind'] as String? ?? 'invoices';
        final rows = ((batch['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((row) => Map<String, Object?>.from(row))
            .toList();
        mergeChain = mergeChain.then((_) async {
          if (kind == 'profiles') {
            final merged = await repo.mergeShopProfiles(rows);
            result.receivedProfiles += rows.length;
            result.applied += merged.applied;
            result.overwritten += merged.overwritten;
            result.keptLocal += merged.keptLocal;
          } else {
            final merged = await repo.mergeInvoices(rows);
            result.receivedInvoices += rows.length;
            result.applied += merged.applied;
            result.overwritten += merged.overwritten;
            result.keptLocal += merged.keptLocal;
            result.duplicatesSkipped += merged.duplicatesSkipped;
            for (final sha in merged.mediaNeeded) {
              if (!result.mediaNeeded.contains(sha)) {
                result.mediaNeeded.add(sha);
              }
            }
          }
        });
      }
      await mergeChain;
      // Merged rows bypass insertInvoice, so the derived shops table must
      // be rebuilt before anything reads it.
      await database.refreshDerivedShops();

      // 4. Exchange summaries, then close the round.
      await channel.sendControl(
        _summaryFrame,
        seq: _nextSeq,
        data: {
          'applied': result.applied,
          'overwritten': result.overwritten,
          'keptLocal': result.keptLocal,
          'duplicatesSkipped': result.duplicatesSkipped,
          'mediaNeeded': result.mediaNeeded,
        },
      );
      await inboundSummary.future;

      if (peerId.isNotEmpty) {
        await repo.advanceCursors(
          peerId,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      await channel.sendControl(_byeFrame, seq: _nextSeq);
      result.success = true;
      return result;
    } catch (error) {
      result.error = '$error';
      return result;
    } finally {
      await subscription.cancel();
    }
  }
}
