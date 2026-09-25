import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/sync/protocol/sync_frame.dart';
import 'package:fatoora_lens/sync/security/sync_secure_channel.dart';
import 'package:fatoora_lens/sync/transport/sync_transport.dart';
import 'package:fatoora_lens/sync/transport/ws_transport.dart';

Future<(SyncSecureChannel, SyncSecureChannel)> _establishOverPair(
  (SyncTransport, SyncTransport) pair, {
  String sessionId = 'sess-1',
}) async {
  final (hostInner, guestInner) = pair;
  final hostKeys = await X25519().newKeyPair();
  final hostPublic = await hostKeys.extractPublicKey();

  final hostFuture = SyncSecureChannel.establish(
    transport: hostInner,
    side: SyncSide.host,
    sessionId: sessionId,
    hostStaticKeyPair: hostKeys,
  );
  final guestFuture = SyncSecureChannel.establish(
    transport: guestInner,
    side: SyncSide.guest,
    sessionId: sessionId,
    hostPublicKey: Uint8List.fromList(hostPublic.bytes),
  );
  return (await hostFuture, await guestFuture);
}

void main() {
  group('SyncSecureChannel over loopback', () {
    test('handshake succeeds and frames decrypt in both directions',
        () async {
      final pair = LoopbackTransport.pair();
      final (host, guest) = await _establishOverPair(pair);

      final hostReceived = Completer<SyncFrame>();
      final hostSub = host.frames.listen(hostReceived.complete);
      final guestReceived = Completer<SyncFrame>();
      final guestSub = guest.frames.listen(guestReceived.complete);

      await guest.sendControl(
        SyncFrame.kTypeHello,
        seq: 1,
        data: {'role': 'guest'},
      );
      final atHost = await hostReceived.future.timeout(
        const Duration(seconds: 5),
      );
      expect(atHost.type, SyncFrame.kTypeHello);
      expect(atHost.data['role'], 'guest');
      expect(atHost.sessionId, 'sess-1');

      await host.sendBlob(
        seq: 2,
        bytes: Uint8List.fromList(utf8.encode('binary payload')),
      );
      final atGuest = await guestReceived.future.timeout(
        const Duration(seconds: 5),
      );
      expect(atGuest.isBlob, isTrue);
      expect(utf8.decode(atGuest.bytes!), 'binary payload');

      await hostSub.cancel();
      await guestSub.cancel();
      await host.close();
      await guest.close();
    });

    test('many frames keep their order and counters stay in sync', () async {
      final pair = LoopbackTransport.pair();
      final (host, guest) = await _establishOverPair(pair);

      final received = <String>[];
      final done = Completer<void>();
      final sub = host.frames.listen((frame) {
        received.add('${frame.type}:${frame.seq}');
        if (frame.seq == 30) {
          done.complete();
        }
      });
      for (var i = 1; i <= 30; i++) {
        await guest.sendControl('tick', seq: i);
      }
      await done.future.timeout(const Duration(seconds: 10));
      expect(received.length, 30);
      expect(received.last, 'tick:30');
      await sub.cancel();
      await host.close();
      await guest.close();
    });

    test('a tampered frame fails authentication and surfaces an error',
        () async {
      final (hostInner, guestInner) = LoopbackTransport.pair();
      final (host, guest) = await _establishOverPair((hostInner, guestInner));

      final guestError = Completer<Object>();
      final sub = guest.frames.listen(
        (_) {},
        onError: guestError.complete,
      );

      // Raw garbage injected into the guest's inbound path must be
      // rejected by the authentication tag.
      guestInner.ingest(
        SyncFrame.blob(seq: 99, bytes: Uint8List.fromList(List.filled(48, 7)))
            .encodeBlob(),
      );

      final error = await guestError.future.timeout(const Duration(seconds: 5));
      expect(error, isA<SyncChannelException>());

      await sub.cancel();
      await host.close();
      await guest.close();
    });

    test('a replayed frame is rejected', () async {
      final (hostInner, guestInner) = LoopbackTransport.pair();
      final (host, guest) = await _establishOverPair((hostInner, guestInner));

      // Capture one valid encrypted frame from the wire.
      List<int>? captured;
      final probe = hostInner.frames.listen((frame) {
        if (frame.isBlob && captured == null) {
          captured = frame.bytes;
        }
      });

      await guest.sendControl(SyncFrame.kTypePing, seq: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(captured, isNotNull);
      await probe.cancel();

      final hostError = Completer<Object>();
      final sub = host.frames.listen((_) {}, onError: hostError.complete);

      // Replay the exact same bytes into the host's inbound path: the
      // receive counter has moved on, so authentication must fail.
      hostInner.ingest(
        SyncFrame.blob(seq: 2, bytes: Uint8List.fromList(captured!))
            .encodeBlob(),
      );
      final error = await hostError.future.timeout(const Duration(seconds: 5));
      expect(error, isA<SyncChannelException>());

      await sub.cancel();
      await host.close();
      await guest.close();
    });
  });

  group('SyncSecureChannel over a real WebSocket', () {
    late WsServerTransport server;
    late int port;

    setUp(() async {
      server = WsServerTransport(port: 0);
      port = await server.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('end-to-end encrypted handshake and exchange', () async {
      final client = WsClientTransport(
        uri: Uri.parse('ws://127.0.0.1:$port/sync'),
      );
      await client.start();

      final hostKeys = await X25519().newKeyPair();
      final hostPublic = await hostKeys.extractPublicKey();

      final hostFuture = SyncSecureChannel.establish(
        transport: server,
        side: SyncSide.host,
        sessionId: 'ws-sess',
        hostStaticKeyPair: hostKeys,
      );
      final guestFuture = SyncSecureChannel.establish(
        transport: client,
        side: SyncSide.guest,
        sessionId: 'ws-sess',
        hostPublicKey: Uint8List.fromList(hostPublic.bytes),
      );
      final channels = await Future.wait([hostFuture, guestFuture]);
      final host = channels[0];
      final guest = channels[1];

      final received = Completer<SyncFrame>();
      final sub = host.frames.listen(received.complete);
      await guest.sendControl(
        SyncFrame.kTypeHello,
        seq: 1,
        data: {'secret': 'encrypted-over-ws'},
      );
      final frame = await received.future.timeout(const Duration(seconds: 5));
      expect(frame.data['secret'], 'encrypted-over-ws');

      await sub.cancel();
      await host.close();
      await guest.close();
      await client.close();
    });
  });
}
