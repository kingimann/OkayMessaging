import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../state/backup_prefs.dart';
import '../state/cloud_sync.dart';
import '../payments/iap_entitlement.dart';
import '../state/storage_store.dart';
import '../utils/date_formatter.dart';

/// Cloud storage.
///
/// Servers, posts and follows sync for free and are not shown here — this
/// screen is about the one thing that counts as *your* storage: your chat
/// history. It can be backed up to the cloud, encrypted under a key only you
/// hold, on a paid plan — there is no free allowance. Chats can also just be backed up
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

  /// The size the picker is currently showing, in GB. Null until first build,
  /// which seeds it from what the user already has.
  int? _pickedGb;

  @override
  void initState() {
    super.initState();
    // Ask the server what Apple has done since last time — a renewal, a
    // cancellation, or a refund all happen without the app being open.
    IapEntitlement.instance.refresh().then((e) {
      if (e == null || !mounted) return;
      StorageStore.instance.applyServerEntitlement(
          active: e.active, gb: e.gb, expiresAt: e.expiresAt);
    });
  }

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

  /// A plan's monthly price for the button and the header — the App Store's
  /// real localized price for that size's product (USD or CAD, and matching
  /// the charge), falling back to the plan's plain USD figure off-store.
  String _priceLabel(StoragePlan plan) => plan.isNone
      ? 'Not subscribed'
      : '${StorePrices.instance.money(plan.priceCents, productId: StorePurchases.storageProductId(plan.gb))}/mo';

  /// Buys [gb] of storage. Passing 0 cancels the subscription outright —
  /// there is no free allowance to fall back to.
  Future<void> _buyGb(int gb) async {
    final storage = StorageStore.instance;
    if (gb <= 0) {
      final ok = await _confirm(
          'Cancel storage?',
          'Chat backup stops. What is already stored stays on the server '
              'until the paid period ends, but nothing new can be added.');
      if (ok) await storage.cancel();
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
      final result = await store.buyStorage(gb);
      if (!mounted) return;
      if (result.ok) {
        await storage.subscribe(gb);
        _snack('You now have $gb GB of chat storage.');
      } else {
        // Every one of these used to read "Purchase cancelled." — including
        // the one that actually happens today, which is that the products do
        // not exist in App Store Connect yet. Telling somebody they changed
        // their mind when they did not is worse than saying nothing.
        _snack(result.message);
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
        listenable: Listenable.merge([
          CloudSync.instance,
          StorageStore.instance,
          BackupPrefs.instance,
        ]),
        builder: (context, _) {
          final sync = CloudSync.instance;
          final storage = StorageStore.instance;
          // ONE left edge. The note was inset by an icon, the section
          // headings by 4, the body copy by 4 and the cards by 0 — four
          // different left edges down one screen, which is most of why it
          // read as untidy.
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _communalNote(context),
              const SizedBox(height: 16),
              _usageCard(context, storage),
              const SizedBox(height: 24),
              _plansSection(context, storage),
              const SizedBox(height: 28),
              _chatBackupSection(context, sync, storage),
              const SizedBox(height: 28),
              _backupOptionsSection(context, sync),
            ],
          );
        },
      ),
    );
  }

  /// A section heading, in the one style this screen uses for all of them.
  Widget _sectionHeading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: AppColors.subtle(context))),
      );

  Widget _communalNote(BuildContext context) => Text(
        'Servers, posts and follows sync for everyone, free, and never count '
        'against your storage. This page is only about your chat backup.',
        style: TextStyle(
            fontSize: 13, height: 1.35, color: AppColors.subtle(context)),
      );

  Widget _usageCard(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    // Two different things, and they were drawn as one. With no plan there is
    // no quota, so the meter read "0 B of 0 B used · 0 B free" under an empty
    // bar — three numbers that say nothing, above a heading that said "No plan
    // plan" because the name already contained the word.
    final none = !storage.isPaid;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // Neutral. This was `primaryContainer`, which in the dark theme is a
        // teal slab — the only saturated block on a screen in an app that is
        // otherwise black and white.
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(none ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                  size: 20, color: AppColors.subtle(context)),
              const SizedBox(width: 8),
              // Flexible: the title and the countdown share one line, and
              // "100 GB of storage" beside "30 days left" is wider than a
              // small phone at a large text size.
              Flexible(
                child: Text(
                    none
                        ? 'No storage plan'
                        : '${storage.plan.name} of storage',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (storage.isPaid) ...[
                const SizedBox(width: 8),
                Text('${storage.daysLeft} days left',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (none)
            Text('Chat backup is off. Pick a size below to turn it on.',
                style: TextStyle(
                    fontSize: 13, color: AppColors.subtle(context)))
          else ...[
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
            const SizedBox(height: 8),
            Text(
              '${storage.usedLabel} of ${storage.quotaLabel} used · '
              '${storage.availableLabel} free',
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
          ],
          if (storage.isFull || storage.nearLimit) ...[
            const SizedBox(height: 12),
            _limitBanner(context, storage),
          ],
        ],
      ),
    );
  }

  /// A gentle nudge (near limit) or a hard stop (full), with a one-tap jump to
  /// the next size up.
  Widget _limitBanner(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    final full = storage.isFull;
    final bigger = storage.nextSizeUp;
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
                  ? 'Your ${storage.quotaLabel} of storage is full. Add more '
                      'to keep backing up chats.'
                  : 'You\'re almost out of storage.',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          if (bigger != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _buyGb(bigger.gb),
              style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: Text('Get ${bigger.gb} GB'),
            ),
          ],
        ],
      ),
    );
  }

  /// "Choose how much space you want": a slider over the purchasable sizes,
  /// with the live price and a buy/renew button.
  Widget _plansSection(BuildContext context, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    final sizes = StorageStore.sizes;
    // Default the picker to what they have (or the first step up from free).
    _pickedGb ??= storage.isPaid ? storage.selectedGb : sizes.first;
    final picked = _pickedGb!;
    final plan = StorageStore.planForGb(picked);
    final isCurrent = storage.isPaid && storage.selectedGb == picked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(context, 'Need more space?'),
        Text(
          'Up to ${StorageStore.maxGb} GB. The App Store sells fixed sizes, '
          'so the slider steps in ${StorageStore.stepGb} GB.',
          style: TextStyle(
              fontSize: 13, height: 1.35, color: AppColors.subtle(context)),
        ),
        const SizedBox(height: 10),
        // The same surface and the same 16 as the card above it. A Card
        // carries its own 4-point margin, so the two blocks on this screen
        // started two points apart — small enough to look like a mistake
        // rather than a decision.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$picked GB',
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text(_priceLabel(plan),
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ],
              ),
              Slider(
                value: picked.toDouble(),
                min: sizes.first.toDouble(),
                max: sizes.last.toDouble(),
                divisions: sizes.length - 1,
                label: '$picked GB',
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _pickedGb =
                        (v / StorageStore.stepGb).round() *
                            StorageStore.stepGb),
              ),
              Row(
                children: [
                  Text('${sizes.first} GB',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  Text('${sizes.last} GB',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _buyGb(picked),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(isCurrent ? Icons.refresh : Icons.cloud_done,
                          size: 18),
                  label: Text(_busy
                      ? 'Processing…'
                      : isCurrent
                          ? 'Renew $picked GB — ${_priceLabel(plan)}'
                          : 'Get $picked GB — ${_priceLabel(plan)}'),
                ),
              ),
            ],
          ),
        ),
        if (storage.isPaid)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : () => _buyGb(0),
              child: const Text('Cancel storage'),
            ),
          ),
      ],
    );
  }

  Widget _chatBackupSection(
      BuildContext context, CloudSync sync, StorageStore storage) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(context, 'Chat backup'),
        Text(
          'Your chats are encrypted with a key only you hold before they ever '
          'leave the device. Lose the key and nobody — not even us — can '
          'recover the backup.',
          style: TextStyle(
              fontSize: 13, height: 1.35, color: AppColors.subtle(context)),
        ),
        const SizedBox(height: 14),
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

  /// The user's controls over the communal backup: back up now, automatic
  /// backup + how often, what it carries, and a way to wipe the cloud copy.
  Widget _backupOptionsSection(BuildContext context, CloudSync sync) {
    final prefs = BackupPrefs.instance;
    final scheme = Theme.of(context).colorScheme;
    final subtle = AppColors.subtle(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(context, 'Backup options'),
        Text(
          'Your servers, posts, follows and more back up to the cloud, '
          'encrypted. Chats are separate, above.',
          style: TextStyle(fontSize: 13, height: 1.35, color: subtle),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: sync.syncing
                    ? null
                    : () =>
                        _run(CloudSync.instance.syncNow, 'Backed up to the cloud.'),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('Back up now'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: sync.syncing
                    ? null
                    : () =>
                        _run(CloudSync.instance.restore, 'Restored from the cloud.'),
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('Restore'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          sync.lastSync == null
              ? 'Not backed up yet.'
              : 'Last backup: ${DateFormatter.callLabel(sync.lastSync!)}',
          style: TextStyle(fontSize: 12.5, color: subtle),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.autoBackup,
          onChanged: (v) => prefs.setAutoBackup(v),
          title: const Text('Automatic backup'),
          subtitle: const Text(
              'Back up changes as you make them, and on a schedule.'),
        ),
        if (prefs.autoBackup) ...[
          const SizedBox(height: 2),
          Text('HOW OFTEN',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: subtle)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final (label, value) in const [
                ('Daily', BackupInterval.daily),
                ('Weekly', BackupInterval.weekly),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: prefs.interval == value,
                  onSelected: (_) => prefs.setInterval(value),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Text('WHAT\'S INCLUDED',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: subtle)),
        for (final (key, label) in BackupPrefs.categories)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: prefs.includes(key),
            onChanged: (v) => prefs.setIncluded(key, v),
            title: Text(label),
          ),
        Text('Chats are never in this backup — they have their own, above.',
            style: TextStyle(fontSize: 12, color: subtle)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: sync.syncing
                ? null
                : () async {
                    final ok = await _confirm(
                      'Delete all cloud data?',
                      'Everything this account has in the cloud — the backup '
                          'above and your encrypted chat backup — is erased. '
                          'What is on this device stays. This cannot be undone.',
                    );
                    if (ok) {
                      await _run(CloudSync.instance.deleteCloudData,
                          'Cloud data deleted.');
                    }
                  },
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete all cloud data'),
          ),
        ),
      ],
    );
  }
}
