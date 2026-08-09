import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../state/pricing_store.dart';
import '../theme/app_theme.dart';

/// The owner's price editor: the figures the APP assumes, published to every
/// device without shipping a build.
///
/// The banner at the top is the honest frame, and it is not decoration — what
/// is edited here is NOT what anybody is charged. Apple charges what the SKU
/// says in App Store Connect, and every purchase surface shows StoreKit's own
/// localized price whenever it has one. These numbers fill in only where there
/// is no store price to show, and set the tier ladder a creator picks from.
class PricingEditorScreen extends StatefulWidget {
  const PricingEditorScreen({super.key});

  @override
  State<PricingEditorScreen> createState() => _PricingEditorScreenState();
}

class _PricingEditorScreenState extends State<PricingEditorScreen> {
  late final TextEditingController _perGb = TextEditingController(
      text: PricingStore.instance.storagePerGbCents.toString());
  late final List<TextEditingController> _tiers = [
    for (final c in PricingStore.instance.tierCents)
      TextEditingController(text: c.toString())
  ];
  late final Map<String, TextEditingController> _tips = {
    for (final t in StorePurchases.tipProducts)
      t.id: TextEditingController(
          text: StorePurchases.tipCentsFor(t.id, t.cents).toString())
  };

  bool _busy = false;

  @override
  void dispose() {
    _perGb.dispose();
    for (final c in _tiers) {
      c.dispose();
    }
    for (final c in _tips.values) {
      c.dispose();
    }
    super.dispose();
  }

  int _read(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  /// Why a set of values can't be published, or null when it can. The tier
  /// ladder must rise: a level priced below the one under it is the App Store
  /// Connect mistake this surface exists to keep out of the app.
  String? _problem() {
    if (_read(_perGb) <= 0 || _read(_perGb) > 500) {
      return 'Storage per GB must be between 1¢ and 500¢.';
    }
    final tiers = [for (final c in _tiers) _read(c)];
    if (tiers.any((v) => v <= 0)) return 'Every tier needs a price.';
    for (var i = 1; i < tiers.length; i++) {
      if (tiers[i] <= tiers[i - 1]) {
        return 'Tiers must get more expensive going down the list.';
      }
    }
    if (_tips.values.any((c) => _read(c) <= 0)) {
      return 'Every tip needs a price.';
    }
    return null;
  }

  Future<void> _publish() async {
    final problem = _problem();
    final messenger = ScaffoldMessenger.of(context);
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _busy = true);
    final ok = await PricingStore.instance.publish({
      'storagePerGbCents': _read(_perGb),
      'tierCents': [for (final c in _tiers) _read(c)],
      'tipCents': {
        for (final e in _tips.entries) e.key: _read(e.value),
      },
    });
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? 'Published. Every device picks these up on next launch.'
            : 'Couldn\'t publish — run docs/app_pricing.sql and paste the '
                'pricing-set function first.')));
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Prices')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              'These are the prices the APP assumes — not what anyone is '
              'charged. Apple charges whatever the product says in App Store '
              'Connect, and the app always shows the store\'s own price when '
              'it has one. What you set here shows only where there is no '
              'store price (the web app, test mode, the moment before the '
              'store answers) and sets the tier levels a creator picks from.\n\n'
              'To change what people actually pay, change the price in App '
              'Store Connect. That needs no build and no change here.',
              style: TextStyle(fontSize: 13, height: 1.45, color: subtle),
            ),
          ),
          const SizedBox(height: 20),
          Text('CLOUD STORAGE',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: subtle)),
          const SizedBox(height: 8),
          _CentsField(
            controller: _perGb,
            label: 'Per GB, per month (cents)',
            help: 'The whole ladder is built from this, rounded up to the '
                'next \$N.99. Break-even is 10¢/GB.',
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
            'Ladder: ${[
              for (final gb in [10, 50, 100])
                '$gb GB ${StorePrices.usd((gb * _read(_perGb) / 100).ceil() * 100 - 1)}'
            ].join(' · ')}',
            style: TextStyle(fontSize: 12.5, color: subtle),
          ),
          const SizedBox(height: 22),
          Text('SUBSCRIPTION TIERS',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: subtle)),
          const SizedBox(height: 4),
          Text(
            'The four levels a creator or paid server picks from. Each maps to '
            'one of the four IAP products, so there are always four and they '
            'must rise.',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: subtle),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _tiers.length; i++) ...[
            _CentsField(
              controller: _tiers[i],
              label: 'Tier ${i + 1} (cents)',
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 14),
          Text('DEVELOPER TIPS',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: subtle)),
          const SizedBox(height: 8),
          for (final t in StorePurchases.tipProducts) ...[
            _CentsField(
              controller: _tips[t.id]!,
              label: '${t.emoji} ${t.label} (cents)',
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 10),
          if (_problem() != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_problem()!,
                  style: TextStyle(color: scheme.error, fontSize: 13)),
            ),
          FilledButton(
            onPressed: _busy ? null : _publish,
            child: Text(_busy ? 'Publishing…' : 'Publish to everyone'),
          ),
        ],
      ),
    );
  }
}

class _CentsField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? help;
  final VoidCallback onChanged;
  const _CentsField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.help,
  });

  @override
  Widget build(BuildContext context) {
    final cents = int.tryParse(controller.text.trim()) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            // Cents are what the code stores; the dollars are for the human.
            suffixText: cents > 0 ? StorePrices.usd(cents) : null,
          ),
        ),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(help!,
                style: TextStyle(
                    fontSize: 12, color: AppColors.subtle(context))),
          ),
      ],
    );
  }
}
