import 'package:flutter/material.dart';

import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../state/pricing_store.dart';
import '../state/promotion_store.dart';
import '../theme/app_theme.dart';
import 'phone_gate.dart';

/// "Promote this post" — the app's own ad inventory, sold to its own users.
///
/// Four tiers, and what they buy is DAYS, never a better slot. There is
/// deliberately no auction: an auction is a ranking somebody can outbid, which
/// turns a timeline into a market for attention and gives the serving side a
/// reason to read what was spent. Here the serving side reads only whether a
/// placement is running.
Future<void> showPromoteSheet(BuildContext context, String postId) async {
  // Nothing on sale, so the sheet never opens — the backstop under the ⋮ row
  // that is already hidden.
  if (!StorePurchases.enabled) return;
  // Buying reach needs an account that answers for what it promotes, the same
  // rule every other public write follows.
  if (postNeedsPhone(context, what: 'Promoting a post')) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PromoteSheet(postId: postId),
  );
}

class _PromoteSheet extends StatefulWidget {
  const _PromoteSheet({required this.postId});
  final String postId;

  @override
  State<_PromoteSheet> createState() => _PromoteSheetState();
}

class _PromoteSheetState extends State<_PromoteSheet> {
  int _tier = 1;
  bool _busy = false;

  Future<void> _buy() async {
    setState(() => _busy = true);
    final until =
        await PromotionStore.instance.promote(widget.postId, tier: _tier);
    if (!mounted) return;
    setState(() => _busy = false);
    final store = PromotionStore.instance;
    if (until == null) {
      // Silence means the buyer cancelled — nothing to report. Anything else
      // carries the server's own word for it rather than one sentence for
      // every failure.
      if (store.lastError.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(store.lastError)));
      }
      return;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Promoted. It carries a "Promoted" label while it '
            'runs.')));
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Promote this post',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                'It is carried higher up the newsfeed for as long as you buy, '
                'and wears a "Promoted" label the whole time.',
                style: TextStyle(fontSize: 12.5, color: subtle)),
            const SizedBox(height: 16),
            for (var i = 0; i < StorePurchases.promotionDays.length; i++)
              RadioGroupTile(
                selected: _tier == i,
                title: '${StorePurchases.promotionDays[i]} days',
                trailing: StorePrices.instance.money(
                    PricingStore.instance.tierCents[i],
                    productId: StorePurchases.promotionProductId(i)),
                onTap: _busy ? null : () => setState(() => _tier = i),
              ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _busy ? null : _buy,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Promote for '
                      '${StorePurchases.promotionDays[_tier]} days'),
            ),
            const SizedBox(height: 10),
            // Three things that are true and easy to assume otherwise. A paid
            // placement buys REACH, not exemption: the post is screened like
            // any other, and a sanctioned account cannot buy its way back on.
            Text(
                'A one-time App Store charge — it does not renew. Promoting '
                'moves a post up the newsfeed; it does not change who may '
                'reply, and it does not exempt the post from moderation. '
                'Money buys days, never a better position than somebody who '
                'paid the same.',
                style: TextStyle(fontSize: 11.5, color: subtle)),
          ],
        ),
      ),
    );
  }
}

/// A plain radio row — `RadioListTile`'s group API is deprecated in this
/// Flutter, the same call `form_fill_screen.dart` already made.
class RadioGroupTile extends StatelessWidget {
  const RadioGroupTile({
    super.key,
    required this.selected,
    required this.title,
    required this.trailing,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? AppColors.accentOn(context) : null),
        title: Text(title),
        trailing: Text(trailing,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        onTap: onTap,
      );
}
