import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../protocol/sync_frame.dart';
import '../transport/sync_transport.dart';

/// One entry of a connection test report.
class TestResult {
  const TestResult({
    required this.name,
    required this.passed,
    required this.detail,
    this.metrics = const <String, String>{},
  });

  final String name;
  final bool passed;
  final String detail;
  final Map<String, String> metrics;
}

/// Aggregated outcome of the whole battery.
class TestReport {
  const TestReport({required this.results});

  final List<TestResult> results;

  bool get allPassed => results.every((result) => result.passed);

  int get passedCount => results.where((result) => result.passed).length;
}

/// Roles of the two ends of a diagnostic session.
enum TestRole { initiator, echo }

/// Runs the M1 connectivity battery over any [SyncTransport]:
/// handshake, ping round-trips, and chunked bulk transfers verified by
/// SHA-256. The initiator drives the tests; the echo side only mirrors
/// traffic, exactly as the remote phone would.
class ConnectionTestSession {
  ConnectionTestSession({
    required this.transport,
    required this.role,
    this.sessionId = 'diag',
    this.pingCount = 10,
    this.pingTimeout = const Duration(seconds: 5),
    this.smallTransferBytes = 100 * 1024,
    this.largeTransferBytes = 5 * 1024 * 1024,
    this.chunkSize = 64 * 1024,
    this.transferTimeout = const Duration(seconds: 30),
  })  : assert(pingCount > 0),
        assert(chunkSize > 0 && chunkSize <= SyncFrame.maxBlobBytes);

  final SyncTransport transport;
  final TestRole role;
  final String sessionId;

  final int pingCount;
  final Duration pingTimeout;
  final int smallTransferBytes;
  final int largeTransferBytes;
  final int chunkSize;
  final Duration transferTimeout;

  int _seq = 0;
  int get _nextSeq => ++_seq;

  final _pendingWaits = <_FrameWait>[];

