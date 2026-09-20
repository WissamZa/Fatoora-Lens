import 'package:flutter/material.dart';

import '../l10n.dart';

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
      ],
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
