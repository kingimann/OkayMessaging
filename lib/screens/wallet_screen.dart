import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/parental_controls.dart';
import '../widgets/parental_gate.dart';
import '../widgets/phone_gate.dart';

import '../main.dart' show openChatForPhone;
import '../state/incoming_links.dart';
import '../state/platform_moderation.dart';
import '../payments/connect_webview.dart';
import '../payments/nfc_pay.dart';
import '../payments/payment_service.dart';
import '../payments/stripe_sheet.dart';
import '../payments/storage_economics.dart';
import '../state/crash_reporter.dart';
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
  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

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

  const WalletScreen({super.key, this.fromSidebar = false});

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

  /// Tap-to-pay (payer side): read a pay tag and open straight into paying that
  /// person. On iOS an iPhone can read a tag but can't pretend to be one, so
  /// the payee's phone can't broadcast — they make a reusable pay STICKER from
  /// Receive → "Write an NFC tag", and this reads it. No NFC on this device
  /// falls back to the QR code (their tap-free way to be paid).
  Future<void> _tapToPay() async {
    final can = await NfcPay.instance.available();
    if (!mounted) return;
    if (can) {
      final link = await NfcPay.instance.readTag();
      if (!mounted) return;
      final target = link == null ? null : IncomingLinks.addTarget(link);
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('That tag isn\'t an OkayMessenger pay tag.')));
        return;
      }
      // Open the person the tag names; paying is one tap from their chat.
      await openChatForPhone(target.phone, systemFallback: false);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.contactless_outlined, size: 40),
              const SizedBox(height: 12),
              const Text('Tap to pay needs NFC',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'This device can\'t read NFC tags. To be paid in person, show '
                'your QR code instead — the other person scans it and pays.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheet).pop();
                  _openReceive();
                },
                icon: const Icon(Icons.qr_code_2),
                style:
                    FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                label: const Text('Show my QR code'),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
    // The real card entry runs on Stripe's HOSTED checkout page in a WebView,
    // not the native Payment Sheet — the sheet couldn't present on some
    // devices (it returned a silent cancel and never asked for a card). Test
    // mode still simulates, and a device with no WebView keeps the old path.
    final useHostedCheckout =
        !PaymentService.instance.testMode.value && ConnectWebView.isSupported;
    try {
      if (useHostedCheckout) {
        final url =
            await PaymentService.instance.topUpCheckoutUrl(amountCents: cents);
        if (!mounted) return;
        // Inline: the card form slides up over the wallet as a tall sheet
        // rather than pushing a separate full screen — it stays in context.
        final done = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          // No drag-to-dismiss: at full height the sheet can only be dragged
          // DOWN, so it swallowed the WebView's upward scroll and the card
          // form couldn't reach its postal-code and pay button. The ✕ in the
          // header closes it instead.
          enableDrag: false,
          useSafeArea: true,
          builder: (_) => _TopUpCheckoutSheet(url: url),
        );
        if (!mounted) return;
        _refresh();
        if (done == true) {
          messenger.showSnackBar(const SnackBar(
              content: Text('Payment received — your balance updates in a '
                  'moment.')));
        }
        return;
      }
      final ok = await PaymentService.instance.addMoney(amountCents: cents);
      if (!mounted) return;
      if (ok) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Added to your wallet. It lands in a moment.')));
        _refresh();
      } else {
        // false with no captured error is a plain cancel; anything else is a
        // real failure whose reason is now on lastError.
        final why = StripeSheet.lastError;
        if (why == null || why.trim().isEmpty) {
          messenger.showSnackBar(const SnackBar(
              content: Text('That didn\'t go through — nothing was charged.')));
        } else {
          _showTopUpError(why);
        }
      }
    } on PaymentException catch (e) {
      if (!mounted) return;
      _showTopUpError(_addMoneyError(e.code));
    } catch (e) {
      // A failure that ISN'T a PaymentException — the top-up function not
      // deployed, or the network — used to escape here and the button just
      // did nothing. Show the friendly line AND the raw reason so it can be
      // read, not swallowed.
      if (!mounted) return;
      _showTopUpError(
          'Couldn\'t reach the top-up service. It may not be set up yet — '
          'try again shortly.\n\nDetails: ${e.toString()}');
    }
  }

  /// A PERSISTENT, copyable error — not a snackbar that vanishes before it can
  /// be read. When a top-up fails at the card step the exact reason is the
  /// whole game, so it stays on screen with a Copy button until dismissed.
  void _showTopUpError(String message) {
    // Also ship the reason to crash_reports: the sheet failure is CAUGHT, so
    // it never reaches the auto-reporter, and the exact flutter_stripe error
    // is otherwise only readable off the device. Reporting it makes the cause
    // diagnosable server-side. No message content or identity — just the
    // payment error text.
    CrashReporter.instance.report(
        'topup failed: $message', StackTrace.current,
        context: 'topup');
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Couldn\'t add money'),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  bool _cashingOut = false;

  /// The Cash-App "Cash Out" action, hoisted so the big button owns it: to a
  /// debit card instantly when that's available, otherwise it explains why and
  /// leaves the automatic bank payout to run. No card yet → add one first.
  Future<void> _cashOut(WalletStatus s) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!s.hasDebitCard) {
      _openAddCard(s.currency.toLowerCase());
      return;
    }
    if (!s.canCashOutInstantly) {
      messenger.showSnackBar(SnackBar(
          content: Text(s.cardLocked
              ? 'Instant cash out is locked after recent card changes. Your '
                  'balance still pays out to your bank.'
              : s.cardHoldDaysLeft > 0
                  ? 'Instant cash out unlocks in ${s.cardHoldDaysLeft} business '
                      '${s.cardHoldDaysLeft == 1 ? 'day' : 'days'}. Bank payout '
                      'is unaffected.'
                  : !InstantPayoutEconomics.isSupportedIn(s.country)
                      ? 'Instant cash out isn\'t available in your country yet. '
                          'Your balance pays out to your bank automatically.'
                      : s.instantAvailableCents <= 0
                          ? 'Nothing to cash out yet.'
                          : 'At least '
                              '${s.money(InstantPayoutEconomics.minimumCents)} '
                              'needs to be available to cash out instantly.')));
      return;
    }
    final amount = s.instantAvailableCents;
    final fee = InstantPayoutEconomics.feeCents(amount, s.country);
    final lands = InstantPayoutEconomics.landsCents(amount, s.country);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cash out instantly?'),
        content: Text(
          '${s.money(amount)} from your balance\n'
          '− ${s.money(fee)} Stripe\'s instant fee\n'
          '= ${s.money(lands)} on your '
          '${s.cardBrand ?? 'card'} ••${s.cardLast4 ?? '••'}\n\n'
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
    setState(() => _cashingOut = true);
    final outcome =
        await PaymentService.instance.cashOutInstantly(amount, country: s.country);
    if (!mounted) return;
    setState(() => _cashingOut = false);
    messenger.showSnackBar(SnackBar(
      content: Text(outcome.ok
          ? 'On its way — ${s.money(outcome.amountCents - outcome.feeCents)} '
              'to ••${s.cardLast4 ?? '••'}'
          : outcome.message),
    ));
    if (outcome.ok) _refresh();
  }

  /// A readable line for each way a top-up can be refused.
  String _addMoneyError(String code) {
    switch (code) {
      case 'parental_locked':
        return 'Payments are turned off by Screen Time.';
      case 'not_onboarded':
        return 'Finish setting up payouts before you can add money.';
      case 'identity_required':
        return 'Verify your identity to add money.';
      case 'sender_banned':
        return 'This account can\'t move money right now.';
      default:
        // A Stripe failure comes through as a human sentence (a decline
        // reason, an account that can't yet receive) — show it as-is rather
        // than wrapping a whole sentence in "(...)". A short code stays parem.
        return code.contains(' ')
            ? code
            : 'Couldn\'t add money right now ($code).';
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
            // Transactions moved off the floating button into the bar's
            // top-right, where the other wallet actions live.
            IconButton(
              icon: const Icon(Icons.receipt_long_outlined),
              tooltip: 'Transactions',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PaymentHistoryScreen())),
            ),
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
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      if (PaymentService.instance.testMode.value)
                        const _TestModeBanner(),
                      _PausedBanner(
                        key: ValueKey(_controlsEpoch),
                        onResume: _openControls,
                      ),
                      // Cash App's face: a big centred balance, then the two
                      // signature actions.
                      _BalanceHero(status: s),
                      const SizedBox(height: 28),
                      if (!s.canReceive) ...[
                        _OnboardCard(onStart: _startOnboarding),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: _CashPill(
                                label: 'Add Cash',
                                icon: Icons.add,
                                filled: true,
                                onTap: _addMoney,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _CashPill(
                                label: 'Cash Out',
                                icon: Icons.arrow_downward,
                                busy: _cashingOut,
                                onTap: () => _cashOut(s),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _CashPill(
                                label: 'Receive',
                                icon: Icons.qr_code_2,
                                tertiary: true,
                                onTap: _openReceive,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _CashPill(
                                label: 'Tap to pay',
                                icon: Icons.contactless_outlined,
                                tertiary: true,
                                onTap: _tapToPay,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _PayoutCard(
                          status: s,
                          onChangeBank: () => _openChangeBank(s),
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Simulated payments are a QA tool, not a shipping
                      // feature — an ordinary buyer flipping it on turns real
                      // money into make-believe. Owners/admins only.
                      ListenableBuilder(
                        listenable: PlatformModeration.instance,
                        builder: (context, _) =>
                            PlatformModeration.instance.canAdminister
                                ? const _TestModeTile()
                                : const SizedBox.shrink(),
                      ),
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

/// Cash App's big rounded action buttons. [filled] is the bright-green primary
/// (Add Cash), the default is a solid neutral (Cash Out), and [tertiary] is a
/// quieter tinted pill (Receive).
class _CashPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool tertiary;
  final bool busy;
  const _CashPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.tertiary = false,
    this.busy = false,
  });

  /// Cash App's signature bright green, used for the primary action.
  static const Color cashGreen = Color(0xFF00C244);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (filled) {
      bg = cashGreen;
      fg = Colors.white;
    } else if (tertiary) {
      bg = scheme.surfaceContainerHighest;
      fg = scheme.onSurface;
    } else {
      bg = scheme.onSurface.withValues(alpha: 0.90);
      fg = scheme.surface;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(30),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              else
                Icon(icon, color: fg, size: 20),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      color: fg,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
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
          const SizedBox(height: 12),
          // The single most common confusion: people expect to top up without
          // a card and stop at Stripe's sheet, thinking it wants their
          // cash-out card. Say plainly that the next step is the card the
          // money comes FROM, and that it isn't the payout card.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.subtle(context).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.credit_card,
                    size: 18, color: AppColors.subtle(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Next you\'ll enter a debit or credit card to pay with — '
                    'that\'s where the money comes from. It\'s not your '
                    'cash-out card.',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: AppColors.subtle(context)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed:
                cents <= 0 ? null : () => Navigator.of(context).pop(cents),
            child: const Text('Continue to card'),
          ),
        ],
      ),
    );
  }
}