  /// Runs the session. On the echo side this serves until the initiator
  /// sends `bye`; on the initiator side it returns the full report.
  Future<TestReport> run() async {
    final done = Completer<TestReport>();
    final subscription = transport.frames.listen(
      (frame) => _onFrame(frame, done),
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(const SocketException('Transport closed.'));
        }
      },
    );
    try {
      if (role == TestRole.initiator) {
        await _send(SyncFrame.kTypeHello, data: {'role': 'initiator', 'proto': 1});
        final hello = await _waitFor(
          (frame) => frame.type == SyncFrame.kTypeHello,
          timeout: pingTimeout,
        );
        if ((hello.data['role'] ?? '') != 'echo') {
          throw StateError('Peer did not identify itself as echo.');
        }
        final results = [
          await _runPingTest(),
          await _runTransferTest('small', smallTransferBytes),
          await _runTransferTest('large', largeTransferBytes),
        ];
        await _send(SyncFrame.kTypeBye);
        if (!done.isCompleted) done.complete(TestReport(results: results));
      } else {
        await _send(SyncFrame.kTypeHello, data: {'role': 'echo', 'proto': 1});
      }
      return await done.future;
    } finally {
      await subscription.cancel();
      for (final wait in _pendingWaits) {
        wait.abort();
      }
      _pendingWaits.clear();
    }
  }

  // ---- shared plumbing -------------------------------------------------

  Future<SyncFrame> _waitFor(
    bool Function(SyncFrame) predicate, {
    required Duration timeout,
  }) {
    final wait = _FrameWait(predicate, timeout);
    _pendingWaits.add(wait);
    return wait.future;
  }

  void _onFrame(SyncFrame frame, Completer<TestReport> done) {
    for (final wait in List<_FrameWait>.of(_pendingWaits)) {
      if (!wait.completer.isCompleted && wait.predicate(frame)) {
        wait.complete(frame);
        _pendingWaits.remove(wait);
        return;
      }
    }
    switch (role) {
      case TestRole.initiator:
        _onInitiatorFrame(frame, done);
      case TestRole.echo:
        _onEchoFrame(frame, done);
    }
  }

  Future<void> _send(String type, {Map<String, Object?>? data}) =>
      transport.sendControl(
        type,
        seq: _nextSeq,
        sessionId: sessionId,
        data: data,
      );

  // ---- initiator side --------------------------------------------------

  Future<TestResult> _runPingTest() async {
    final rtts = <int>[];
    try {
      for (var i = 0; i < pingCount; i++) {
        final sentAt = DateTime.now().millisecondsSinceEpoch;
        await _send(SyncFrame.kTypePing, data: {'ts': sentAt});
        final pong = await _waitFor(
          (frame) => frame.type == SyncFrame.kTypePong,
          timeout: pingTimeout,
        );
        final echoTs = (pong.data['ts'] as num?)?.toInt() ?? sentAt;
        rtts.add(max(0, DateTime.now().millisecondsSinceEpoch - echoTs));
      }
    } on TimeoutException {
      return const TestResult(
        name: 'ping',
        passed: false,
        detail: 'Peer stopped answering pings.',
      );
    }
    rtts.sort();
    final avg = rtts.fold<int>(0, (sum, value) => sum + value) ~/ rtts.length;
    return TestResult(
      name: 'ping',
      passed: true,
      detail: 'ok',
      metrics: {
        'avg': '$avg ms',
        'min': '${rtts.first} ms',
        'max': '${rtts.last} ms',
      },
    );
  }

  Future<TestResult> _runTransferTest(String name, int totalBytes) async {
    // Deterministic pseudo-random payload (both tails included).
    final sent = Uint8List(totalBytes);
    final value = ByteData.view(sent.buffer);
    final rng = Random(42);
    for (var i = 0; i + 4 <= totalBytes; i += 4) {
      value.setUint32(i, rng.nextInt(1 << 32), Endian.little);
    }
    final expectedHash = crypto.sha256.convert(sent).toString();

    final chunkCount = (totalBytes / chunkSize).ceil();

    // Subscribe BEFORE sending anything: broadcast streams drop frames
    // delivered while nobody listens, and on the loopback carrier the echo
    // can come back within the same microtask cascade as the send.
    final echoedFuture = _collectEchoedChunks(chunkCount);

    final watch = Stopwatch()..start();
    try {
      await _send(SyncFrame.kTypeTransferStart, data: {
        'id': name,
        'bytes': totalBytes,
        'chunks': chunkCount,
        'sha256': expectedHash,
      });
      for (var i = 0; i < chunkCount; i++) {
        final start = i * chunkSize;
        final end = min(start + chunkSize, totalBytes);
        await transport.sendBlob(
          seq: _nextSeq,
          bytes: Uint8List.sublistView(sent, start, end),
        );
      }
      final echoed = await echoedFuture;
      watch.stop();

      final received = Uint8List.fromList(
        echoed.expand((chunk) => chunk).toList(),
      );
      final receivedHash = crypto.sha256.convert(received).toString();
      final seconds = max(watch.elapsedMilliseconds, 1) / 1000;
      final mbps = totalBytes / (1024 * 1024) / seconds;
      final hashesMatch = receivedHash == expectedHash;
      return TestResult(
        name: 'transfer-$name',
        passed: hashesMatch,
        detail: hashesMatch
            ? 'ok'
            : 'SHA-256 mismatch: sent $expectedHash, received $receivedHash',
        metrics: {
          'size': '${(totalBytes / 1024).toStringAsFixed(0)} KB',
          'time': '${seconds.toStringAsFixed(2)} s',
          'throughput': '${mbps.toStringAsFixed(2)} MB/s',
          'sha256': hashesMatch ? 'match' : 'mismatch',
        },
      );
    } on TimeoutException {
      return TestResult(
        name: 'transfer-$name',
        passed: false,
        detail: 'Transfer timed out after ${transferTimeout.inSeconds}s.',
      );
    }
  }

  /// Collects the echoed chunks in arrival order (all carriers are
  /// ordered and reliable, so arrival order equals send order).
  Future<List<Uint8List>> _collectEchoedChunks(int chunkCount) {
    final chunks = <Uint8List>[];
    final completer = Completer<List<Uint8List>>();
    late final StreamSubscription<SyncFrame> sub;
    sub = transport.frames.listen(
      (frame) {
        if (completer.isCompleted) return;
        if (frame.type == SyncFrame.kTypeBye ||
            frame.type == SyncFrame.kTypeError) {
          completer.completeError(StateError('Peer aborted the transfer.'));
          return;
        }
        if (!frame.isBlob || frame.bytes == null) return;
        chunks.add(frame.bytes!);
        if (chunks.length >= chunkCount) {
          completer.complete(chunks);
          sub.cancel();
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    return completer.future.timeout(transferTimeout);
  }

  void _onInitiatorFrame(SyncFrame frame, Completer<TestReport> done) {
    // Stray control frames (e.g. busy) end the session with a failure.
    if (frame.type == SyncFrame.kTypeBusy && !done.isCompleted) {
      done.complete(const TestReport(results: [
        TestResult(
          name: 'handshake',
          passed: false,
          detail: 'Peer rejected the connection: another session is active.',
        ),
      ]));
    }
  }

  // ---- echo side ---------------------------------------------------------

  int _echoChunksRemaining = 0;

  void _onEchoFrame(SyncFrame frame, Completer<TestReport> done) {
    switch (frame.type) {
      case SyncFrame.kTypePing:
        unawaited(_send(SyncFrame.kTypePong, data: frame.data));
      case SyncFrame.kTypeTransferStart:
        _echoChunksRemaining = ((frame.data['chunks'] as num?) ?? 0).toInt();
      case SyncFrame.kTypeBlob:
        if (_echoChunksRemaining <= 0) return;
        _echoChunksRemaining--;
        unawaited(
          transport.sendBlob(seq: _nextSeq, bytes: frame.bytes ?? Uint8List(0)),
        );
      case SyncFrame.kTypeBye:
        if (!done.isCompleted) {
          done.complete(const TestReport(results: []));
        }
    }
  }
}

/// A one-shot wait for the next frame matching [predicate].
class _FrameWait {
  _FrameWait(this.predicate, Duration timeout)
      : completer = Completer<SyncFrame>() {
    _timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Timed out waiting for an expected frame.', timeout),
        );
      }
    });
  }

  final bool Function(SyncFrame) predicate;
  final Completer<SyncFrame> completer;
  late final Timer _timer;

  Future<SyncFrame> get future {
    final wrapped = Completer<SyncFrame>();
    unawaited(completer.future.then(
      (frame) {
        _timer.cancel();
        wrapped.complete(frame);
      },
      onError: (Object error, StackTrace stackTrace) {
        _timer.cancel();
        wrapped.completeError(error, stackTrace);
      },
    ));
    return wrapped.future;
  }

  void complete(SyncFrame frame) => completer.complete(frame);

  void abort() => _timer.cancel();
}

/// Convenience for the self-diagnostic and tests: runs the whole battery
/// over a loopback pair inside a single process.
Future<TestReport> runLoopbackSelfTest({int largeTransferBytes = 512 * 1024}) async {
  final (initiatorTransport, echoTransport) = LoopbackTransport.pair();
  final initiator = ConnectionTestSession(
    transport: initiatorTransport,
    role: TestRole.initiator,
    largeTransferBytes: largeTransferBytes,
  );
  final echo = ConnectionTestSession(transport: echoTransport, role: TestRole.echo);
  try {
    final results = await Future.wait([initiator.run(), echo.run()]);
    return results.first;
  } finally {
    await initiatorTransport.close();
  }
}
