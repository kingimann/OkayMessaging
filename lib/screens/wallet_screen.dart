import 'package:flutter/material.dart';
import '../state/parental_controls.dart';
import '../widgets/parental_gate.dart';
import '../widgets/phone_gate.dart';

import '../payments/payment_service.dart';
import '../payments/storage_economics.dart';
import 'add_debit_card_screen.dart';
import 'change_bank_screen.dart';
import 'payment_controls_screen.dart';
import 'native_onboarding_screen.dart';
import 'payment_diagnostics_screen.dart';
import 'payment_history_screen.dart';
import 'receive_money_screen.dart';
import '../widgets/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/verified_gate.dart';

/// The receiver's wallet: set up payments (Stripe Express KYC), see the
/// connected-account balance, and track automatic payouts to the bank. The
/// platform never holds funds — money sits in the user's Stripe balance and
/// Stripe auto-pays it out.
/// Tells a would-be recipient what they are taking on before they onboard.
///
/// Receiving money here means being the merchant of record: payments land in
/// their own Stripe account, and a chargeback comes back out of it. That is
/// the trade for the platform never holding anyone's money, and it belongs
/// before sign-up rather than at their first dispute.
///
/// Returns true when they accept.
Future<bool> showRecipientLiabilityNotice(BuildContext context) =>
    showAppConfirmDialog(
      context,
      icon: Icons.account_balance_outlined,
      title: 'Before you set up payments',
      message: 'Money people send you goes straight into your own Stripe '
          'account — we never hold it.\n\n'
          'That also means the payment is yours: Stripe\'s processing fee '
          'comes out of it, and if a sender reverses a payment through their '
          'bank, the amount comes back out of your account. We ban anyone who '
          'does that, but the money is still yours to lose.',
      confirmLabel: 'I understand',
      cancelLabel: 'Not now',
    );

class WalletScreen extends StatefulWidget {
  /// A load failure's raw code, translated into the thing to actually do.
  /// Pure and static so a test can pin every mapping — "Couldn't load your
  /// wallet" over a bare code was reported as "Wallet doesn't load", with
  /// nothing on screen saying whether to retry, re-sign-in, or report it.
  static String errorAdvice(String code) {
    final c = code.toLowerCase();
    if (c.contains('jwt') ||
        c.contains('authorization') ||
        c.contains('401') ||
        c.contains('unauthorized')) {
      return 'Your sign-in on this device has expired, so the server '
          'refused to answer. Sign out (Settings) and sign back in, then '
          'open the wallet again.';
    }
    if (c.contains('timed_out')) {
      return 'The server didn\'t answer in time. Check your connection and '
          'retry — if this keeps happening, the payments backend may be '
          'down.';
    }
    if (c.contains('socket') || c.contains('network') || c.contains('host')) {
      return 'No connection to the server. Check your internet and retry.';
    }
    return 'The payments backend answered with an error. Retry, and if it '
        'persists run "Check payments setup" (the icon at the top) and '
        'send what it says.';
  }

  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Future<WalletStatus>? _future;

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

  void _refresh() => setState(() {
        _future = _load();
        _controlsEpoch++;
      });

  /// Bumped to make [_PausedBanner] ask again. Pausing is invisible from here
  /// otherwise, and a wallet that looks ordinary while nothing can move is how
  /// somebody discovers the switch days later, from a failed transfer.
  int _controlsEpoch = 0;

