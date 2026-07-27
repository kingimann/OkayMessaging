import 'package:flutter/material.dart';

import '../state/chat_store.dart';
import 'cloud_sync_count.dart';
import '../state/cloud_sync.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../state/saved_places_store.dart';
import '../state/score_store.dart';
import '../utils/date_formatter.dart';

/// Settings for end-to-end encrypted cloud sync: everything is encrypted on
/// this device with a passphrase-derived key before it ever leaves it.
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final TextEditingController _pass =
      TextEditingController(text: CloudSync.instance.passphrase);
  bool _obscure = true;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action, String success) async {
    final error = await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? success)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypted cloud sync')),
      body: ListenableBuilder(
        listenable: CloudSync.instance,
        builder: (context, _) {
          final sync = CloudSync.instance;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lock_outline,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          const Text('End-to-end encrypted',
                              style:
                                  TextStyle(fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        sync.autoMode
                            ? 'Your servers, feed posts, follows, saved '
                                'places and Okay Score back up automatically '
                                '— encrypted on this device (AES-256-GCM) '
                                'before upload, and restored just by signing '
                                'in with your number again. Chats stay on '
                                'this device. Set a passphrase below to use '
                                'a stronger key and include chats.'
                            : 'Chats, feed posts, follows, saved places, '
                                'your communities and your Okay Score are '
                                'encrypted on this device (AES-256-GCM, key '
                                'derived from your passphrase) before '
                                'upload. The server only ever stores '
                                'ciphertext it cannot read — and if you '
                                'lose the passphrase, nobody can recover '
                                'the backup. Not even us.',
                        style: TextStyle(
                            fontSize: 13.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // What's actually in the backup, so "Sync now" isn't a
              // leap of faith.
              ListenableBuilder(
                listenable: Listenable.merge([
                  ChatStore.instance,
                  FeedStore.instance,
                  FollowStore.instance,
                  SavedPlacesStore.instance,
                  CommunityStore.instance,
                  ScoreStore.instance,
                ]),
                builder: (context, _) {
                  final parts = <String>[
                    // Chats ride only under a user-set passphrase.
                    if (!CloudSync.instance.autoMode)
                      backupCount(ChatStore.instance.chats.length, 'chat'),
                    backupCount(FeedStore.instance.exportPosts().length, 'post'),
                    backupCount(FollowStore.instance.followingCount, 'follow'),
                    backupCount(
                        SavedPlacesStore.instance.places.length, 'saved place'),
                    backupCount(CommunityStore.instance.communities.length,
                        'community', plural: 'communities'),
                    '${ScoreStore.instance.points} score',
                  ];
                  return Row(
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 16,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'In this backup: ${parts.join(' · ')}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText:
                      'Passphrase (optional — adds chats, min 6 characters)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    tooltip: _obscure ? 'Show' : 'Hide',
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                title: const Text('Sync automatically'),
                subtitle:
                    const Text('Upload an encrypted copy after changes'),
                value: sync.enabled,
                onChanged: (v) => CloudSync.instance
                    .configure(passphrase: _pass.text, on: v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: sync.syncing
                          ? null
                          : () async {
                              await CloudSync.instance.configure(
                                  passphrase: _pass.text,
                                  on: sync.enabled);
                              await _run(CloudSync.instance.syncNow,
                                  'Backed up — encrypted end to end.');
                            },
                      icon: const Icon(Icons.cloud_upload_outlined,
                          size: 18),
                      label: const Text('Sync now'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: sync.syncing
                          ? null
                          : () async {
                              await CloudSync.instance.configure(
                                  passphrase: _pass.text,
                                  on: sync.enabled);
                              await _run(CloudSync.instance.restore,
                                  'Restored from your encrypted backup.');
                            },
                      icon: const Icon(Icons.cloud_download_outlined,
                          size: 18),
                      label: const Text('Restore'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (sync.syncing)
                const Center(
                    child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )),
              if (sync.lastSync != null)
                Text(
                  'Last synced: ${DateFormatter.callLabel(sync.lastSync!)}',
                  style:
                      TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              if (sync.lastError != null) ...[
                const SizedBox(height: 8),
                Card(
                  color: Theme.of(context)
                      .colorScheme
                      .errorContainer
                      .withValues(alpha: 0.4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(sync.lastError!,
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
