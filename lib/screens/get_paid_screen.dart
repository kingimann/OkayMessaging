import 'package:flutter/material.dart';

import '../app_state.dart';
import '../payments/lightning.dart';
import '../payments/payment_service.dart';
import '../relay/relay_service.dart';
import '../state/nwc_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import 'native_onboarding_screen.dart';

/// The two ways somebody can be sparked or tipped, on one screen, with what
/// each really costs to set up.
///
/// This exists because the app had exactly one visible answer to "how do I get
/// paid" — the Stripe form, twenty boxes deep with an ID photo and a bank
/// account — and one invisible answer that takes about thirty seconds. A
/// Lightning address needs no ID, no bank and no session; it was already
/// supported, and it was at the bottom of Edit profile where only somebody who
/// already knew about it would ever find it. Nearly every tip that fails
/// fails on the recipient never having finished setup, so the fix is putting
/// the cheap rail in front of the expensive one instead of behind it.
///
/// Neither is presented as the "right" one. They are different money: Lightning
/// is bitcoin that lands in the recipient's own wallet and that Okay can never
/// see, cash is dollars into a bank account that Stripe has to verify a human
/// behind. What the screen does is stop the second from being the only one
/// anybody is offered.
class GetPaidScreen extends StatefulWidget {
  /// Whether Stripe has already been finished — the wallet knows this and
  /// passes it in rather than making this screen ask again.
  final bool cashReady;

  /// True when this is a tab of [MoneyScreen]: the list only, without a
  /// scaffold or app bar of its own.
  final bool embedded;

  const GetPaidScreen(
      {super.key, required this.cashReady, this.embedded = false});

  @override
  State<GetPaidScreen> createState() => _GetPaidScreenState();
}

class _GetPaidScreenState extends State<GetPaidScreen> {
  late final TextEditingController _lightning;

  /// Cleared as soon as the field is edited, so "Saved" never describes what
  /// is currently on screen.
  bool _justSaved = false;
  bool _cashReady = false;

  @override
  void initState() {
    super.initState();
    _cashReady = widget.cashReady;
    // Rebuilt on every keystroke, not only when [_justSaved] falls: the
    // malformed-address line and the Save button both read the live text, so
    // a listener that fired conditionally left somebody typing nonsense into
    // an enabled button with no complaint on screen.
    _lightning =
        TextEditingController(text: AppState.profile.value.lightningAddress)
          ..addListener(() => setState(() => _justSaved = false));
  }

  @override
  void dispose() {
    _lightning.dispose();
    super.dispose();
  }

  String get _typed => _lightning.text.trim().toLowerCase();

  /// Empty is a legitimate value — it turns the rail off.
  bool get _valid => _typed.isEmpty || LightningAddress.isValid(_typed);

  bool get _lightningOn =>
      LightningAddress.isValid(AppState.profile.value.lightningAddress);

