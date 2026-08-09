import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../payments/payment_service.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../widgets/app_dialogs.dart';

/// A place for people to support the developer with an optional tip. There are
/// no paid tiers — OkayMessenger is free, private, and has no ads, tracking, or
/// subscriptions; tips are entirely optional and just help keep it running.
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

  int get _amountCents => _tips[_selected].cents;
  // The store's real price for the chosen tip, in the buyer's own currency
  // (USD or CAD), falling back to a plain USD figure off-store.
  String get _amountLabel => StorePrices.instance
      .money(_amountCents, productId: _tips[_selected].id);

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
    // cards correct themselves from it too.
    StorePrices.instance.absorb(r.onSale);
    if (!mounted) return;
    setState(() => _checking = false);
    final lines = [
      for (final t in _tips)
        '${t.emoji} ${t.label} — ${r.onSale[t.id] ?? 'not offered'}',
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
      message: 'Your support genuinely helps keep OkayMessenger independent, '
          'private, and free for everyone.',
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF7A5CFF), Color(0xFF5B3CE0)],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.favorite, color: Colors.white, size: 30),
                SizedBox(height: 10),
                Text('Support OkayMessenger',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 6),
                Text(
                  'OkayMessenger is free, private, and has no ads, tracking, or '
                  'subscriptions. If you\'d like, you can leave a tip to help '
                  'keep it running. Totally optional — thank you either way.',
                  style: TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text('Choose an amount',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.4,
            children: [
              for (var i = 0; i < _tips.length; i++)
                _AmountTile(
                  emoji: _tips[i].emoji,
                  label: _tips[i].label,
                  amount: StorePrices.instance
                      .money(_tips[i].cents, productId: _tips[i].id),
                  selected: _selected == i,
                  onTap: () => setState(() => _selected = i),
                ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7A5CFF),
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text('Send $_amountLabel tip',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              testMode
                  ? 'Payments are in test mode — no real charge is made.'
                  : 'Billed by the App Store. 100% optional.',
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
  final String emoji;
  final String label;
  final String amount;
  final bool selected;
  final VoidCallback onTap;
  const _AmountTile({
    required this.emoji,
    required this.label,
    required this.amount,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7A5CFF);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(amount,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800)),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.subtle(context))),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: accent, size: 20),
          ],
        ),
      ),
    );
  }
}