/// Cash App's hero: the balance, big and centred, is the whole top of the
/// screen — no card, no gradient, just the number.
class _BalanceHero extends StatelessWidget {
  final WalletStatus status;
  const _BalanceHero({required this.status});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              status.money(status.availableCents),
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            status.pendingCents > 0
                ? 'Balance · ${status.money(status.pendingCents)} pending'
                : 'Balance · ${status.currency.toUpperCase()}',
            style: TextStyle(color: subtle, fontSize: 13.5),
          ),
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
            // Simulated payments are for QA — owners/admins only, never an
            // ordinary user staring at a wallet that isn't set up.
            if (PlatformModeration.instance.canAdminister) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () => PaymentService.instance.setTestMode(true),
                icon: const Icon(Icons.science_outlined),
                label: const Text('Try test mode'),
              ),
              const SizedBox(height: 6),
              Text('Simulates payments — no real money moves.',
                  style:
                      TextStyle(color: AppColors.subtle(context), fontSize: 12)),
            ],
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

/// Stripe's hosted checkout page for a top-up, shown INLINE as a tall sheet
/// over the wallet — inside the app's own WebView, no browser, no popup, the
/// same surface Connect onboarding uses. The native Payment Sheet couldn't
/// present on some devices; this always shows a card form. Pops `true` the
/// moment the page navigates to the return URL (the payment finished), which
/// the WebView catches and reports as 'submitted'.
class _TopUpCheckoutSheet extends StatelessWidget {
  final String url;
  const _TopUpCheckoutSheet({required this.url});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Nearly full height so the whole card form and its keyboard fit; the ✕ in
    // the header dismisses it (the sheet's own drag is off so the WebView can
    // scroll to the bottom of the form).
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.92,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                const Text('Add cash',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              child: ConnectWebView.build(
                url: url,
                // A plain hosted page needs neither a client secret nor the
                // embedded component's secret pump — it is ordinary navigation.
                clientSecret: '',
                publishableKey: PaymentService.publishableKey,
                dark: isDark,
                accent: AppColors.accentOn(context),
                completionUrlPrefix: PaymentService.returnUrl,
                onEvent: (event) {
                  // Checkout ends by navigating to the return URL (success or
                  // cancel); either way the person belongs back in the app,
                  // where the balance refresh tells the true story.
                  if (event == 'submitted' && context.mounted) {
                    Navigator.of(context).pop(true);
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