  Future<void> _openControls() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PaymentControlsScreen()));
    if (mounted) setState(() => _controlsEpoch++);
  }

  /// The direct-deposit form. Changing it is heavier than setting it the
  /// first time on purpose: payouts pause for seven business days, and the
  /// screen says so before anything is typed.
  Future<void> _openChangeBank(WalletStatus s) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ChangeBankScreen(
            country: (s.country ?? 'CA').toUpperCase(),
            currency: s.currency.toLowerCase())));
    if (changed == true && mounted) _refresh();
  }

  /// The card form itself. "Add a debit card" used to open Payment controls,
  /// which has no card in it anywhere — a button that answered a different
  /// question than the one it asked.
  Future<void> _openAddCard(String currency) async {
    final added = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => AddDebitCardScreen(currency: currency)));
    if (added == true && mounted) _refresh();
  }

  Future<void> _startOnboarding() async {
    final understood = await showRecipientLiabilityNotice(context);
    if (!understood || !mounted) return;

    // The app's own forms, on every platform that can show a form — which is
    // all of them. Stripe still holds the details and the sensitive numbers go
    // straight to it from the device, but nothing here is a web page and
    // nothing pops up. The screen falls back to Stripe's own page by itself for
    // an account too old for native collection.
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NativeOnboardingScreen()),
    );
    if (done == true && mounted) _refresh();
  }

  void _openReceive() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ReceiveMoneyScreen()),
      );

  /// Top up the wallet from a card. The amount typed is what lands; the fee
  /// rides on top, and the sheet shows the total before charging.
  Future<void> _addMoney() async {
    final cents = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: const _AddMoneySheet(),
      ),
    );
    if (cents == null || cents <= 0 || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await PaymentService.instance.addMoney(amountCents: cents);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(ok
              ? 'Added to your wallet. It lands in a moment.'
              : 'That didn\'t go through — nothing was charged.')));
      if (ok) _refresh();
    } on PaymentException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(e.code == 'parental_locked'
              ? 'Payments are turned off by Screen Time.'
              : 'Couldn\'t add money right now.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrapped here rather than at the button that opens this, so every way
    // in is covered.
    return ParentalGate(
      restriction: ParentalRestriction.payments,
      title: 'Wallet',
      child: PhoneGate(
      title: 'Wallet',
      reason: 'Sending or receiving money means a bank, a card and an ID '
          'check, and every one of those is attached to a person a phone '
          'number identifies. There is nothing here an account without one '
          'could be given.',
      child: VerifiedGate(
      title: 'Wallet',
      reason: 'This moves real money to and from real people. A card is charged '
          'and a bank account is paid out, and both need to belong to '
          'somebody the app can actually name.',
      // Deliberately NOT waived for the owner. Every payment carries the
      // verified legal name on the Stripe intent and the capture gate checks
      // against it, so `payments-create-intent` refuses without one no matter
      // who is asking. Letting an owner in here would trade an explanation
      // for a 403 three taps later.
      ownerReason: 'You run this app, and this is still not yours to skip. '
          'Every payment carries the legal name from your ID check, and Stripe '
          'refuses one without it — a role in this app cannot supply a name '
          'that somebody else has to verify.',
        child: _guarded(context),
      ),
      ),
    );
  }

  Widget _guarded(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          if (PaymentService.instance.isConfigured) ...[
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Payment controls',
              onPressed: _openControls,
            ),
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refresh),
          ],
          // Outside the isConfigured guard on purpose: "payments aren't set up"
          // is one of the things the self-test exists to explain.
          IconButton(
            icon: const Icon(Icons.medical_information_outlined),
            tooltip: 'Check payments setup',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const PaymentDiagnosticsScreen())),
          ),
        ],
      ),
      floatingActionButton: !PaymentService.instance.isConfigured
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PaymentHistoryScreen())),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Transactions'),
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
                return PullToRefresh(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (PaymentService.instance.testMode.value)
                        const _TestModeBanner(),
                      _PausedBanner(
                        key: ValueKey(_controlsEpoch),
                        onResume: _openControls,
                      ),
                      _BalanceCard(status: s),
                      const SizedBox(height: 12),
                      // The two ways to fill a wallet: put your own money in
                      // (a card top-up), or be paid by somebody else. Both
                      // need the account onboarded first — you cannot receive
                      // into a balance that does not exist.
                      if (s.canReceive)
                        Row(
                          children: [
                            Expanded(
                              child: _WalletAction(
                                  icon: Icons.add,
                                  label: 'Add money',
                                  onTap: _addMoney),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _WalletAction(
                                  icon: Icons.qr_code_2,
                                  label: 'Receive',
                                  onTap: _openReceive),
                            ),
                          ],
                        )
                      else
                        // No account yet: receiving is still the way in, so
                        // offer it — it opens the same onboarding.
                        _WalletAction(
                            icon: Icons.qr_code_2,
                            label: 'Ways to get paid',
                            onTap: _openReceive),
                      const SizedBox(height: 16),
                      if (!s.canReceive)
                        _OnboardCard(onStart: _startOnboarding)
                      else ...[
                        _CashOutCard(
                          status: s,
                          onDone: _refresh,
                          onAddCard: () =>
                              _openAddCard(s.currency.toLowerCase()),
                        ),
                        const SizedBox(height: 16),
                        _PayoutCard(
                          status: s,
                          onChangeBank: () => _openChangeBank(s),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const _TestModeTile(),
                      const SizedBox(height: 8),
                      const _InfoFooter(),
                    ],
                  ),
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
                      color: AppColors.subtle(context))),
              const SizedBox(height: 6),
              Text(WalletScreen.errorAdvice(msg),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle(context))),
              const SizedBox(height: 6),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.subtle(context), fontSize: 11)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

