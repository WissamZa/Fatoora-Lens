import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

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
  int mediaTransferred = 0;
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
        'mediaTransferred': mediaTransferred,
        'success': success,
      };
}

/// Inbound events are queued on arrival and drained by one serial chain,
/// so nothing is dropped on carriers that discard un-listened events and
/// everything keeps its arrival order.
sealed class _InboundEvent {
  const _InboundEvent();
}

class _MetaEvent extends _InboundEvent {
  _MetaEvent(this.data);
  final Map<String, Object?> data;
}

class _RowsEvent extends _InboundEvent {
  _RowsEvent(this.kind, this.rows);
  final String kind;
  final List<Map<String, Object?>> rows;
}

class _DataEndEvent extends _InboundEvent {
  const _DataEndEvent();
}

class _MediaStartEvent extends _InboundEvent {
  _MediaStartEvent(this.sha, this.totalBytes, this.chunks);
  final String sha;
  final int totalBytes;
  final int chunks;
}

class _MediaChunkEvent extends _InboundEvent {
  _MediaChunkEvent(this.bytes);
  final Uint8List bytes;
}

class _MediaEndEvent extends _InboundEvent {
  const _MediaEndEvent();
}


class _SummaryEvent extends _InboundEvent {
  _SummaryEvent(this.data);
  final Map<String, Object?> data;
}

class _ByeEvent extends _InboundEvent {
  const _ByeEvent();
}

/// Accumulates one incoming media file across its chunks.
class _MediaReceiveState {
  String? sha;
  int expectedChunks = 0;
  final bytesBuilder = BytesBuilder(copy: true);

  void start(String sha, int chunks) {
    this.sha = sha;
    expectedChunks = chunks;
  }

  void addChunk(Uint8List chunk) {
    bytesBuilder.add(chunk);
  }

  Future<int> finish(DatabaseService database) async {
    final expectedSha = sha;
    sha = null;
    if (expectedSha == null) return 0;
    final bytes = bytesBuilder.takeBytes();
    final ok = await database.storeMediaFile(expectedSha, bytes);
    return ok ? 1 : 0;
  }
}

/// Drives one symmetric sync session over an established secure channel:
/// both devices exchange metadata, stream their scoped payloads, merge
/// inbound rows non-destructively, transfer requested media files in
/// hash-verified chunks, and advance their per-peer cursors.
class SyncSessionEngine {
  SyncSessionEngine({
    required this.channel,
    required this.database,
    required this.preferences,
    this.batchSize = 100,
    this.mediaChunkSize = 64 * 1024,
  });

  static const String _metaFrame = 'meta';
  static const String _rowsFrame = 'rows';
  static const String _dataEndFrame = 'data-end';
  static const String _summaryFrame = 'summary';
  static const String _mediaStartFrame = 'media-start';
  static const String _mediaEndFrame = 'media-end';
  static const String _byeFrame = 'bye';

  final SyncSecureChannel channel;
  final DatabaseService database;
  final SyncPreferences preferences;
  final int batchSize;
  final int mediaChunkSize;

  int _seq = 0;
  int get _nextSeq => ++_seq;

  /// The protocol step that failed, reported inside [SyncSessionResult.error].
  String _step = 'start';

  final _MediaReceiveState _media = _MediaReceiveState();

  Future<SyncSessionResult> run({
    Duration timeout = const Duration(minutes: 10),
  }) {
    return runSession().timeout(timeout);
  }

