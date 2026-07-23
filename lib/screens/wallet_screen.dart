import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../payments/payment_service.dart';
import '../theme/app_theme.dart';

/// The receiver's wallet: set up payments (Stripe Express KYC), see the
/// connected-account balance, and track automatic payouts to the bank. The
/// platform never holds funds — money sits in the user's Stripe balance and
/// Stripe auto-pays it out.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Future<WalletStatus>? _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (PaymentService.instance.isConfigured) _future = _load();
    PaymentService.instance.testMode.addListener(_onTestMode);
  }

  @override
  void dispose() {
    PaymentService.instance.testMode.removeListener(_onTestMode);
    super.dispose();
  }

  void _onTestMode() {
    if (!mounted) return;
    setState(() =>
        _future = PaymentService.instance.isConfigured ? _load() : null);
  }

  Future<WalletStatus> _load() => PaymentService.instance.status();

  void _refresh() => setState(() => _future = _load());

  Future<void> _startOnboarding() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await PaymentService.instance.onboardingUrl();
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.inAppBrowserView);
      if (!ok) {
        await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not start setup: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          if (PaymentService.instance.isConfigured)
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _busy ? null : _refresh),
        ],
      ),
      body: !PaymentService.instance.isConfigured
          ? const _NotConfigured()
          : FutureBuilder<WalletStatus>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _error(snap.error.toString());
                }
                final s = snap.data!;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (PaymentService.instance.testMode.value)
                      const _TestModeBanner(),
                    _BalanceCard(status: s),
                    const SizedBox(height: 16),
                    if (!s.canReceive)
                      _OnboardCard(busy: _busy, onStart: _startOnboarding)
                    else
                      _PayoutCard(status: s),
                    const SizedBox(height: 16),
                    const _TestModeTile(),
                    const SizedBox(height: 8),
                    const _InfoFooter(),
                  ],
                );
              },
            ),
    );
  }

  Widget _error(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text('Couldn\'t load your wallet',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 6),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

class _BalanceCard extends StatelessWidget {
  final WalletStatus status;
  const _BalanceCard({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF12B76A), Color(0xFF0B7C4C)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Available balance',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(status.money(status.availableCents),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.w800)),
          if (status.pendingCents > 0) ...[
            const SizedBox(height: 4),
            Text('${status.money(status.pendingCents)} pending',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
          const SizedBox(height: 10),
          Text(status.currency.toUpperCase(),
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ],
      ),
    );
  }
}

class _OnboardCard extends StatelessWidget {
  final bool busy;
  final VoidCallback onStart;
  const _OnboardCard({required this.busy, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.account_balance, color: Color(0xFF12B76A)),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Set up payments to receive money',
                      style: TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'A quick, secure identity check (handled by Stripe) lets you '
              'receive money and have it auto-deposited to your Canadian bank.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13.5),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF12B76A),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: busy ? null : onStart,
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Set up with Stripe'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayoutCard extends StatelessWidget {
  final WalletStatus status;
  const _PayoutCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final payout = status.payoutStatus;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined,
                color: Color(0xFF12B76A)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cash out',
                      style: TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    payout == null
                        ? 'Your balance is automatically paid out to your bank.'
                        : 'Latest payout: $payout'
                            '${status.payoutAmountCents != null ? ' · ${status.money(status.payoutAmountCents!)}' : ''}',
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.check_circle, color: Color(0xFF12B76A)),
          ],
        ),
      ),
    );
  }
}

class _InfoFooter extends StatelessWidget {
  const _InfoFooter();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 15, color: Colors.grey.shade500),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Payments are processed by Stripe. Okay Messaging never holds your '
            'funds or sees your card details, and your messages stay private.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.payments_outlined,
                size: 48, color: AppColors.tealGreenDark),
            const SizedBox(height: 14),
            Text('Payments aren\'t set up yet',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text(
              'Add your Stripe publishable key and deploy the payment Edge '
              'Functions to enable in-chat payments. See PAYMENTS.md.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => PaymentService.instance.setTestMode(true),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Try test mode'),
            ),
            const SizedBox(height: 6),
            Text('Simulates payments — no real money moves.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// A banner shown across payment surfaces while sandbox mode is on.
class _TestModeBanner extends StatelessWidget {
  const _TestModeBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9A825).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFFF9A825).withValues(alpha: 0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.science_outlined, color: Color(0xFFF57F17)),
          SizedBox(width: 10),
          Expanded(
            child: Text('Test mode — payments are simulated, no real money '
                'moves.'),
          ),
        ],
      ),
    );
  }
}

/// Toggles sandbox mode on/off.
class _TestModeTile extends StatelessWidget {
  const _TestModeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PaymentService.instance.testMode,
      builder: (context, on, _) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
        ),
        child: SwitchListTile(
          secondary: const Icon(Icons.science_outlined),
          title: const Text('Test mode'),
          subtitle: Text(on
              ? 'Payments are simulated'
              : 'Simulate payments without Stripe'),
          value: on,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(14))),
          onChanged: PaymentService.instance.setTestMode,
        ),
      ),
    );
  }
}
