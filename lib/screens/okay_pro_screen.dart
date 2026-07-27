import 'package:flutter/material.dart';

import '../payments/payment_service.dart';
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
  /// Preset tip amounts in cents.
  static const _presets = [
    (300, '☕', 'Coffee'),
    (500, '🍩', 'Snack'),
    (1000, '🍕', 'Lunch'),
    (2500, '🎉', 'Generous'),
  ];

  int _amountCents = 500;
  bool _sending = false;

  Future<void> _customAmount() async {
    final controller = TextEditingController(
        text: (_amountCents / 100).toStringAsFixed(0));
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom amount'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: r'$',
            hintText: '5',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final dollars = double.tryParse(controller.text.trim()) ?? 0;
              Navigator.pop(dialogContext, (dollars * 100).round());
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (result != null && result >= 100) {
      setState(() => _amountCents = result);
    }
  }

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      final ok = await PaymentService.instance.tip(amountCents: _amountCents);
      if (!mounted) return;
      setState(() => _sending = false);
      if (ok) _thankYou();
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(
        content: Text(e.code == 'not_configured'
            ? 'Tips aren\'t set up yet — try again soon.'
            : 'Payment couldn\'t be completed.'),
      ));
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


  String get _amountLabel => '\$${(_amountCents / 100).toStringAsFixed(2)}';

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
              for (final (cents, emoji, label) in _presets)
                _AmountTile(
                  emoji: emoji,
                  label: label,
                  amount: '\$${(cents / 100).toStringAsFixed(0)}',
                  selected: _amountCents == cents,
                  onTap: () => setState(() => _amountCents = cents),
                ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _customAmount,
            icon: const Icon(Icons.tune),
            label: Text(_presets.every((p) => p.$1 != _amountCents)
                ? 'Custom · $_amountLabel'
                : 'Custom amount'),
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
                  : 'Paid securely in-app. Amounts in CAD. 100% optional.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
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
                          fontSize: 12, color: Colors.grey.shade600)),
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