  Future<void> _saveLightning() async {
    if (!_valid) return;
    final p = AppState.profile.value;
    if (Session.instance.isSignedIn) {
      await Session.instance
          .updateProfile(name: p.name, about: p.about, lightningAddress: _typed);
    } else {
      // A name-only account has no session and can still be paid this way —
      // Lightning is the one rail that never needed one.
      AppState.updateProfile(
          name: p.name, about: p.about, lightningAddress: _typed);
    }
    // Contacts learn the address now rather than on the next message, which
    // is the difference between a spark button that appears and one that
    // appears eventually.
    RelayService.instance.broadcastProfile();
    if (!mounted) return;
    setState(() => _justSaved = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_typed.isEmpty
            ? 'Lightning sparks turned off'
            : 'People can spark you over Lightning now')));
  }

  /// Takes the connection string a wallet issues. Deliberately a paste field
  /// and not a QR scan for v1: every wallet offers copy, and a camera
  /// permission prompt to set up an optional convenience is a worse trade
  /// than a long-press.
  Future<void> _connectWallet() async {
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect a wallet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'In your Lightning wallet, look for "Nostr Wallet Connect" and '
              'create a connection for Okay. Copy the string it gives you and '
              'paste it here.\n\nIt lets Okay ask your wallet to pay, up to '
              'whatever limit you set there. It is not a password and it does '
              'not give Okay your bitcoin.',
              style: TextStyle(fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: 'nostr+walletconnect://…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Connect')),
        ],
      ),
    );
    if (pasted == null || !mounted) return;
    final problem = await NwcStore.instance.connect(pasted);
    if (!mounted) return;
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Wallet connected')));
  }

  Future<void> _disconnectWallet() async {
    await NwcStore.instance.disconnect();
    if (!mounted) return;
    setState(() {});
    // Says the part the app cannot do: forgetting the string here stops THIS
    // phone using it, and revoking it in the wallet is what stops it for good.
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Forgotten on this phone. Revoke it in your wallet too '
            'to be sure.')));
  }

  Future<void> _setUpCash() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NativeOnboardingScreen()),
    );
    if (done == true && mounted) setState(() => _cashReady = true);
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Two ways people can spark or tip you. You can turn on either, '
            'both, or neither.',
            style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle),
          ),
          const SizedBox(height: 18),
          _RailCard(
            icon: Icons.bolt,
            title: 'Bitcoin over Lightning',
            cost: 'About 30 seconds · no ID, no bank details',
            on: _lightningOn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _lightning,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Your Lightning address',
                    hintText: 'you@getalby.com',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (!_valid)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'That is not a Lightning address. It is shaped like an '
                      'email: name@domain.',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _valid ? _saveLightning : null,
                  child: Text(_justSaved
                      ? 'Saved'
                      : _typed.isEmpty && _lightningOn
                          ? 'Turn off'
                          : 'Save'),
                ),
                const SizedBox(height: 10),
                Text(
                  'Get one free from a Lightning wallet — Alby, Wallet of '
                  'Satoshi, Phoenix and others hand you an address the moment '
                  'you install them. It is safe to publish, like a tip jar.',
                  style: TextStyle(fontSize: 12, height: 1.35, color: subtle),
                ),
                const SizedBox(height: 8),
                Text(
                  'Payments go straight from their wallet to yours. Okay never '
                  'holds the money and takes no cut — which also means it '
                  'cannot tell you when one arrives. Your wallet does that.',
                  style: TextStyle(fontSize: 12, height: 1.35, color: subtle),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _RailCard(
            icon: Icons.account_balance,
            title: 'Cash to your bank',
            cost: 'A few minutes · photo ID and a bank account',
            on: _cashReady,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _cashReady
                      ? 'Tips in dollars land in your Okay balance and are '
                          'paid out to your bank.'
                      : 'Stripe has to check who you are before real money can '
                          'be sent to a real bank account. Your name, email and '
                          'town are filled in already; what is left is your date '
                          'of birth, address, ID and bank numbers.',
                  style: TextStyle(fontSize: 12.5, height: 1.35, color: subtle),
                ),
                if (!_cashReady) ...[
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _setUpCash,
                    child: const Text('Set up with Stripe'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          // SENDING, not receiving — and it is on this screen anyway because
          // this is where somebody already has their wallet app open.
          _RailCard(
            icon: Icons.link,
            title: 'Connect your wallet for sending',
            cost: 'Optional · about a minute',
            on: NwcStore.instance.isConnected,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  NwcStore.instance.isConnected
                      ? 'Sparks you send are paid by your wallet without '
                          'leaving Okay, and it tells us whether each one went '
                          'through — via ${NwcStore.instance.relayHost}.'
                      : 'Without this, sending a spark hands the invoice to '
                          'your wallet app and Okay never learns what happened, '
                          'so it can\'t tell you whether it worked. Connect one '
                          'and it can. Okay still never holds your bitcoin.',
                  style: TextStyle(fontSize: 12.5, height: 1.35, color: subtle),
                ),
                const SizedBox(height: 12),
                if (NwcStore.instance.isConnected)
                  OutlinedButton(
                    onPressed: _disconnectWallet,
                    child: const Text('Disconnect'),
                  )
                else
                  FilledButton(
                    onPressed: _connectWallet,
                    child: const Text('Connect a wallet'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            PaymentService.instance.testMode.value
                ? 'Payments are in test mode on this phone, so cash tips are '
                    'simulated. Lightning is never simulated — it is a real '
                    'address and a real wallet.'
                : 'Sparks and tips are both final — there is no refund button '
                    'on either.',
            style: TextStyle(fontSize: 12, height: 1.35, color: subtle),
          ),
        ],
      );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Get paid')),
      body: body,
    );
  }
}

/// One rail, with an honest badge for whether it is actually working.
///
/// The badge is the point of the card: "On" means somebody could spark you
/// this second, and that is the only question anybody arrives here with.
class _RailCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String cost;
  final bool on;
  final Widget child;

  const _RailCard({
    required this.icon,
    required this.title,
    required this.cost,
    required this.on,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              _StatusChip(on: on),
            ],
          ),
          const SizedBox(height: 4),
          Text(cost, style: TextStyle(fontSize: 12, color: subtle)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool on;
  const _StatusChip({required this.on});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: on
            ? const Color(0xFF12B76A).withValues(alpha: 0.14)
            : Colors.transparent,
        border: Border.all(
            color: on
                ? const Color(0xFF12B76A)
                : Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        on ? 'On' : 'Off',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: on ? const Color(0xFF12B76A) : subtle,
        ),
      ),
    );
  }
}
