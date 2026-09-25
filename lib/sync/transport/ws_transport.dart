import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/sync_frame.dart';
import 'sync_transport.dart';

/// Default TCP port for the on-device sync server.
const int kDefaultSyncPort = 8765;

/// Common delivery glue for both ends of a WebSocket connection.
mixin _WsDelivery on BaseTransport {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  void attachChannel(WebSocketChannel channel) {
    _channel = channel;
    setState(TransportState.connected);
    _subscription = channel.stream.listen(
      ingest,
      onError: (dynamic error) => setState(TransportState.error),
      onDone: () {
        if (!isClosed) close();
      },
      cancelOnError: true,
    );
  }

  void _write(Object message) {
    final channel = _channel;
    if (channel == null || isClosed) {
      throw StateError('WebSocket transport is not connected.');
    }
    channel.sink.add(message);
  }

  @override
  Future<void> onClose() async {
    await _subscription?.cancel();
    final channel = _channel;
    _channel = null;
    try {
      await channel?.sink.close();
    } catch (_) {
      // The socket may already be gone; closing is best-effort.
    }
  }
}

/// Host side: embeds an HTTP server with a WebSocket endpoint at /sync and
/// adopts the first device that connects. Additional connections are told
/// the session is busy and dropped.
class WsServerTransport extends BaseTransport with _WsDelivery {
  WsServerTransport({this.port = kDefaultSyncPort, this.address});

  /// Network address to bind; defaults to any IPv4 interface.
  final InternetAddress? address;
  final int port;

  HttpServer? _server;
  bool _clientAdopted = false;

  /// Binds the server. Resolves with the actual port (useful when the
  /// caller passes 0 for an ephemeral port, as the tests do).
  Future<int> start() async {
    final server = await shelf_io.serve(_router(), address ?? InternetAddress.anyIPv4, port);
    _server = server;
    setState(TransportState.listening);
    return server.port;
  }

  shelf.Handler _router() => webSocketHandler(
      (WebSocketChannel channel, String? subprotocol) {
        if (!_clientAdopted) {
          _clientAdopted = true;
          attachChannel(channel);
          return;
        }
        // Only one client per session; anything else is told to back off.
        channel.sink.add(
          SyncFrame.control(type: SyncFrame.kTypeBusy, sessionId: '', seq: 0)
              .encodeControl(),
        );
        channel.sink.close();
      },
    );

  @override
  Future<void> sendControl(
    String type, {
    required int seq,
    String? sessionId,
    Map<String, Object?>? data,
  }) async {
    _write(
      SyncFrame.control(
        type: type,
        sessionId: sessionId ?? '',
        seq: seq,
        data: data,
      ).encodeControl(),
    );
  }

  @override
  Future<void> sendBlob({required int seq, required Uint8List bytes}) async {
    _write(SyncFrame.blob(seq: seq, bytes: bytes).encodeBlob());
  }

  @override
  Future<void> close() async {
    await super.close();
    final server = _server;
    _server = null;
    _clientAdopted = false;
    await server?.close(force: true);
  }

  @override
  Future<void> onClose() async {}
}

/// Join side: connects to a host's `ws://<ip>:<port>/sync` endpoint.
class WsClientTransport extends BaseTransport with _WsDelivery {
  WsClientTransport({required this.uri, this.connectTimeout = const Duration(seconds: 3)});

  final Uri uri;
  final Duration connectTimeout;

  /// Connects to the host; throws [TimeoutException] when the host is
  /// unreachable within [connectTimeout] — the trigger for the cloud
  /// fallback path later.
  Future<void> start() async {
    setState(TransportState.connecting);
    final channel = WebSocketChannel.connect(uri);
    await channel.ready.timeout(connectTimeout, onTimeout: () {
      unawaited(channel.sink.close());
      throw TimeoutException(
        'Sync host did not answer in time.',
        connectTimeout,
      );
    });
    attachChannel(channel);
  }

  @override
  Future<void> sendControl(
    String type, {
    required int seq,
    String? sessionId,
    Map<String, Object?>? data,
  }) async {
    _write(
      SyncFrame.control(
        type: type,
        sessionId: sessionId ?? '',
        seq: seq,
        data: data,
      ).encodeControl(),
    );
  }

  @override
  Future<void> sendBlob({required int seq, required Uint8List bytes}) async {
    _write(SyncFrame.blob(seq: seq, bytes: bytes).encodeBlob());
  }

  @override
  Future<void> onClose() async {}
}

/// Returns the first non-loopback IPv4 address of this device, which the
/// sync screens show so the peer can connect. Wi-Fi and ethernet
/// interfaces are preferred over mobile data (whose address is
/// unreachable from the local network). Null when offline.
Future<String?> localIpv4Address() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  String? mobileFallback;
  for (final interface in interfaces) {
    final isWifi = interface.name.startsWith('wlan') ||
        interface.name.startsWith('eth') ||
        interface.name.startsWith('en');
    for (final addr in interface.addresses) {
      final raw = addr.address;
      if (raw.startsWith('169.254.') || raw.startsWith('::ffff:')) continue;
      if (isWifi) return raw;
      mobileFallback ??= raw;
    }
  }
  return mobileFallback;
}
