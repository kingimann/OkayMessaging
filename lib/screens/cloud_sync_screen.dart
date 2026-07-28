import 'package:flutter/material.dart';

import '../payments/payment_service.dart';
import '../state/cloud_sync.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../state/saved_places_store.dart';
import '../state/score_store.dart';
import '../state/storage_store.dart';
import '../utils/date_formatter.dart';
import 'cloud_sync_count.dart';

/// Cloud storage: a paid monthly subscription that backs everything (except
/// chats) up to the server, end-to-end encrypted. Chats never leave the
/// device. Without an active subscription nothing uploads.
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final TextEditingController _pass =
      TextEditingController(text: CloudSync.instance.passphrase);
  bool _obscure = true;
  bool _buying = false;

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

  Future<void> _subscribe() async {
    final payments = PaymentService.instance;
    if (!payments.canBuyStorage) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Payments aren\'t set up on this device. Turn on payments test '
            'mode in Wallet to try it, or open the app on your phone.'),
      ));
      return;
    }
    setState(() => _buying = true);
    try {
      final ok =
          await payments.buyStorage(amountCents: StorageStore.priceCents);
      if (!mounted) return;
      if (ok) {
        await StorageStore.instance.addPeriod();
        // Back up immediately so the subscription pays off right away.
        await CloudSync.instance.syncNow();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cloud storage is on — your data is backing up.'),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Payment cancelled.'),
        ));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Couldn\'t complete the purchase. Try again.'),
      ));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud storage')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [CloudSync.instance, StorageStore.instance]),
        builder: (context, _) {
          final sync = CloudSync.instance;
          final storage = StorageStore.instance;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _subscriptionCard(context, storage),
              if (storage.active) ...[
                const SizedBox(height: 12),
                _usageCard(context, sync, storage),
              ],
              const SizedBox(height: 12),
              _encryptionCard(context),
              const SizedBox(height: 12),
              _backupContents(context),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Custom encryption key (optional, min 6 chars)',
                  helperText:
                      'Use your own key instead of your phone number — '
                      'portable across numbers, unrecoverable if lost.',
                  helperMaxLines: 2,
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
                      onPressed: (sync.syncing || !storage.active)
                          ? null
                          : () async {
                              await CloudSync.instance.configure(
                                  passphrase: _pass.text, on: sync.enabled);
                              await _run(CloudSync.instance.syncNow,
                                  'Backed up — encrypted end to end.');
                            },
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: const Text('Sync now'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (sync.syncing || !storage.active)
                          ? null
                          : () async {
                              await CloudSync.instance.configure(
                                  passphrase: _pass.text, on: sync.enabled);
                              await _run(CloudSync.instance.restore,
                                  'Restored from your encrypted backup.');
                            },
                      icon:
                          const Icon(Icons.cloud_download_outlined, size: 18),
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
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
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

  /// The plan card: price, current state, and the subscribe / renew button.
  Widget _subscriptionCard(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    final active = storage.active;
    return Card(
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(active ? Icons.cloud_done : Icons.cloud_outlined,
                    color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(StorageStore.planName,
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                Text('${storage.priceLabel}/mo',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              active
                  ? 'Active — ${storage.daysLeft} day'
                      '${storage.daysLeft == 1 ? '' : 's'} left. Your servers, '
                      'posts, follows, saved places and score keep backing up '
                      'automatically.'
                  : 'Back up everything except chats to the server, encrypted '
                      'end to end, and restore it on any device by signing in. '
                      'Subscribe to turn it on.',
              style: TextStyle(
                  fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _buying ? null : _subscribe,
                icon: _buying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(active ? Icons.refresh : Icons.lock_open, size: 18),
                label: Text(_buying
                    ? 'Processing…'
                    : active
                        ? 'Renew — ${storage.priceLabel} for 30 more days'
                        : 'Subscribe — ${storage.priceLabel}/month'),
              ),
            ),
            if (active) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _confirmCancel(context, storage),
                  child: const Text('Cancel storage'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancel(
      BuildContext context, StorageStore storage) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel cloud storage?'),
        content: const Text(
            'Automatic backup stops immediately. Whatever is already backed '
            'up stays on the server, and you can subscribe again anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel storage')),
        ],
      ),
    );
    if (ok == true) await storage.cancel();
  }

  /// The usage meter: used vs available, a per-category breakdown, and a
  /// backup health check.
  Widget _usageCard(
      BuildContext context, CloudSync sync, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    // Before the first upload there's no recorded size; show the live estimate
    // so the meter isn't stuck at zero.
    final used = storage.usedBytes > 0
        ? storage.usedBytes
        : sync.estimatedBytes();
    final fraction = (used / StorageStore.quotaBytes).clamp(0.0, 1.0);
    final sections = sync.sectionSizes().take(5).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline, color: scheme.primary),
                const SizedBox(width: 8),
                const Text('Storage used',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                  '${StorageStore.formatBytes(used)} of ${storage.quotaLabel}',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text('${storage.availableLabel} available',
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            if (sections.isNotEmpty) ...[
              const Divider(height: 22),
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                          child: Text(s.key,
                              style: const TextStyle(fontSize: 13.5))),
                      Text(StorageStore.formatBytes(s.value),
                          style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: sync.syncing
                    ? null
                    : () => _run(CloudSync.instance.verifyBackup,
                        'Backup verified — present and readable.'),
                icon: const Icon(Icons.verified_outlined, size: 18),
                label: const Text('Verify backup'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _encryptionCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: scheme.primary),
                const SizedBox(width: 8),
                const Text('End-to-end encrypted',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Everything is encrypted on this device (AES-256-GCM) before it '
              'uploads — the server only ever stores ciphertext it can\'t '
              'read. Chats are never included: your messages stay on the '
              'device they were sent from.',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backupContents(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([
        FeedStore.instance,
        FollowStore.instance,
        SavedPlacesStore.instance,
        CommunityStore.instance,
        ScoreStore.instance,
      ]),
      builder: (context, _) {
        final parts = <String>[
          backupCount(FeedStore.instance.exportPosts().length, 'post'),
          backupCount(FollowStore.instance.followingCount, 'follow'),
          backupCount(
              SavedPlacesStore.instance.places.length, 'saved place'),
          backupCount(CommunityStore.instance.communities.length, 'community',
              plural: 'communities'),
          '${ScoreStore.instance.points} score',
        ];
        return Row(
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'In this backup: ${parts.join(' · ')}',
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }
}