  Future<SyncSessionResult> runSession() async {
    final result = SyncSessionResult();
    final repo = SyncRepository(database.syncDatabase);

    final events = Queue<_InboundEvent>();
    final metaReady = Completer<Map<String, Object?>>();
    final peerDataEnd = Completer<void>();
    final summaryReady = Completer<Map<String, Object?>>();
    final byeReceived = Completer<void>();
    var processing = Future<void>.value();

    Future<void> enqueue(_InboundEvent event) {
      events.add(event);
      processing = processing
          .then((_) => _drainEvent(events, repo, result))
          .catchError((Object error, StackTrace stackTrace) {
        result.error ??= 'receive: $error';
      });
      return processing;
    }

    final subscription = channel.frames.listen(
      (frame) {
        switch (frame.type) {
          case _metaFrame:
            final event = _MetaEvent(Map<String, Object?>.from(frame.data));
            unawaited(enqueue(event).then((_) {
              if (!metaReady.isCompleted) metaReady.complete(event.data);
            }, onError: (Object error, StackTrace stackTrace) {
              if (!metaReady.isCompleted) {
                metaReady.completeError(error, stackTrace);
              }
            }));
          case _rowsFrame:
            final rows = ((frame.data['rows'] as List?) ?? const [])
                .whereType<Map>()
                .map((row) => Map<String, Object?>.from(row))
                .toList();
            unawaited(enqueue(_RowsEvent(
              frame.data['kind'] as String? ?? 'invoices',
              rows,
            )));
          case _dataEndFrame:
            unawaited(enqueue(const _DataEndEvent()));
            if (!peerDataEnd.isCompleted) peerDataEnd.complete();
          case _mediaStartFrame:
            unawaited(enqueue(_MediaStartEvent(
              (frame.data['sha'] as String?) ?? '',
              (frame.data['bytes'] as num?)?.toInt() ?? 0,
              (frame.data['chunks'] as num?)?.toInt() ?? 0,
            )));
          case _mediaEndFrame:
            unawaited(enqueue(const _MediaEndEvent()));
          case _summaryFrame:
            final event = _SummaryEvent(Map<String, Object?>.from(frame.data));
            unawaited(enqueue(event).then((_) {
              if (!summaryReady.isCompleted) summaryReady.complete(event.data);
            }, onError: (Object error, StackTrace stackTrace) {
              if (!summaryReady.isCompleted) {
                summaryReady.completeError(error, stackTrace);
              }
            }));
          case _byeFrame:
            unawaited(enqueue(const _ByeEvent()).then((_) {
              if (!byeReceived.isCompleted) byeReceived.complete();
            }, onError: (Object error, StackTrace stackTrace) {
              if (!byeReceived.isCompleted) {
                byeReceived.completeError(error, stackTrace);
              }
            }));
          default:
            if (frame.isBlob && frame.bytes != null) {
              // Blob frames on the channel are media file chunks; rows
              // travel inside control frames only.
              unawaited(enqueue(_MediaChunkEvent(frame.bytes!)));
            }
        }
      },
      onError: (Object error) {
        if (!metaReady.isCompleted) metaReady.completeError(error);
        if (!peerDataEnd.isCompleted) peerDataEnd.completeError(error);
        if (!summaryReady.isCompleted) summaryReady.completeError(error);
      },
      onDone: () {
        // The peer (or the channel) went away: fail every pending wait so
        // this side reports immediately instead of spinning forever.
        const gone = SocketException('Peer closed the connection.');
        if (!metaReady.isCompleted) metaReady.completeError(gone);
        if (!peerDataEnd.isCompleted) peerDataEnd.completeError(gone);
        if (!summaryReady.isCompleted) summaryReady.completeError(gone);
        if (!byeReceived.isCompleted) byeReceived.completeError(gone);
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
      final peerMeta = await metaReady.future;
      final peerId = (peerMeta['deviceId'] as String?) ?? '';
      result.peerDeviceId = peerId;
      _step = 'meta';

      // 2. Build and stream our outbound payload (scope = our own prefs).
      _step = 'payload';
      final payload = await repo.buildOutboundPayload(peerId, preferences);
      result.sentInvoices = payload.invoices.length;
      result.sentProfiles = payload.profiles.length;
      await _sendBatches('invoices', payload.invoices);
      await _sendBatches('profiles', payload.profiles);
      await channel.sendControl(_dataEndFrame, seq: _nextSeq);

      // 3. Wait for the peer's data; the chain merges it in order.
      _step = 'receive';
      await peerDataEnd.future;
      await processing;
      // Merged rows bypass insertInvoice, so the derived shops table must
      // be rebuilt before anything reads it.
      await database.refreshDerivedShops();

      _step = 'summary';
      // 4. Exchange summaries (the peer learns which media we lack).
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
      final peerSummary = await summaryReady.future;
      final peerNeeds = (peerSummary['mediaNeeded'] as List? ?? const [])
          .whereType<String>()
          .toList();

      // 5. Media phase: deliver the files the peer asked for; the chunks
      // the peer sends to us are drained by the same chain.
      _step = 'media';
      if (preferences.syncImages) {
        final deliver = <String>[];
        for (final sha in peerNeeds) {
          if (await database.mediaFilePath(sha) != null) deliver.add(sha);
        }
        // ignore: avoid_print
        print('DEBUG media: peerNeeds=$peerNeeds deliver=$deliver');
        final sendDone = _sendMediaFiles(deliver);
        await processing;
        await sendDone;
      }

      _step = 'cursors';
      if (peerId.isNotEmpty) {
        await repo.advanceCursors(
          peerId,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      await channel.sendControl(_byeFrame, seq: _nextSeq);
      // The peer sends its own bye after its media phase, so waiting for
      // it guarantees every inbound media frame has been stored.
      await byeReceived.future;
      await processing;
      result.success = true;
      return result;
    } catch (error) {
      result.error = '$_step: $error';
      return result;
    } finally {
      await subscription.cancel();
    }
  }

  // ---- outbound helpers --------------------------------------------------

  Future<void> _sendBatches(String kind, List<Map<String, Object?>> rows) async {
    for (var i = 0; i < rows.length; i += batchSize) {
      await channel.sendControl(
        _rowsFrame,
        seq: _nextSeq,
        data: {
          'kind': kind,
          'rows': rows.sublist(
            i,
            i + batchSize > rows.length ? rows.length : i + batchSize,
          ),
        },
      );
    }
  }

  Future<void> _sendMediaFiles(List<String> hashes) async {
    for (final sha in hashes) {
      final path = await database.mediaFilePath(sha);
      if (path == null) continue;
      final bytes = await File(path).readAsBytes();
      final chunkCount =
          bytes.isEmpty ? 1 : (bytes.length / mediaChunkSize).ceil();
      await channel.sendControl(
        _mediaStartFrame,
        seq: _nextSeq,
        data: {'sha': sha, 'bytes': bytes.length, 'chunks': chunkCount},
      );
      if (bytes.isEmpty) {
        await channel.sendBlob(seq: _nextSeq, bytes: Uint8List(0));
      }
      for (var i = 0; i < chunkCount; i++) {
        final start = i * mediaChunkSize;
        final end = start + mediaChunkSize > bytes.length
            ? bytes.length
            : start + mediaChunkSize;
        await channel.sendBlob(
          seq: _nextSeq,
          bytes: Uint8List.sublistView(bytes, start, end),
        );
      }
      await channel.sendControl(
        _mediaEndFrame,
        seq: _nextSeq,
        data: {'sha': sha},
      );
    }
  }

  // ---- inbound processing --------------------------------------------------

  Future<void> _drainEvent(
    Queue<_InboundEvent> events,
    SyncRepository repo,
    SyncSessionResult result,
  ) async {
    while (events.isNotEmpty) {
      final event = events.removeFirst();
      switch (event) {
        case _MetaEvent():
          break;
        case _SummaryEvent():
          break;
        case _DataEndEvent():
        case _ByeEvent():
          break;
        case _RowsEvent(:final kind, :final rows):
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
        case _MediaStartEvent(:final sha, :final chunks):
          _media.start(sha, chunks);
        case _MediaChunkEvent(:final bytes):
          _media.addChunk(bytes);
        case _MediaEndEvent():
          final stored = await _media.finish(database);
          // ignore: avoid_print
          print('DEBUG recv mend stored=$stored');
          result.mediaTransferred += stored;
      }
    }
  }
}
