import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/sync_peer.dart';
import '../sync/pairing.dart';
import '../sync/security/sync_secure_channel.dart';
import '../sync/sync_identity.dart';
import '../sync/sync_preferences.dart';
import '../sync/sync_session.dart';
import '../sync/transport/ws_transport.dart';
import 'scanner_screen.dart';

/// Device-to-device sync: pick what to sync, then host a session on the
/// local network or join a host by scanning its pairing QR. The session
/// runs end-to-end encrypted (the QR carries the host's X25519 public
/// key) over the local WebSocket transport. Successfully paired devices
/// are saved and can be re-synced with one tap, no QR needed.
class SyncScreen extends StatefulWidget {
  const SyncScreen({required this.database, super.key});

  final DatabaseService database;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

enum _Phase { config, hosting, syncing, done }

class _SyncScreenState extends State<SyncScreen> {
  SyncPreferences _preferences = const SyncPreferences();
  List<SyncPeer> _peers = const [];
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
    _reload();
  }

  Future<void> _reload() async {
    final prefs = await SyncPreferences.load(widget.database.getSetting);
    final peers = await widget.database.getSyncPeers();
    if (!mounted) return;
    setState(() {
      _preferences = prefs;
      _prefsLoaded = true;
      _peers = peers;
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

  void _reset() {
    setState(() {
      _result = null;
      _error = null;
      _statusLine = null;
    });
  }

  void _showResult(SyncSessionResult result) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _result = result;
      _statusLine = null;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _error = message;
    });
  }

  /// Runs the encrypted session on an established channel and refreshes
  /// the saved peers afterwards.
  Future<void> _runSession(SyncSecureChannel channel) async {
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
    await _reload();
    _showResult(result);
  }

  /// Hosts a brand-new pairing: QR on screen, persistent host key.
  Future<void> _host() async {
    _reset();
    final noNetworkText = AppL10n.isEnglish(context)
        ? 'No local network found.'
        : 'لا توجد شبكة محلية للاتصال.';
    setState(() {
      _phase = _Phase.hosting;
      _statusLine = tr(context, 'syncStarting');
    });
    final server = WsServerTransport();
    try {
      final port = await server.start();
      final ip = await localIpv4Address();
      if (!mounted) return;
      if (ip == null) {
        await server.close();
        _fail(noNetworkText);
        return;
      }
      final hostKeys = await SyncIdentity.loadHostKeyPair(widget.database);
      final hostPublic = await hostKeys.extractPublicKey();
      final pairing = PairingInfo(
        deviceId: widget.database.deviceId ?? '',
        publicKeyB64: base64Encode(hostPublic.bytes),
        ip: ip,
        port: port,
      );
      if (!mounted) return;
      setState(() {
        _server = server;
        _pairing = pairing;
        _statusLine = tr(context, 'syncWaitingPeer');
      });

      // The channel subscribes itself and waits for the guest's handshake
      // for as long as this screen stays open.
      final channel = await SyncSecureChannel.establish(
        transport: server,
        side: SyncSide.host,
        sessionId: 'sync-${DateTime.now().millisecondsSinceEpoch}',
        hostStaticKeyPair: hostKeys,
        timeout: const Duration(minutes: 30),
      );
      await _runSession(channel);
      await _teardown();
    } catch (error) {
      _fail('$error');
      await _teardown();
    }
  }

  /// Hosts a re-sync for a saved peer (the peer joins without a QR).
  Future<void> _hostForSavedPeer(SyncPeer peer) async {
    _reset();
    setState(() {
      _phase = _Phase.hosting;
      _statusLine = tr(context, 'syncWaitingPeer');
    });
    final server = WsServerTransport();
    try {
      await server.start();
      if (!mounted) return;
      setState(() => _server = server);
      final hostKeys = await SyncIdentity.loadHostKeyPair(widget.database);
      final channel = await SyncSecureChannel.establish(
        transport: server,
        side: SyncSide.host,
        sessionId: 'sync-${DateTime.now().millisecondsSinceEpoch}',
        hostStaticKeyPair: hostKeys,
        timeout: const Duration(minutes: 30),
      );
      final engine = SyncSessionEngine(
        channel: channel,
        database: widget.database,
        preferences: _preferences,
        hostRole: true,
        expectedPeerDeviceId: peer.deviceId,
        peerTokenLookup: (_) async => peer.pairToken,
      );
      final result = await engine.run();
      await channel.close();
      await _reload();
      _showResult(result);
      await _teardown();
    } catch (error) {
      _fail('$error');
      await _teardown();
    }
  }

