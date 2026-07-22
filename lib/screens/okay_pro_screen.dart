import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class _Plan {
  final String name;
  final String price;
  final String cadence;
  final List<String> features;
  final bool highlighted;
  const _Plan(this.name, this.price, this.cadence, this.features,
      {this.highlighted = false});
}

const _plans = [
  _Plan('Free', r'$0', 'forever', [
    'Private, end-to-end encrypted chats',
    'Voice & video calls',
    'Communities & channels',
    'In-chat payments (small app fee)',
  ]),
  _Plan('Pro', r'$4.99', 'per month', [
    'Everything in Free',
    'Larger file transfers',
    'Custom chat themes & accent colors',
    'Unlimited pinned messages',
    'Lower payment fee',
  ], highlighted: true),
  _Plan('Business', r'$9', 'per user / month', [
    'Everything in Pro',
    'Team admin controls & roles',
    'Priority call reliability (TURN)',
    'Bulk member management',
    'Priority support',
  ]),
];

/// The monetization / upgrade screen for the freemium and Business tiers.
/// Billing itself is handled by Stripe Billing (or App Store / Play in-app
/// purchase) — wire it up before shipping; this screen presents the offer.
class OkayProScreen extends StatelessWidget {
  const OkayProScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Okay Pro')),
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
                Icon(Icons.workspace_premium, color: Colors.white, size: 30),
                SizedBox(height: 10),
                Text('Do more with Okay Pro',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 6),
                Text(
                  'Support a private, no-tracking messenger and unlock power '
                  'features for you or your team.',
                  style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          for (final p in _plans) _PlanCard(plan: p),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Prices in CAD. Cancel anytime. Billed via the App Store, '
              'Google Play, or Stripe.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final _Plan plan;
  const _PlanCard({required this.plan});

  @override
  Widget build(BuildContext context) {
    final accent = plan.highlighted ? const Color(0xFF7A5CFF) : Colors.grey;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: plan.highlighted
            ? Border.all(color: const Color(0xFF7A5CFF), width: 2)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(plan.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              if (plan.highlighted) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7A5CFF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('POPULAR',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
              ],
              const Spacer(),
              Text(plan.price,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800)),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(plan.cadence,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ),
          const SizedBox(height: 12),
          for (final f in plan.features)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(f, style: const TextStyle(fontSize: 14))),
                ],
              ),
            ),
          if (plan.name != 'Free') ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: plan.highlighted
                      ? const Color(0xFF7A5CFF)
                      : AppColors.tealGreenDark,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('${plan.name} checkout coming soon')),
                ),
                child: Text('Choose ${plan.name}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
