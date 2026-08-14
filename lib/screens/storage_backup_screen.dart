import 'package:flutter/material.dart';

import '../state/backup_service.dart';
import '../state/storage_store.dart';
import '../widgets/info_section.dart';
import 'backup_screen.dart';
import 'cloud_sync_screen.dart';

/// Backup and storage under one row, because they were three rows answering
/// the same question in different words: **Chat backup** (the encrypted export
/// to iCloud/Dropbox/Drive), **Cloud storage** (the paid plan that backup
/// rides on), and **Storage and data** (clearing chats off this phone).
///
/// Nothing moved into anything else — each still opens the screen it always
/// did, and every one of them is reachable by the same words it was findable
/// by before. What changed is that Settings names the topic once instead of
/// three times, which is the whole point: a settings list you scroll past is
/// a settings list nobody reads.
class StorageBackupScreen extends StatelessWidget {
  /// What "Storage and data" does — clearing every chat off this device. It
  /// lives in `settings_screen.dart` beside the other destructive
  /// confirmations, so it is passed in rather than copied here: two dialogs
  /// asking to delete every message is one too many.
  final Future<void> Function(BuildContext context) onClearChats;

  const StorageBackupScreen({super.key, required this.onClearChats});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage & backup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          InfoSection(
            children: [
              ListenableBuilder(
                listenable: BackupService.instance,
                builder: (context, _) => InfoTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: 'Chat backup',
                  subtitle: 'Encrypted backup to iCloud, Dropbox, or Drive',
                  trailing: BackupService.instance.isBackupDue()
                      ? const Icon(Icons.schedule, color: Color(0xFFF57F17))
                      : null,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BackupScreen()),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: StorageStore.instance,
                builder: (context, _) {
                  final storage = StorageStore.instance;
                  return InfoTile(
                    leading: const Icon(Icons.cloud_sync_outlined),
                    title: 'Cloud storage',
                    subtitle: storage.isPaid
                        ? '${storage.plan.name} — encrypted chat backup, '
                            '${storage.quotaLabel}'
                        : 'Encrypted chat backup — Free ${storage.quotaLabel}, '
                            'upgrade for more',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
                    ),
                  );
                },
              ),
              InfoTile(
                leading: const Icon(Icons.data_usage_outlined),
                title: 'Storage and data',
                subtitle: 'Clear all chats from this device',
                onTap: () => onClearChats(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
