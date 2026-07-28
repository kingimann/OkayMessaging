import 'package:flutter/material.dart';

import '../payments/store_purchases.dart';
import '../state/cloud_sync.dart';
import '../state/storage_store.dart';
import '../utils/date_formatter.dart';

/// Cloud storage.
///
/// Servers, posts and follows sync for free and are not shown here — this
/// screen is about the one thing that counts as *your* storage: your chat
/// history. It can be backed up to the cloud, encrypted under a key only you
/// hold, on a tiered plan (Free up to paid). Chats can also just be backed up
/// locally to iCloud / app storage instead.
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final TextEditingController _pass =
      TextEditingController(text: CloudSync.instance.passphrase);
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action, String success) async {
    await CloudSync.instance
        .configure(passphrase: _pass.text, on: CloudSync.instance.enabled);
    final error = await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error ?? success)));
  }

  Future<void> _choosePlan(StoragePlan plan) async {
    final storage = StorageStore.instance;
    if (plan.isFree) {
      // Downgrading to Free is free and immediate.
      if (storage.selectedTier != StorageTier.free) {
        final ok = await _confirm(
            'Switch to Free?',
            'You drop to ${StorageStore.formatBytes(plan.quotaBytes)}. If your '
                'chat backup is larger than that, it stays on the server but '
                'you can\'t add to it until you\'re back under the limit.');
        if (ok) await storage.subscribe(StorageTier.free);
      }
      return;
    }
    // Storage is a subscription — it bills through the App Store, not Stripe.
    final store = StorePurchases.instance;
    if (!store.isSupported) {
      _snack('Purchases aren\'t available on this device. Turn on payments '
          'test mode in Wallet to try it, or open the app on your iPhone.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await store.buyStorage(plan.tier);
      if (!mounted) return;
      if (ok) {
        await storage.subscribe(plan.tier);
        _snack('You\'re on ${plan.name} — '
            '${plan.quotaBytes ~/ (1024 * 1024 * 1024)} GB of chat storage.');
      } else {
        _snack('Purchase cancelled.');
      }
    } catch (_) {
      _snack('Couldn\'t complete the purchase. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud storage')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([CloudSync.instance, StorageStore.instance]),
        builder: (context, _) {
          final sync = CloudSync.instance;
          final storage = StorageStore.instance;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _communalNote(context),
              const SizedBox(height: 12),
              _usageCard(context, storage),
              const SizedBox(height: 16),
              _plansSection(context, storage),
              const SizedBox(height: 20),
              _chatBackupSection(context, sync, storage),
            ],
          );
        },
      ),
    );
  }

  Widget _communalNote(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.groups_2_outlined, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Your servers, posts and follows sync automatically for everyone — '
            'free, and never counted against your storage. This is just your '
            'chat backup.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _usageCard(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Text('${storage.plan.name} plan',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (storage.isPaid)
                  Text('${storage.daysLeft} days left',
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: storage.usedFraction,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                color: storage.isFull
                    ? scheme.error
                    : (storage.nearLimit ? const Color(0xFFF0A020) : null),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${storage.usedLabel} of ${storage.quotaLabel} used · '
              '${storage.availableLabel} free',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            if (storage.isFull || storage.nearLimit) ...[
              const SizedBox(height: 10),
              _limitBanner(context, storage),
            ],
          ],
        ),
      ),
    );
  }

  /// A gentle nudge (near limit) or a hard stop (full), with a one-tap upgrade
  /// to the smallest plan that would actually fit.
  Widget _limitBanner(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    final full = storage.isFull;
    final bigger = StorageStore.plans
        .where((p) => p.quotaBytes > storage.quotaBytes)
        .cast<StoragePlan?>()
        .firstWhere((_) => true, orElse: () => null);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (full ? scheme.errorContainer : scheme.tertiaryContainer)
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(full ? Icons.error_outline : Icons.info_outline,
              size: 18, color: scheme.onSurface),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              full
                  ? 'Your ${storage.plan.name} storage is full. Upgrade to keep '
                      'backing up chats.'
                  : 'You\'re almost out of ${storage.plan.name} storage.',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          if (bigger != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _choosePlan(bigger),
              style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: Text('Get ${bigger.name}'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _plansSection(BuildContext context, StorageStore storage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Text('NEED MORE SPACE?',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Colors.grey.shade500)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Pick a plan to add storage. The App Store sets fixed sizes, so '
            'these are the amounts on offer.',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        for (final plan in StorageStore.plans)
          _planTile(context, plan, storage),
      ],
    );
  }

  Widget _planTile(
      BuildContext context, StoragePlan plan, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    final current = storage.selectedTier == plan.tier;
    final gb = plan.quotaBytes ~/ (1024 * 1024 * 1024);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: current
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: ListTile(
        title: Row(
          children: [
            Text(plan.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            if (current)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Current',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
              ),
          ],
        ),
        subtitle: Text('$gb GB'),
        trailing: current
            ? (plan.isFree
                ? null
                : TextButton(
                    onPressed: _busy ? null : () => _choosePlan(plan),
                    child: const Text('Renew')))
            : FilledButton.tonal(
                onPressed: _busy ? null : () => _choosePlan(plan),
                child: Text(plan.isFree ? 'Switch' : plan.priceLabel),
              ),
      ),
    );
  }

  Widget _chatBackupSection(
      BuildContext context, CloudSync sync, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text('CHAT BACKUP',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Colors.grey.shade500)),
        ),
        Text(
          'Your chats are encrypted with a key only you hold before they ever '
          'leave the device. Lose the key and nobody — not even us — can '
          'recover the backup.',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: _obscure,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Encryption key (min 6 characters)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              tooltip: _obscure ? 'Show' : 'Hide',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (!sync.chatBackupReady && _pass.text.trim().length < 6)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Set a key of at least 6 characters to enable chat backup.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (sync.syncing || _pass.text.trim().length < 6)
                    ? null
                    : () => _run(CloudSync.instance.backUpChats,
                        'Chats backed up — encrypted end to end.'),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('Back up chats'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (sync.syncing || _pass.text.trim().length < 6)
                    ? null
                    : () => _run(CloudSync.instance.restoreChats,
                        'Chats restored from your encrypted backup.'),
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('Restore'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: (sync.syncing || _pass.text.trim().length < 6)
                ? null
                : () => _run(CloudSync.instance.verifyChatBackup,
                    'Chat backup verified — present and readable.'),
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: const Text('Verify backup'),
          ),
        ),
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
          Text('Last backup: ${DateFormatter.callLabel(sync.lastSync!)}',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        if (sync.lastError != null) ...[
          const SizedBox(height: 8),
          Card(
            color: scheme.errorContainer.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(sync.lastError!,
                  style: const TextStyle(fontSize: 13.5)),
            ),
          ),
        ],
      ],
    );
  }
}
