import 'package:flutter/material.dart';

import '../payments/iap_entitlement.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../state/ai_assistant.dart';
import '../state/ai_pass_store.dart';
import '../state/storage_store.dart';
import '../theme/app_theme.dart';
import 'package:intl/intl.dart';
import 'cloud_sync_screen.dart';
import 'okay_pro_screen.dart';

/// Everything the app sells, in one place.
///
/// These were scattered by accident of when each was built: tips under
/// Settings, storage on its own screen, the AI pass behind the assistant's
/// overflow menu, creator subscriptions on a profile and paid memberships on
/// an invite card. Somebody wanting to pay for something had to already know
/// where it lived.
///
/// Two of them cannot live here and the page says so rather than pretending:
/// a creator subscription is bought from the creator (there is no catalogue of
/// people to pick from) and a server membership from that server's invite.
/// Listing them with a dead button would be worse than explaining where they
/// are.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

/// A plain calendar day — these are renewal dates, not timestamps.
String _day(DateTime d) => DateFormat.yMMMd().format(d);

class _StoreScreenState extends State<StoreScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The prices shown here are the store's own, so ask for them on open —
    // the launch answer can be stale after a change in App Store Connect.
    StorePrices.instance.load();
  }

  Future<void> _buyAiPass() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await AiPassStore.instance.subscribe();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
        content: Text(result.ok
            ? 'Okay AI Pro is active. Enjoy.'
            : result.message)));
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await StorePurchases.instance.restorePurchases();
      final e = await IapEntitlement.instance.refresh();
      if (e != null) {
        StorageStore.instance.applyServerEntitlement(
            active: e.active, gb: e.gb, expiresAt: e.expiresAt);
      }
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content: Text('Checked your Apple ID for past purchases.')));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t reach the App Store.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Store')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          StorePrices.instance,
          AiPassStore.instance,
          StorageStore.instance,
        ]),
        builder: (context, _) {
          // Pull to ask the store again. Apple's own product metadata can lag
          // a price change in App Store Connect, and when it does there is
          // nothing in the app that can correct it — so the honest thing is a
          // way to re-ask on demand rather than waiting out a cache nobody
          // can see.
          return RefreshIndicator(
            onRefresh: _refreshPrices,
            child: _body(context, subtle),
          );
        },
      ),
    );
  }

  /// Re-asks the store, then SAYS what happened.
  ///
  /// A bare pull-to-refresh is invisible when nothing changes — the spinner
  /// turns, the same figures come back, and there is no way to tell whether
  /// the app looked or not. That is useless for the one question this exists
  /// to answer: "I raised the price in App Store Connect, has it landed?"
  /// So the three outcomes are named, including the two that are not
  /// success.
  Future<void> _refreshPrices() async {
    Map<String, String?> snapshot() => {
          for (final id in StorePrices.allIds())
            id: StorePrices.instance.priceFor(id)
        };
    final before = snapshot();
    await StorePrices.instance.load();
    if (!mounted) return;
    final after = snapshot();
    final changed =
        after.entries.where((e) => before[e.key] != e.value).length;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(changed > 0
          ? (changed == 1 ? '1 price updated' : '$changed prices updated')
          : StorePrices.instance.answered
              // Apple answered and its answer has not moved. Worth saying
              // outright: its product metadata can lag a price change in App
              // Store Connect by hours, and nothing here can hurry it.
              ? 'The App Store still reports the same prices.'
              : 'The App Store did not answer.'),
    ));
  }

  Widget _body(BuildContext context, Color subtle) {
    final ai = AiPassStore.instance;
    final storage = StorageStore.instance;
    final aiPrice =
        StorePrices.instance.priceFor(StorePurchases.aiPassProductId);
    final aiUnavailable =
        StorePrices.instance.isUnavailable(StorePurchases.aiPassProductId);
    return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text('Chats, calls, servers and the forum are free.',
                  style: TextStyle(fontSize: 13.5, height: 1.45, color: subtle)),
              const SizedBox(height: 20),

              _StoreCard(
                icon: Icons.auto_awesome,
                title: 'Okay AI Pro',
                blurb: 'Unlimited messages for 30 days. '
                    '${AiAssistant.freePerDay} a day without it.',
                // Never a made-up amount: the store's price, or nothing.
                price: aiUnavailable
                    ? StorePrices.unavailableLabel
                    : (aiPrice ?? ''),
                active: ai.active,
                activeNote: ai.activeUntil == null
                    ? null
                    : 'Active until ${_day(ai.activeUntil!)}',
                actionLabel: ai.active ? 'Extend by 30 days' : 'Get Okay AI Pro',
                onTap: (_busy || aiUnavailable) ? null : _buyAiPass,
              ),

              _StoreCard(
                icon: Icons.cloud_outlined,
                title: 'Cloud storage',
                blurb: 'Encrypted backup, under a key only you hold. '
                    'Monthly, by the gigabyte.',
                price: '',
                active: storage.isPaid,
                activeNote: storage.isPaid
                    ? '${storage.selectedGb} GB'
                        '${storage.activeUntil == null ? '' : ' · renews '
                            '${_day(storage.activeUntil!)}'}'
                    : null,
                actionLabel: storage.isPaid ? 'Manage plan' : 'See plans',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
                ),
              ),

              _StoreCard(
                icon: Icons.favorite_outline,
                title: 'Support the developer',
                blurb: 'A one-off tip. Buys nothing, unlocks nothing.',
                price: '',
                actionLabel: 'Leave a tip',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OkayProScreen()),
                ),
              ),

              const SizedBox(height: 8),
              Text('BOUGHT SOMEWHERE ELSE',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: subtle)),
              const SizedBox(height: 8),
              // Not buttons. Both are bought from a particular person or
              // server, so a button here would have nothing to act on.
              const _WhereCard(
                icon: Icons.workspace_premium_outlined,
                title: 'Creator subscriptions',
                blurb: 'Bought on a creator\'s profile. One pass each.',
              ),
              const _WhereCard(
                icon: Icons.groups_outlined,
                title: 'Paid server membership',
                blurb: 'Bought from the server\'s invite.',
              ),

              const SizedBox(height: 18),
              Center(
                child: TextButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('Restore purchases'),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Billed by the App Store. Cancel in Settings → your name → '
                  'Subscriptions.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.4, color: subtle),
                ),
              ),
            ],
    );
  }
}

/// One purchasable thing.
class _StoreCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String blurb;

  /// The store's own price, or empty when this card only opens another
  /// screen (storage has a ladder; a tip has four amounts).
  final String price;
  final bool active;
  final String? activeNote;
  final String actionLabel;
  final VoidCallback? onTap;

  const _StoreCard({
    required this.icon,
    required this.title,
    required this.blurb,
    required this.price,
    required this.actionLabel,
    required this.onTap,
    this.active = false,
    this.activeNote,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtle = AppColors.subtle(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: active
            ? Border.all(color: const Color(0xFF12B76A), width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (price.isNotEmpty)
                Text(price,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(blurb,
              style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle)),
          if (active && activeNote != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF12B76A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(activeNote!,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF12B76A))),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onTap,
              child: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// Something purchasable that is NOT bought here, and where it is instead.
class _WhereCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String blurb;
  const _WhereCard({
    required this.icon,
    required this.title,
    required this.blurb,
  });

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: subtle),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(blurb,
                    style:
                        TextStyle(fontSize: 12.5, height: 1.4, color: subtle)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
