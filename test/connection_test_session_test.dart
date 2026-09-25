import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/sync/protocol/sync_frame.dart';
import 'package:fatoora_lens/sync/testing/connection_test_session.dart';
import 'package:fatoora_lens/sync/transport/sync_transport.dart';
import 'package:fatoora_lens/sync/transport/ws_transport.dart';

void main() {
  group('ConnectionTestSession over loopback', () {
    test('full battery passes with default sizes', () async {
      final report = await runLoopbackSelfTest();

      expect(report.results, hasLength(3));
      expect(report.allPassed, isTrue);
      expect(report.results[0].name, 'ping');
      expect(report.results[0].metrics['avg'], isNotNull);
      expect(report.results[1].name, 'transfer-small');
      expect(report.results[1].passed, isTrue);
      expect(report.results[2].name, 'transfer-large');
      expect(report.results[2].passed, isTrue);
    });

    test('reports a hash mismatch when the echo corrupts a chunk', () async {
      final (initiatorTransport, echoTransport) = LoopbackTransport.pair();
      // An echoing peer that flips one byte of every chunk it returns.
      final corruptingEcho = _CorruptingEcho(transport: echoTransport);
      final initiator = ConnectionTestSession(
        transport: initiatorTransport,
        role: TestRole.initiator,
        largeTransferBytes: 64 * 1024,
      );
      try {
        unawaited(corruptingEcho.run());
        final report = await initiator.run();

        final transfers =
            report.results.where((result) => result.name.startsWith('transfer'));
        expect(transfers, isNotEmpty);
        expect(
          transfers.every((result) => !result.passed),
          isTrue,
          reason: 'Corrupted echoes must fail the SHA-256 verification.',
        );
      } finally {
        await initiatorTransport.close();
      }
    });
  });

  group('ConnectionTestSession over a real WebSocket', () {
    late WsServerTransport server;
    late int port;

    setUp(() async {
      server = WsServerTransport(port: 0);
      port = await server.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('full battery passes between a client and the local server',
        () async {
      final client = WsClientTransport(
        uri: Uri.parse('ws://127.0.0.1:$port/sync'),
      );
      await client.start();

      final echo = ConnectionTestSession(
        transport: server,
        role: TestRole.echo,
        largeTransferBytes: 256 * 1024,
        chunkSize: 32 * 1024,
      );
      final initiator = ConnectionTestSession(
        transport: client,
        role: TestRole.initiator,
        largeTransferBytes: 256 * 1024,
        chunkSize: 32 * 1024,
      );

      final echoDone = echo.run();
      final report = await initiator.run();
      final echoReport = await echoDone;

      expect(report.allPassed, isTrue);
      expect(report.results, hasLength(3));
      expect(echoReport.results, isEmpty, reason: 'Echo side serves silently.');
      await client.close();
    });

    test('the server rejects a second concurrent client with busy', () async {
      final first = WsClientTransport(
        uri: Uri.parse('ws://127.0.0.1:$port/sync'),
      );
      await first.start();

      final second = WsClientTransport(
        uri: Uri.parse('ws://127.0.0.1:$port/sync'),
      );
      await second.start();

      final busy = await second.frames
          .firstWhere((frame) => frame.type == SyncFrame.kTypeBusy)
          .timeout(const Duration(seconds: 5));
      expect(busy.type, SyncFrame.kTypeBusy);
      await second.close();
      await first.close();
    });

    test('connecting to a closed port fails instead of hanging', () async {
      final client = WsClientTransport(
        uri: Uri.parse('ws://127.0.0.1:1/sync'),
        connectTimeout: const Duration(seconds: 2),
      );
      await expectLater(client.start(), throwsA(isA<Object>()));
    });
  });
}

/// Echo peer that deliberately corrupts returned chunks, used to prove the
/// SHA-256 verification catches transmission errors.
class _CorruptingEcho {
  _CorruptingEcho({required this.transport});

  final SyncTransport transport;

  Future<void> run() async {
    var chunks = 0;
    await for (final frame in transport.frames) {
      switch (frame.type) {
        case SyncFrame.kTypeHello:
          await transport.sendControl(
            SyncFrame.kTypeHello,
            seq: frame.seq,
            sessionId: frame.sessionId,
            data: {'role': 'echo', 'proto': 1},
          );
        case SyncFrame.kTypePing:
          await transport.sendControl(
            SyncFrame.kTypePong,
            seq: frame.seq,
            sessionId: frame.sessionId,
            data: frame.data,
          );
        case SyncFrame.kTypeBlob:
          final bytes = Uint8List.fromList(frame.bytes ?? <int>[]);
          if (bytes.isNotEmpty) {
            bytes[0] ^= 0xFF;
          }
          await transport.sendBlob(seq: ++chunks, bytes: bytes);
        case SyncFrame.kTypeBye:
          return;
      }
    }
  }
}
