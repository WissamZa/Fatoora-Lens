import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../sync/pairing.dart';
import '../sync/security/sync_secure_channel.dart';
import '../sync/sync_preferences.dart';
import '../sync/sync_session.dart';
import '../sync/transport/ws_transport.dart';
import 'scanner_screen.dart';

/// Device-to-device sync: pick what to sync, then host a session on the
/// local network or join a host by scanning its pairing QR. The session
/// runs end-to-end encrypted (the QR carries the host's X25519 public
/// key) over the local WebSocket transport.
class SyncScreen extends StatefulWidget {
  const SyncScreen({required this.database, super.key});

  final DatabaseService database;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

enum _Phase { config, hosting, syncing, done }

class _SyncScreenState extends State<SyncScreen> {
  SyncPreferences _preferences = const SyncPreferences();
  bool _prefsLoaded = false;

  _Phase _phase = _Phase.config;
  String? _statusLine;
  SyncSessionResult? _result;
  String? _error;

  WsServerTransport? _server;
  PairingInfo? _pairing;

  @override
  void initState() {
    super.initState();
    SyncPreferences.load(widget.database.getSetting).then((prefs) {
      if (!mounted) return;
      setState(() {
        _preferences = prefs;
        _prefsLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _teardown() async {
    final server = _server;
    _server = null;
    await server?.close();
  }

  Future<void> _savePrefs(SyncPreferences prefs) async {
    setState(() => _preferences = prefs);
    await prefs.save(widget.database.setSetting);
  }

  void _showResult(SyncSessionResult result) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _result = result;
      _statusLine = result.success
          ? tr(context, 'syncDone')
          : '${tr(context, 'error')}: ${result.error}';
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _error = message;
    });
  }

  Future<void> _host() async {
    setState(() {
      _phase = _Phase.hosting;
      _result = null;
      _error = null;
      _statusLine = tr(context, 'syncStarting');
    });
    final server = WsServerTransport();
    final noNetworkText = AppL10n.isEnglish(context)
        ? 'No local network found.'
        : 'لا توجد شبكة محلية للاتصال.';
    try {
      final port = await server.start();
      final ip = await localIpv4Address();
      if (!mounted) return;
      if (ip == null) {
        await server.close();
        _fail(noNetworkText);
        return;
      }
      setState(() {
        _server = server;
        _statusLine = tr(context, 'syncWaitingPeer');
      });

      final hostKeys = await X25519().newKeyPair();
      final hostPublic = await hostKeys.extractPublicKey();
      final pairing = PairingInfo(
        deviceId: widget.database.deviceId ?? '',
        publicKeyB64: base64Encode(hostPublic.bytes),
        ip: ip,
        port: port,
      );
      if (!mounted) return;
      setState(() => _pairing = pairing);

      // Establish directly: the channel subscribes to the server's frames
      // itself and waits for the guest's handshake. Consuming frames with
      // a separate loop here would steal the handshake frame and both
      // sides would time out (seen in real two-device testing).
      final channel = await SyncSecureChannel.establish(
        transport: server,
        side: SyncSide.host,
        sessionId: 'sync-${DateTime.now().millisecondsSinceEpoch}',
        hostStaticKeyPair: hostKeys,
        // The host waits as long as the user keeps this screen open.
        timeout: const Duration(minutes: 30),
      );
      if (!mounted) {
        await channel.close();
        return;
      }
      setState(() {
        _phase = _Phase.syncing;
        _statusLine = tr(context, 'syncRunning');
      });
      final engine = SyncSessionEngine(
        channel: channel,
        database: widget.database,
        preferences: _preferences,
      );
      final result = await engine.run();
      await channel.close();
      _showResult(result);
      await _teardown();
    } catch (error) {
      _fail('$error');
      await _teardown();
    }
  }

  Future<void> _joinFromQr() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (!mounted || payload == null || payload.trim().isEmpty) return;
    final PairingInfo pairing;
    try {
      pairing = PairingInfo.decode(payload.trim());
    } on FormatException {
      return _fail(tr(context, 'syncBadQr'));
    }
    await _join(pairing);
  }

  Future<void> _join(PairingInfo pairing) async {
    setState(() {
      _phase = _Phase.syncing;
      _result = null;
      _error = null;
      _statusLine = tr(context, 'connecting');
    });
    final client = WsClientTransport(
      uri: Uri.parse('ws://${pairing.ip}:${pairing.port}/sync'),
    );
    try {
      await client.start();
      final channel = await SyncSecureChannel.establish(
        transport: client,
        side: SyncSide.guest,
        sessionId: 'sync-${DateTime.now().millisecondsSinceEpoch}',
        hostPublicKey: pairing.publicKeyBytes,
      );
      if (!mounted) {
        await channel.close();
        return;
      }
      setState(() {
        _statusLine = tr(context, 'syncRunning');
      });
      final engine = SyncSessionEngine(
        channel: channel,
        database: widget.database,
        preferences: _preferences,
      );
      final result = await engine.run();
      await channel.close();
      _showResult(result);
    } on TimeoutException {
      if (!mounted) return;
      _fail(tr(context, 'hostUnreachable'));
    } catch (error) {
      _fail('$error');
    } finally {
      await client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'syncTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
        children: [
          if (_phase == _Phase.config || _phase == _Phase.done) ...[
            _PrefsCard(
              preferences: _preferences,
              enabled: _prefsLoaded,
              onChanged: _savePrefs,
            ),
            const SizedBox(height: 16),
            if (_result != null) ...[
              _ResultCard(result: _result!),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Card(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          color: theme.colorScheme.error),
                      const SizedBox(width: 10),
                      Expanded(child: SelectableText(_error!)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _host,
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: Text(tr(context, 'syncHost')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _joinFromQr,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(tr(context, 'syncJoin')),
                  ),
                ),
              ],
            ),
          ],
          if (_phase == _Phase.hosting) ...[
            _WaitingCard(status: _statusLine, pairing: _pairing),
          ],
          if (_phase == _Phase.syncing) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(_statusLine ?? ''),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PrefsCard extends StatelessWidget {
  const _PrefsCard({
    required this.preferences,
    required this.enabled,
    required this.onChanged,
  });

  final SyncPreferences preferences;
  final bool enabled;
  final ValueChanged<SyncPreferences> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          children: [
            SwitchListTile(
              value: preferences.syncInvoices,
              onChanged: enabled && !preferences.syncInvoices
                  ? null
                  : (value) => onChanged(
                      preferences.copyWith(syncInvoices: value)),
              title: Text(tr(context, 'syncInvoicesToggle')),
              secondary: const Icon(Icons.receipt_long_outlined),
            ),
            SwitchListTile(
              value: preferences.syncShopProfiles,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(syncShopProfiles: value)),
              title: Text(tr(context, 'syncProfilesToggle')),
              secondary: const Icon(Icons.storefront_outlined),
            ),
            SwitchListTile(
              value: preferences.syncImages,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(syncImages: value)),
              title: Text(tr(context, 'syncImagesToggle')),
              secondary: const Icon(Icons.image_outlined),
            ),
            SwitchListTile(
              value: preferences.allowCloudFallback,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(allowCloudFallback: value)),
              title: Text(tr(context, 'syncCloudToggle')),
              subtitle: Text(tr(context, 'syncCloudHint')),
              secondary: const Icon(Icons.cloud_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({required this.status, required this.pairing});

  final String? status;
  final PairingInfo? pairing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              status ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: pairing?.qrPayload() ?? 'awaiting-pairing',
                size: 200,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              tr(context, 'syncQrHint'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final SyncSessionResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = result.toSummary();
    final entries = summary.entries
        .where((entry) => entry.key != 'success' && entry.key != 'peer')
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.success
                      ? Icons.check_circle_rounded
                      : Icons.error_rounded,
                  color: result.success
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  result.success
                      ? tr(context, 'syncDone')
                      : tr(context, 'syncFailed'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (!result.success && result.error != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                '${tr(context, 'error')}: ${result.error}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 10),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(entry.key, style: theme.textTheme.bodySmall),
                    Text(
                      '${entry.value}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
