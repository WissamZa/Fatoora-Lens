import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_info.dart';
import '../l10n.dart';
import 'connection_test_screen.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({
    required this.darkMode,
    required this.onToggleTheme,
    required this.onToggleLanguage,
    required this.onExportCsv,
    required this.onBackup,
    required this.onRestore,
    required this.onPdf,
    super.key,
  });

  final bool darkMode;
  final VoidCallback onToggleTheme;
  final VoidCallback onToggleLanguage;
  final VoidCallback onExportCsv;
  final VoidCallback onBackup;
  final VoidCallback onRestore;
  final VoidCallback onPdf;

  @override
  Widget build(BuildContext context) {
    final english = AppL10n.isEnglish(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
      children: [
        Text(tr(context, 'settings'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              SwitchListTile.adaptive(
                value: darkMode,
                onChanged: (_) => onToggleTheme(),
                title: Text(tr(context, 'darkMode')),
                secondary: const Icon(Icons.dark_mode_outlined),
              ),
              ListTile(
                leading: const Icon(Icons.language_outlined),
                title: Text(tr(context, 'language')),
                subtitle: Text(english ? tr(context, 'english') : tr(context, 'arabic')),
                trailing: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(tr(context, 'arabic'))),
                    ButtonSegment(value: true, label: Text(tr(context, 'english'))),
                  ],
                  selected: {english},
                  onSelectionChanged: (selection) {
                    if (selection.first != english) onToggleLanguage();
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _ActionCard(icon: Icons.file_download_outlined, title: tr(context, 'exportCsv'), onTap: onExportCsv),
        const SizedBox(height: 10),
        _ActionCard(icon: Icons.backup_outlined, title: tr(context, 'backup'), onTap: onBackup),
        const SizedBox(height: 10),
        _ActionCard(icon: Icons.restore_outlined, title: tr(context, 'restore'), onTap: onRestore),
        const SizedBox(height: 10),
        _ActionCard(icon: Icons.picture_as_pdf_outlined, title: tr(context, 'pdf'), onTap: onPdf),
        const SizedBox(height: 10),
        _ActionCard(
          icon: Icons.wifi_tethering_rounded,
          title: tr(context, 'connectionTest'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ConnectionTestScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _ActionCard(icon: Icons.info_outline_rounded, title: tr(context, 'aboutApp'), onTap: () => _showAboutDialog(context)),
      ],
    );
  }

  Future<void> _showAboutDialog(BuildContext context) async {
    final english = AppL10n.isEnglish(context);
    // The version comes from the platform (sourced from pubspec.yaml),
    // so bumping the version in one place updates the About screen too.
    final packageInfo = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0A7A67), Color(0xFF159E83)],
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                    ),
                  ),
                  child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 38),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  english ? AppInfo.appNameEn : AppInfo.appNameAr,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${tr(context, 'version')} ${packageInfo.version}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                english ? AppInfo.descriptionEn : AppInfo.descriptionAr,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 16),
              _AboutRow(
                icon: Icons.engineering_outlined,
                label: tr(context, 'developer'),
                value: AppInfo.developerName,
              ),
              if (AppInfo.contactEmail.isNotEmpty)
                _AboutRow(
                  icon: Icons.alternate_email_rounded,
                  label: tr(context, 'contact'),
                  value: AppInfo.contactEmail,
                ),
              if (AppInfo.contactPhone.isNotEmpty)
                _AboutRow(
                  icon: Icons.phone_outlined,
                  label: tr(context, 'contact'),
                  value: AppInfo.contactPhone,
                ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'close')),
            ),
          ],
        );
      },
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      );
}