  /// Joins a saved host device at its last known address.
  Future<void> _joinSavedPeer(SyncPeer peer) async {
    _reset();
    final unreachable = AppL10n.isEnglish(context)
        ? 'Could not reach ${peer.displayName}. Is it hosting right now?'
        : 'تعذر الوصول إلى ${peer.displayName}. هل هو في وضع الاستضافة الآن؟';
    setState(() {
      _phase = _Phase.syncing;
      _statusLine = tr(context, 'connecting');
    });
    final client = WsClientTransport(
      uri: Uri.parse('ws://${peer.lastIp}:${peer.lastPort}/sync'),
    );
    try {
      await client.start();
      final channel = await SyncSecureChannel.establish(
        transport: client,
        side: SyncSide.guest,
        sessionId: 'sync-${DateTime.now().millisecondsSinceEpoch}',
        hostPublicKey: base64Decode(peer.hostPublicKeyB64!),
      );
      final engine = SyncSessionEngine(
        channel: channel,
        database: widget.database,
        preferences: _preferences,
        hostRole: false,
        mySavedToken: peer.pairToken,
        peerIp: peer.lastIp,
        peerPort: peer.lastPort,
      );
      final result = await engine.run();
      await channel.close();
      await _reload();
      _showResult(result);
    } on TimeoutException {
      _fail(unreachable);
    } catch (error) {
      _fail('$error');
    } finally {
      await client.close();
    }
  }

  /// Joins by scanning the host's QR (first pairing).
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
    await _joinPairing(pairing);
  }

  Future<void> _joinPairing(PairingInfo pairing) async {
    _reset();
    final unreachable = AppL10n.isEnglish(context)
        ? 'Could not reach the host. Check the hints in the failed session.'
        : 'تعذر الوصول إلى الجهاز المضيف. راجع التلميحات في الجلسة الفاشلة.';
    setState(() {
      _phase = _Phase.syncing;
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
      final engine = SyncSessionEngine(
        channel: channel,
        database: widget.database,
        preferences: _preferences,
        hostRole: false,
        peerHostPublicKeyB64: pairing.publicKeyB64,
        peerIp: pairing.ip,
        peerPort: pairing.port,
      );
      final result = await engine.run();
      await channel.close();
      await _reload();
      _showResult(result);
    } on TimeoutException {
      _fail(unreachable);
    } catch (error) {
      _fail('$error');
    } finally {
      await client.close();
    }
  }

  Future<void> _renamePeer(SyncPeer peer) async {
    final controller = TextEditingController(text: peer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'renameDevice')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(labelText: tr(context, 'deviceNameLabel')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr(context, 'save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await widget.database.renameSyncPeer(peer.deviceId, name);
    await _reload();
  }

  Future<void> _deletePeer(SyncPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteDevice')),
        content: Text(
          tr(context, 'deleteDeviceConfirm')
              .replaceAll('{name}', peer.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.database.deleteSyncPeer(peer.deviceId);
    await _reload();
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
            Text(
              tr(context, 'savedDevices'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            if (_peers.isEmpty)
              Text(
                tr(context, 'noSavedDevices'),
                style: theme.textTheme.bodySmall,
              )
            else
              for (final peer in _peers) ...[
                _PeerCard(
                  peer: peer,
                  onTap: () => peer.lastRole == 'host'
                      ? _joinSavedPeer(peer)
                      : _hostForSavedPeer(peer),
                  onRename: () => _renamePeer(peer),
                  onDelete: () => _deletePeer(peer),
                ),
                const SizedBox(height: 8),
              ],
            const SizedBox(height: 16),
            Text(
              tr(context, 'newPairing'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: () async {
                  await _teardown();
                  if (!mounted) return;
                  setState(() => _phase = _Phase.config);
                },
                child: Text(tr(context, 'cancel')),
              ),
            ),
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
              onChanged: enabled
                  ? (value) =>
                      onChanged(preferences.copyWith(syncInvoices: value))
                  : null,
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

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    required this.peer,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SyncPeer peer;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSynced = peer.lastSyncedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(peer.lastSyncedAt!);
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.phone_android_rounded,
              color: theme.colorScheme.primary),
        ),
        title: Text(
          peer.displayName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lastSynced != null)
              Text(
                '${tr(context, 'lastSync')}: '
                '${lastSynced.day}/${lastSynced.month}/${lastSynced.year}',
                style: theme.textTheme.bodySmall,
              ),
            Text(
              peer.lastRole == 'host'
                  ? tr(context, 'peerRoleHost')
                  : tr(context, 'peerRoleGuest'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: tr(context, 'renameDevice'),
              onPressed: onRename,
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
            IconButton(
              tooltip: tr(context, 'delete'),
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: theme.colorScheme.error),
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
