import 'package:flutter/material.dart';

import '../models/user.dart';
import '../payments/purchase_outcome.dart';
import '../state/creator_sub_store.dart';

/// The bottom sheet that sells a creator subscription: the price, what it is,
/// and a button that runs the monthly-pass purchase. Returns true when the
/// pass was bought (so the caller can unlock the post it was opened from).
Future<bool> showSubscribeSheet(
  BuildContext context, {
  required String handle,
  required String name,
  required int cents,
  String pitch = '',
}) async {
  final bought = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SubscribeSheet(
      handle: handle,
      name: name,
      cents: cents,
      pitch: pitch,
    ),
  );
  return bought ?? false;
}

/// The tier index a price maps to, or the closest one — the purchase is a
/// fixed-tier store product, so an odd price rounds to the nearest tier.
int tierForCents(int cents) {
  const tiers = AppUser.subscriptionTiersCents;
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

class _SubscribeSheet extends StatefulWidget {
  final String handle;
  final String name;
  final int cents;
  final String pitch;
  const _SubscribeSheet({
    required this.handle,
    required this.name,
    required this.cents,
    required this.pitch,
  });

  @override
  State<_SubscribeSheet> createState() => _SubscribeSheetState();
}

class _SubscribeSheetState extends State<_SubscribeSheet> {
  bool _busy = false;

  String get _price => '\$${(widget.cents / 100).toStringAsFixed(2)}';

  Future<void> _subscribe() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await CreatorSubStore.instance
        .subscribe(widget.handle, tierForCents(widget.cents));
    if (!mounted) return;
    if (result.ok) {
      navigator.pop(true);
      messenger.showSnackBar(SnackBar(
          content: Text('Subscribed to ${widget.name}. Enjoy.')));
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
          22, 4, 22, 22 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.workspace_premium, size: 40, color: scheme.primary),
          const SizedBox(height: 10),
          Text('Subscribe to ${widget.name}',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (widget.handle.isNotEmpty)
            Text('@${widget.handle}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          if (widget.pitch.trim().isNotEmpty) ...[
            Text(widget.pitch.trim(),
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.35)),
            const SizedBox(height: 14),
          ],
          Text('$_price / month',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary)),
          const SizedBox(height: 4),
          Text(
            'A monthly pass, billed through the App Store. It unlocks every '
            'subscribers-only post from ${widget.name} while it\'s active.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : _subscribe,
            child: Text(_busy ? 'One moment…' : 'Subscribe · $_price/mo'),
          ),
        ],
      ),
    );
  }
}
