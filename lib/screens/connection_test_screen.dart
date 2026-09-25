import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../sync/testing/connection_test_session.dart';
import '../sync/transport/ws_transport.dart';

/// M1 diagnostic screen: proves the sync transports work before any sync
/// feature is built on top of them. Runs the battery over a loopback pair
/// (single device) or between two devices over the local WebSocket.
class ConnectionTestScreen extends StatefulWidget {
  const ConnectionTestScreen({super.key});

  @override
  State<ConnectionTestScreen> createState() => _ConnectionTestScreenState();
}

class _ConnectionTestScreenState extends State<ConnectionTestScreen> {
  bool _running = false;
  String? _statusLine;
  List<TestResult> _results = const [];
  bool _allPassed = false;
  String? _error;
  String? _localIp;

  WsServerTransport? _server;
  ConnectionTestSession? _session;
  final TextEditingController _ipController = TextEditingController();

  @override
  void dispose() {
    unawaited(_teardown());
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _teardown() async {
    _session = null;
    final server = _server;
    _server = null;
    await server?.close();
  }

  void _reset() {
    setState(() {
      _results = const [];
      _allPassed = false;
      _error = null;
      _statusLine = null;
    });
  }

  void _applyReport(TestReport report, String successLine) {
    if (!mounted) return;
    setState(() {
      _results = report.results;
      _allPassed = report.results.isNotEmpty && report.allPassed;
      _statusLine = successLine;
      _running = false;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = message;
    });
  }

  Future<void> _runSelfTest() async {
    _reset();
    setState(() {
      _running = true;
      _statusLine = tr(context, 'running');
    });
    try {
      // The battery uses the full production sizes by default; keep the
      // large transfer lighter here so the self-check stays snappy.
      final report = await runLoopbackSelfTest();
      if (!mounted) return;
      _applyReport(
        report,
        report.allPassed ? tr(context, 'allPassed') : tr(context, 'someFailed'),
      );
    } catch (error) {
      _fail('$error');
    }
  }

  Future<void> _startHosting() async {
    _reset();
    setState(() {
      _running = true;
      _statusLine = tr(context, 'listening');
    });
    final ip = await localIpv4Address();
    if (!mounted) return;
    setState(() => _localIp = ip);
    final server = WsServerTransport();
    try {
      final port = await server.start();
      if (!mounted) return;
      setState(() {
        _server = server;
        _statusLine = '${tr(context, 'listening')} (ws://$ip:$port/sync)';
      });
      // Wait for the first inbound frame (the client's hello), then run
      // the echo role until the client sends `bye`.
      await for (final _ in server.frames) {
        if (_session != null) continue;
        _session = ConnectionTestSession(transport: server, role: TestRole.echo);
        final report = await _session!.run();
        if (!mounted) return;
        _applyReport(report, tr(context, 'peerCompleted'));
        _session = null;
      }
    } catch (error) {
      _fail('$error');
    } finally {
      await server.close();
      if (mounted) setState(() => _server = null);
    }
  }

  Future<void> _joinHost() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    _reset();
    setState(() {
      _running = true;
      _statusLine = tr(context, 'connecting');
    });
    final client = WsClientTransport(
      uri: Uri.parse('ws://$ip:$kDefaultSyncPort/sync'),
    );
    try {
      await client.start();
      final session = ConnectionTestSession(
        transport: client,
        role: TestRole.initiator,
      );
      _session = session;
      final report = await session.run();
      if (!mounted) return;
      _applyReport(
        report,
        report.allPassed ? tr(context, 'allPassed') : tr(context, 'someFailed'),
      );
    } on TimeoutException {
      if (!mounted) return;
      _fail(tr(context, 'hostUnreachable'));
    } catch (error) {
      _fail('$error');
    } finally {
      await client.close();
      _session = null;
    }
  }

  void _cancel() {
    unawaited(_teardown());
    setState(() {
      _running = false;
      _statusLine = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'connectionTest')),
        actions: [
          if (_running)
            IconButton(
              tooltip: tr(context, 'cancel'),
              onPressed: _cancel,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
        children: [
          Text(
            tr(context, 'connTestIntro'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),
          _ModeCard(
            icon: Icons.devices_rounded,
            title: tr(context, 'selfTest'),
            subtitle: tr(context, 'selfTestHint'),
            onTap: _running ? null : _runSelfTest,
          ),
          const SizedBox(height: 10),
          _ModeCard(
            icon: Icons.wifi_tethering_rounded,
            title: tr(context, 'hostTest'),
            subtitle: tr(context, 'hostTestHint'),
            onTap: _running ? null : _startHosting,
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.link_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr(context, 'joinTest'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ipController,
                    enabled: !_running,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: tr(context, 'ipAddress'),
                      hintText: '192.168.1.20',
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _running ? null : _joinHost,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(tr(context, 'connect')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_statusLine != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                if (_running)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _allPassed ? Icons.check_circle_rounded : Icons.info_rounded,
                    size: 18,
                    color: _allPassed
                        ? theme.colorScheme.primary
                        : theme.colorScheme.tertiary,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusLine!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_localIp != null) ...[
            const SizedBox(height: 8),
            Text(
              '${tr(context, 'yourIp')}: $_localIp',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Card(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
                    const SizedBox(width: 10),
                    Expanded(child: SelectableText(_error!)),
                  ],
                ),
              ),
            ),
          ],
          for (final result in _results) ...[
            const SizedBox(height: 8),
            _ResultCard(result: result),
          ],
          const SizedBox(height: 16),
          Text(
            tr(context, 'cloudTestPending'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: onTap,
        enabled: onTap != null,
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final TestResult result;

  String _displayName(BuildContext context) {
    if (result.name.startsWith('transfer-')) {
      final size = result.metrics['size'] ?? '';
      return '${tr(context, 'testTransfer')} ($size)';
    }
    if (result.name == 'ping') return tr(context, 'testPing');
    if (result.name == 'handshake') return tr(context, 'testHandshake');
    return result.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.passed
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 20,
                  color: result.passed
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayName(context),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(result.detail, style: theme.textTheme.bodySmall),
            if (result.metrics.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final entry in result.metrics.entries)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${entry.key}: ${entry.value}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
