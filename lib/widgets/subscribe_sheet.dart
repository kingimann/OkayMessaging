import 'package:flutter/material.dart';

import '../models/user.dart';
import '../state/pricing_store.dart';
import '../payments/purchase_outcome.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../state/creator_sub_store.dart';
import 'pass_billing_note.dart';

/// The bottom sheet that sells a creator subscription. Shows every tier the
/// creator offers, lets the reader pick one, and runs the monthly-pass
/// purchase for the chosen price. Returns true when a pass was bought (so the
/// caller can unlock the post it opened from). A creator with one tier gets a
/// one-line sheet; several tiers become a pick list.
Future<bool> showSubscribeSheet(
  BuildContext context, {
  required String handle,
  required String name,
  required List<SubscriptionTier> tiers,
}) async {
  // Nothing to sell, so the sheet never opens. Every caller already hides
  // its own Subscribe button; this is the backstop under all four of them,
  // so a fifth added later cannot put a purchase on screen.
  if (!StorePurchases.enabled) return false;
  final live = [for (final t in tiers) if (t.cents > 0) t];
  if (live.isEmpty) return false;
  final bought = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SubscribeSheet(handle: handle, name: name, tiers: live),
  );
  return bought ?? false;
}

/// The tier index a price maps to, or the closest one — the purchase is a
/// fixed-tier store product, so an odd price rounds to the nearest tier.
int tierForCents(int cents) {
  final tiers = PricingStore.instance.tierCents;
  final exact = tiers.indexOf(cents);
  if (exact != -1) return exact;
  var best = 0;
  var bestGap = (tiers[0] - cents).abs();
  for (var i = 1; i < tiers.length; i++) {
    final gap = (tiers[i] - cents).abs();
    if (gap < bestGap) {
      best = i;
      bestGap = gap;
    }
  }
  return best;
}

/// The price to show for a tier, with the period it buys: the App Store's
/// real localized price for the tier's product (so a Canadian buyer sees CAD,
/// and it matches the charge), falling back to a plain USD figure where there
/// is no store to ask.
///
/// Composed by [StorePrices] rather than by hand, so a tier the store will not
/// sell reads "Unavailable" instead of "Unavailable for 30 days" — a sentence
/// that names a month-long outage rather than a product on permanent sale
/// that App Store Connect is not offering.
String _moneyPer(int cents, {String joiner = 'for'}) =>
    StorePrices.instance.pricedPeriod(cents,
        productId: StorePurchases.creatorSubProductId(tierForCents(cents)),
        joiner: joiner);

/// Whether the App Store has answered and does not sell this tier's product.
///
/// A live Subscribe button in front of one leads to a purchase that can only
/// fail, so it is dead here for the same reason the Store screen's own cards
/// go dead — and false everywhere there is no real store to be refused by
/// (web, payments-test mode, the suite), so nothing off-device changes.
bool _blocked(int cents) => StorePrices.instance
    .isUnavailable(StorePurchases.creatorSubProductId(tierForCents(cents)));

class _SubscribeSheet extends StatefulWidget {
  final String handle;
  final String name;
  final List<SubscriptionTier> tiers;
  const _SubscribeSheet(
      {required this.handle, required this.name, required this.tiers});

  @override
  State<_SubscribeSheet> createState() => _SubscribeSheetState();
}

class _SubscribeSheetState extends State<_SubscribeSheet> {
  bool _busy = false;
  // Default to the cheapest tier — the least-committing way in.
  late int _selected = _cheapestIndex();

  @override
  void initState() {
    super.initState();
    // Re-ask the store on open and repaint when it answers, so the sheet
    // never sells on a stale launch-time price.
    StorePrices.instance.addListener(_onPrices);
    StorePrices.instance.load();
  }

  @override
  void dispose() {
    StorePrices.instance.removeListener(_onPrices);
    super.dispose();
  }

  void _onPrices() {
    if (mounted) setState(() {});
  }

  int _cheapestIndex() {
    var best = 0;
    for (var i = 1; i < widget.tiers.length; i++) {
      if (widget.tiers[i].cents < widget.tiers[best].cents) best = i;
    }
    return best;
  }

  SubscriptionTier get _tier => widget.tiers[_selected];

  Future<void> _subscribe() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await CreatorSubStore.instance
        .subscribe(widget.handle, tierForCents(_tier.cents));
    if (!mounted) return;
    if (result.ok) {
      navigator.pop(true);
      messenger.showSnackBar(
          SnackBar(content: Text('Subscribed to ${widget.name}. Enjoy.')));
    } else {
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(result.outcome == PurchaseOutcome.notOffered
              ? 'Subscriptions aren\'t available here yet.'
              : 'That didn\'t go through — nothing was charged.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final multi = widget.tiers.length > 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.workspace_premium, size: 38, color: scheme.primary),
          const SizedBox(height: 8),
          Text('Subscribe to ${widget.name}',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (widget.handle.isNotEmpty)
            Text('@${widget.handle}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          if (multi)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Choose a tier',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ),
          for (var i = 0; i < widget.tiers.length; i++) ...[
            const SizedBox(height: 8),
            _TierCard(
              tier: widget.tiers[i],
              selected: i == _selected,
              selectable: multi,
              onTap: () => setState(() => _selected = i),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Every tier unlocks the same subscribers-only posts while it\'s '
            'active.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          const PassBillingNote(),
          const SizedBox(height: 14),
          if (_blocked(_tier.cents)) ...[
            Text(
              'The App Store is not offering this on this device right now, '
              'so it can\'t be bought here yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(
            onPressed: (_busy || _blocked(_tier.cents)) ? null : _subscribe,
            child: Text(_blocked(_tier.cents)
                ? StorePrices.unavailableLabel
                : _busy
                    ? 'One moment…'
                    : 'Subscribe · ${_moneyPer(_tier.cents)}'),
          ),
        ],
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  final SubscriptionTier tier;
  final bool selected;
  final bool selectable;
  final VoidCallback onTap;
  const _TierCard(
      {required this.tier,
      required this.selected,
      required this.selectable,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: selectable ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected
              ? scheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectable) ...[
              Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tier.name.isEmpty ? 'Subscriber' : tier.name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  if (tier.perks.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(tier.perks.trim(),
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.3,
                            color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(_moneyPer(tier.cents, joiner: '·'),
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary)),
          ],
        ),
      ),
    );
  }
}
