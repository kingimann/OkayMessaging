import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/backup_service.dart';
import '../util/backup_export.dart';
import '../utils/date_formatter.dart';
import '../widgets/info_section.dart';
import 'settings_widgets.dart';

/// Lets the user create an end-to-end encrypted backup of their chats and send
/// it to iCloud Drive, Dropbox, or Google Drive — and restore from one.
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  String _fileName(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'okay-messaging-${now.year}-${two(now.month)}-${two(now.day)}.okaybak';
  }

  Future<void> _backUp(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final pass = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(confirming: true),
    );
    if (pass == null || pass.isEmpty) return;
    final now = DateTime.now();
    final bytes = BackupService.instance.createArchiveBytes(pass, now: now);
    final result = await exportBackupFile(_fileName(now), bytes);
    messenger.showSnackBar(SnackBar(
      content: Text(result ?? 'Couldn\'t create the backup file'),
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _restore(BuildContext context) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore a backup?'),
        content: const Text(
            'Restoring replaces the chats on this device with the ones in the '
            'backup. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Choose file')),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFiles(withData: true);
    final bytes = picked?.files.singleOrNull?.bytes;
    if (bytes == null) return;
    if (!context.mounted) return;

    final pass = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(confirming: false),
    );
    if (pass == null || pass.isEmpty) return;

    final ok = await BackupService.instance.restoreFromBytes(bytes, pass);
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'Backup restored'
          : 'Couldn\'t restore — wrong passphrase or invalid file'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat backup')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Create an encrypted backup of your chats and keep it in the '
              'cloud. Your backup is locked with a passphrase only you know — '
              'neither Okay nor the cloud provider can read it.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13.5),
            ),
          ),
          const _ProviderRow(),
          settingsSectionLabel(context, 'Backup'),
          InfoSection(children: [
            ListenableBuilder(
              listenable: BackupService.instance,
              builder: (context, _) {
                final at = BackupService.instance.lastBackupAt;
                return InfoTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: 'Back up now',
                  subtitle: at == null
                      ? 'No backup yet'
                      : 'Last backup ${DateFormatter.callLabel(at)}',
                  onTap: () => _backUp(context),
                );
              },
            ),
            InfoTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: 'Restore from backup',
              subtitle: 'Import an .okaybak file',
              onTap: () => _restore(context),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 15, color: Colors.grey.shade500),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'End-to-end encrypted with AES-256. If you lose the '
                    'passphrase, the backup can\'t be recovered.',
                    style:
                        TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// The row of cloud destinations a backup can be saved to.
class _ProviderRow extends StatelessWidget {
  const _ProviderRow();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.cloud_outlined, 'iCloud'),
      (Icons.folder_shared_outlined, 'Dropbox'),
      (Icons.add_to_drive_outlined, 'Drive'),
      (Icons.folder_outlined, 'Files'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final (icon, label) in items)
            Column(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.10),
                  child: Icon(icon,
                      color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(height: 6),
                Text(label,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            ),
        ],
      ),
    );
  }
}

/// A dialog collecting a backup passphrase. When [confirming], a second field
/// must match (used when creating a backup). It owns its controllers so they
/// dispose cleanly after the exit transition.
class _PassphraseDialog extends StatefulWidget {
  final bool confirming;
  const _PassphraseDialog({required this.confirming});

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _pass.text;
    if (widget.confirming) {
      if (p.length < 6) {
        setState(() => _error = 'Use at least 6 characters');
        return;
      }
      if (p != _confirm.text) {
        setState(() => _error = 'Passphrases don\'t match');
        return;
      }
    } else if (p.isEmpty) {
      return;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.confirming ? 'Set a backup passphrase' : 'Enter passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pass,
            obscureText: _obscure,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (widget.confirming) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(labelText: 'Confirm passphrase'),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child:
                  Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
