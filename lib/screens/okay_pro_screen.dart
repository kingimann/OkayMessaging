import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../payments/payment_service.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../widgets/app_dialogs.dart';

/// A place for people to support the developer with an optional tip.
///
/// The blurb below used to boast that the app carried no advertising, no
/// tracking and no subscriptions. That stopped being true: there are AdMob
/// banners on the two public surfaces, and cloud storage, Okay AI Pro,
/// creator subscriptions and paid servers are all subscriptions. Boasting
/// otherwise on the screen that asks for money is the worst possible place to
/// be caught out, so it now says what is actually the case — including that a
/// tip buys nothing, which is the honest pitch. A test pins the old sentence
/// out of this file, so do not quote it back in.
class OkayProScreen extends StatefulWidget {
  const OkayProScreen({super.key});

  @override
  State<OkayProScreen> createState() => _OkayProScreenState();
}

class _OkayProScreenState extends State<OkayProScreen> {
  /// Fixed tip products from the store (Apple/Google) — no arbitrary amounts,
  /// since in-app purchases are set prices.
  static const _tips = StorePurchases.tipProducts;

  // Default to the second tier (Snack).
  int _selected = 1;
  bool _sending = false;

  int get _amountCents =>
      StorePurchases.tipCentsFor(_tips[_selected].id, _tips[_selected].cents);
  // The store's real price for the chosen tip, in the buyer's own currency
  // (USD or CAD), falling back to a plain USD figure off-store.
  /// The chosen tip, as the store will charge it. A spinner cannot go in a
  /// button label, so while the store is still answering this says so — never
  /// a dash, and never the built-in cents.
  String get _amountLabel {
    final prices = StorePrices.instance;
    final id = _tips[_selected].id;
    if (prices.awaitingStore && prices.priceFor(id) == null) {
      return 'loading the price…';
    }
    return prices.money(_amountCents, productId: id);
  }

  /// The store answered and doesn't sell the chosen tip.
  bool get _unavailable =>
      StorePrices.instance.isUnavailable(_tips[_selected].id);

  @override
  void initState() {
    super.initState();
    // Prices are queried once at launch, and Apple's product metadata can lag
    // a price change made in App Store Connect — so re-ask on open, and
    // repaint whenever an answer lands (the launch query can also land after
    // this screen first builds, which used to leave the fallback on screen).
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

  bool _checking = false;

  /// Asks the App Store which tip products it will sell here and says so,
  /// per product — the answer to "I created them in App Store Connect but
  /// it says they're not on sale".
  Future<void> _checkStore() async {
    setState(() => _checking = true);
    final r = await StorePurchases.instance.checkTips();
    // The check just heard the store's current answer — let the visible
    // cards correct themselves from it too. Not `reachable`: this asked
    // about the four tips only, so it cannot say anything about whether the
    // other products are on sale.
    StorePrices.instance.absorb(r.onSale, currencies: r.currencies);
    if (!mounted) return;
    setState(() => _checking = false);
    final lines = [
      for (final t in _tips)
        '${t.emoji} ${t.label} — '
            '${r.onSale[t.id] == null ? 'not offered' : StorePrices.labelled(r.onSale[t.id]!, r.currencies[t.id])}',
    ];
    await showAppConfirmDialog(
      context,
      icon: Icons.storefront_outlined,
      title: 'What the App Store says',
      message: '${lines.join('\n')}\n\n'
          '${StorePurchases.tipsCheckVerdict(r)}',
      confirmLabel: 'Done',
      cancelLabel: null,
    );
  }

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!StorePurchases.instance.isSupported) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Tips are available in the iPhone app.')));
      return;
    }
    setState(() => _sending = true);
    try {
      final result = await StorePurchases.instance.tip(_tips[_selected].id);
      if (!mounted) return;
      setState(() => _sending = false);
      if (result.ok) {
        _thankYou();
      } else {
        // Says which of the several ways it ended, rather than calling all of
        // them a cancellation.
        messenger.showSnackBar(SnackBar(content: Text(result.message)));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(const SnackBar(
          content: Text('Payment couldn\'t be completed.')));
    }
  }

  void _thankYou() {
    showAppConfirmDialog(
      context,
      icon: Icons.favorite,
      title: 'Thank you! 💜',
      message: 'Your support genuinely helps keep OkayMessenger independent '
          'and private, and the core of it free for everyone.',
      confirmLabel: 'Done',
      cancelLabel: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final testMode = PaymentService.instance.testMode.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Support the developer')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // No gradient hero. A violet panel with a big heart on it is the
          // single most "generated app" thing here, and it is off-brand
          // besides: the app's accent is ink, not purple. What the screen has
          // to say is said in text, at reading size, with the qualifier the
          // App Store requires kept and the sales pitch dropped.
          Text('Tips are optional',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            'Messaging, calls, servers and the forum are free, and your '
            'messages are end-to-end encrypted. Cloud backup, Okay AI Pro and '
            'creator subscriptions cost money; the newsfeed and marketplace '
            'carry ads, and they are not personalised.',
            style: TextStyle(
                fontSize: 14, height: 1.45, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 10),
          Text(
            'A tip buys nothing and unlocks nothing.',
            style: TextStyle(
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface),
          ),
          const SizedBox(height: 24),
          Text('Amount',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          // A list, not a 2x2 grid of emoji cards. Four amounts is a choice,
          // and a choice reads as rows.
          for (var i = 0; i < _tips.length; i++)
            _AmountTile(
              label: _tips[i].label,
              amount: StorePrices.instance.money(
                  StorePurchases.tipCentsFor(_tips[i].id, _tips[i].cents),
                  productId: _tips[i].id),
              selected: _selected == i,
              onTap: () => setState(() => _selected = i),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              // A tip the store won't sell can't be sent, and the button
              // should say so rather than name a price nobody will charge.
              onPressed: (_sending || _unavailable) ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(
                      _unavailable
                          ? 'Not available on this store'
                          : 'Send $_amountLabel tip',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              testMode
                  ? 'Payments are in test mode — no real charge is made.'
                  // The amount above is what the App Store reported for this
                  // product, and its own sheet is what actually charges — the
                  // two can disagree for a while after a price change in App
                  // Store Connect, so the sheet gets the last word here
                  // rather than this screen pretending to.
                  : 'Billed by the App Store, which confirms the exact amount '
                      'before you pay. 100% optional.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), fontSize: 12),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: _checking ? null : _checkStore,
              child: Text(_checking
                  ? 'Asking the App Store…'
                  : 'Says it\'s not on sale? Check the store'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountTile extends StatelessWidget {
  final String label;
  final String amount;
  final bool selected;
  final VoidCallback onTap;
  const _AmountTile({
    required this.label,
    required this.amount,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The app's own accent, not a hardcoded violet. Selection is carried by a
    // border and a tick, not a tinted fill — a coloured wash behind a row is
    // decoration standing in for hierarchy.
    final accent = AppColors.accentOn(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? accent
                  : Theme.of(context).dividerColor.withValues(alpha: 0.6),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              Text(amount,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Icon(
                selected ? Icons.radio_button_checked : Icons.circle_outlined,
                size: 18,
                color: selected ? accent : AppColors.subtle(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