/// A wide tappable pill — Add money / Receive — under the balance.
class _WalletAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WalletAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(
                      color: scheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Enter an amount to add to the wallet. Returns cents on confirm. The typed
/// amount is what lands; the sheet says the fee rides on top so the total is
/// no surprise on the card statement.
class _AddMoneySheet extends StatefulWidget {
  const _AddMoneySheet();

  @override
  State<_AddMoneySheet> createState() => _AddMoneySheetState();
}

class _AddMoneySheetState extends State<_AddMoneySheet> {
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _cents {
    final v = double.tryParse(_amount.text.trim());
    return v == null ? 0 : (v * 100).round();
  }

  @override
  Widget build(BuildContext context) {
    final cents = _cents;
    final total = cents <= 0 ? 0 : PaymentEconomics.grossUpCents(cents);
    String money(int c) => '\$${(c / 100).toStringAsFixed(2)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Add money',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                prefixText: '\$ ',
                hintText: '0',
                labelText: 'Amount to add'),
          ),
          const SizedBox(height: 6),
          Text(
            cents <= 0
                ? 'The amount you type lands in your wallet; a card fee rides '
                    'on top.'
                : '${money(cents)} lands in your wallet · card charged '
                    '${money(total)}',
            style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed:
                cents <= 0 ? null : () => Navigator.of(context).pop(cents),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
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

  final VoidCallback onStart;
  const _OnboardCard({required this.onStart});

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
              style: TextStyle(color: AppColors.subtle(context), fontSize: 13.5),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF12B76A),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                // No spinner here any more: tapping opens the form, which owns
                // its own progress. A button that spun while a screen was
                // pushed on top of it was showing the same wait twice.
                onPressed: onStart,
                child: const Text('Set up with Stripe'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cashing out to a debit card, in minutes rather than the usual days.
///
/// The fee is on the card **before** the button, not in a receipt afterwards.
/// Stripe takes its cut out of the amount, so the number that lands is smaller
/// than the number tapped, and an app that only mentions that once the money
/// has moved has picked the wrong moment to be honest.
class _CashOutCard extends StatefulWidget {
  final WalletStatus status;
  final VoidCallback onDone;
  final VoidCallback onAddCard;
  const _CashOutCard({
    required this.status,
    required this.onDone,
    required this.onAddCard,
  });

  @override
  State<_CashOutCard> createState() => _CashOutCardState();
}

class _CashOutCardState extends State<_CashOutCard> {
  bool _busy = false;

  WalletStatus get _s => widget.status;

  Future<void> _cashOut() async {
    final amount = _s.instantAvailableCents;
    final fee = InstantPayoutEconomics.feeCents(amount, _s.country);
    final lands = InstantPayoutEconomics.landsCents(amount, _s.country);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cash out instantly?'),
        // The three numbers that matter, separately. "You get $31.68" alone
        // invites "why not $32?" at exactly the moment nobody can ask.
        content: Text(
          '${_s.money(amount)} from your balance\n'
          '− ${_s.money(fee)} Stripe\'s instant fee\n'
          '= ${_s.money(lands)} on your '
          '${_s.cardBrand ?? 'card'} ••${_s.cardLast4 ?? '••'}\n\n'
          'Usually within 30 minutes. Waiting for the normal payout to your '
          'bank costs nothing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cash out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final outcome =
        await PaymentService.instance.cashOutInstantly(amount, country: _s.country);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(outcome.ok
          ? 'On its way — ${_s.money(outcome.amountCents - outcome.feeCents)} '
              'to ••${_s.cardLast4 ?? '••'}'
          : outcome.message),
    ));
    if (outcome.ok) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final subtle = AppColors.subtle(context);
    // Nothing to move is not a problem to explain, so this says nothing at
    // all rather than drawing a disabled button and a reason.
    if (s.instantAvailableCents <= 0 && s.hasDebitCard) {
      return const SizedBox.shrink();
    }

    final canGo = s.canCashOutInstantly;
    final fee = InstantPayoutEconomics.feeCents(s.instantAvailableCents, s.country);

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, color: Color(0xFF12B76A)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Cash out instantly',
                      style: TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w600)),
                ),
                if (canGo)
                  Text(s.money(s.instantAvailableCents),
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !s.hasDebitCard
                  ? 'Add a debit card and your balance can land in minutes '
                      'instead of waiting for the bank payout.'
                  : s.cardLocked
                      ? 'Instant payouts are locked: the card on this '
                          'account changed too often. The lock lifts on its '
                          'own once the recent changes are more than 30 '
                          'days old. Bank payouts are unaffected.'
                  : s.cardHoldDaysLeft > 0
                      ? 'Your card was added recently. As a security '
                          'measure, instant payouts unlock in '
                          '${s.cardHoldDaysLeft} business '
                          '${s.cardHoldDaysLeft == 1 ? 'day' : 'days'} — '
                          'bank payouts are unaffected.'
                  : !InstantPayoutEconomics.isSupportedIn(s.country)
                      ? 'Stripe does not offer instant payouts in this '
                          'country yet. Your balance still pays out to your '
                          'bank on the normal schedule.'
                      : !InstantPayoutEconomics.isWorthCashingOut(
                              s.instantAvailableCents)
                          ? 'At least '
                              '${s.money(InstantPayoutEconomics.minimumCents)} '
                              'needs to be instantly available.'
                          : 'To your ${s.cardBrand ?? 'card'} '
                              '••${s.cardLast4 ?? '••'}, usually within 30 '
                              'minutes. Stripe charges '
                              '${InstantPayoutEconomics.percentFor(s.country)}% '
                              '(${s.money(fee)}) and takes it from the amount.',
              style: TextStyle(color: subtle, fontSize: 13.5, height: 1.35),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: canGo
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF12B76A),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _cashOut,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.bolt),
                      label: Text(_busy
                          ? 'Sending'
                          : 'Cash out ${s.money(s.instantAvailableCents)}'),
                    )
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      // The card is attached through Stripe's own component:
                      // debit card details must never reach this app.
                      onPressed: s.hasDebitCard ? null : widget.onAddCard,
                      child: Text(s.hasDebitCard
                          ? 'Not available right now'
                          : 'Add a debit card'),
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

  /// Opens the change-direct-deposit form.
  final VoidCallback onChangeBank;
  const _PayoutCard({required this.status, required this.onChangeBank});

  @override
  Widget build(BuildContext context) {
    final payout = status.payoutStatus;
    final held = status.bankHoldDaysLeft > 0;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    held
                        ? Icons.hourglass_top
                        : Icons.account_balance_wallet_outlined,
                    color: held ? Colors.orange : const Color(0xFF12B76A)),
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
                        held
                            ? 'Your payout account was changed recently. As '
                                'a security measure, payouts resume in '
                                '${status.bankHoldDaysLeft} business '
                                '${status.bankHoldDaysLeft == 1 ? 'day' : 'days'}.'
                            : payout == null
                                ? 'Your balance is automatically paid out to '
                                    'your bank'
                                    '${status.bankLast4.isEmpty ? '.' : ' ••${status.bankLast4}.'}'
                                : 'Latest payout: $payout'
                                    '${status.payoutAmountCents != null ? ' · ${status.money(status.payoutAmountCents!)}' : ''}',
                        style: TextStyle(
                            color: AppColors.subtle(context), fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (!held)
                  const Icon(Icons.check_circle, color: Color(0xFF12B76A)),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onChangeBank,
                child: const Text('Change direct deposit'),
              ),
            ),
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
        Icon(Icons.lock_outline, size: 15, color: AppColors.subtle(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Payments are processed by Stripe. OkayMessenger never holds your '
            'funds or sees your card details, and your messages stay private.',
            style: TextStyle(color: AppColors.subtle(context), fontSize: 12, height: 1.4),
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
            Icon(Icons.payments_outlined,
                size: 48, color: AppColors.accentOn(context)),
            const SizedBox(height: 14),
            Text('Payments aren\'t set up yet',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.subtle(context))),
            const SizedBox(height: 6),
            Text(
              'Add your Stripe publishable key and deploy the payment Edge '
              'Functions to enable in-chat payments. See PAYMENTS.md.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => PaymentService.instance.setTestMode(true),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Try test mode'),
            ),
            const SizedBox(height: 6),
            Text('Simulates payments — no real money moves.',
                style: TextStyle(color: AppColors.subtle(context), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Says so when payments are paused, and nothing at all otherwise.
///
/// Fetches on its own so a wallet that can't reach the settings function still
/// renders — the balance is the point of this screen, and a banner failing to
/// load must not take it down.
class _PausedBanner extends StatefulWidget {
  const _PausedBanner({super.key, required this.onResume});

  final VoidCallback onResume;

  @override
  State<_PausedBanner> createState() => _PausedBannerState();
}

class _PausedBannerState extends State<_PausedBanner> {
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final c = await PaymentService.instance.controls();
      if (mounted && c.paused != _paused) setState(() => _paused = c.paused);
    } catch (_) {
      // Unknown reads as not paused: the transfer itself is refused server-side
      // either way, so guessing here costs nothing.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_paused) return const SizedBox.shrink();
    const stop = Color(0xFFD92D20);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: stop.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: stop.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle, color: stop),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Payments are paused — nothing can be sent or '
                'received.'),
          ),
          TextButton(
            onPressed: widget.onResume,
            child: const Text('Resume'),
          ),
        ],
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
