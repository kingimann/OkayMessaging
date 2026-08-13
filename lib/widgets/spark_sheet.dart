import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../payments/lightning.dart';
import 'lightning_spark_sheet.dart';
import '../payments/payment_service.dart';
import '../state/identity_verification.dart';
import '../state/push_service.dart';
import '../theme/app_theme.dart';

/// One-tap preset amounts for a Tip — 21 is the community's number, kept from
/// when this rail was itself called Spark. Shared by the server feed and the
/// public one, so the gesture costs the same everywhere. Returns the chosen
/// cents, or null.
Future<int?> showTipSheet(BuildContext context, {required String toLabel}) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (_) => _TipSheet(toLabel: toLabel),
  );
}

/// The whole TIP flow against a known recipient — real money over the
/// existing Stripe rails, as opposed to a Spark (bitcoin over Lightning,
/// see [offerSpark]/[showLightningSparkSheet]) — the same ladder the feeds
/// walk (can this device send, is the sender verified, can the receiver be
/// paid), then the one-tap sheet, then the REAL transfer, then the push that
/// tells them. Used wherever a message's sender can be tipped directly:
/// server channels, and anywhere else that holds a name and digits rather
/// than a post id. Returns true when money moved.
Future<bool> offerTipTo(BuildContext context,
    {required String toPhone, required String toName}) async {
  final svc = PaymentService.instance;
  final messenger = ScaffoldMessenger.of(context);
  if (!svc.isConfigured) return false;
  if (!svc.canSendOnThisDevice && !svc.testMode.value) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Tips are sent from the iPhone app.')));
    return false;
  }
  if (!IdentityVerification.instance.allowsTrusted) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Verify your ID to send money.')));
    return false;
  }
  if (!svc.testMode.value && !await svc.canReceive(toPhone)) {
    // Not a snackbar and not a dead end. This is the check almost every
    // real tip dies on — money has to have somewhere to land, and hardly
    // anybody has finished Stripe onboarding — so it gets a screen that
    // says why, offers the rail that needs NO onboarding when they have
    // one, and lets the sender nudge them.
    if (!context.mounted) return false;
    await showCannotReceiveSheet(context, toPhone: toPhone, toName: toName);
    return false;
  }
  if (!context.mounted) return false;
  final cents = await showTipSheet(context, toLabel: toName);
  if (cents == null || cents <= 0) return false;
  bool ok;
  try {
    ok = await svc.sendMoney(
      toPhone: toPhone,
      amountCents: cents,
      note: 'Tip',
      // The sheet said tips are final before offering an amount.
      acknowledged: true,
    );
  } on PaymentException catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(switch (e.code) {
      'receiver_not_onboarded' =>
        '$toName hasn\'t set up payments, so tips can\'t reach them yet.',
      'parental_locked' =>
        'Payments are turned off by parental controls on this phone.',
      _ => 'The tip couldn\'t be sent — ${e.code}.',
    })));
    return false;
  } catch (_) {
    return false;
  }
  if (!ok) return false;
  final myName = AppState.profile.value.name;
  PushService.instance.notify(toPhone,
      title: myName.isEmpty ? 'Tip' : myName,
      body: 'Tipped you \$${(cents / 100).toStringAsFixed(2)}');
  messenger.showSnackBar(SnackBar(
      content: Text('Tipped $toName \$${(cents / 100).toStringAsFixed(2)}')));
  return true;
}

/// Whether this device could Spark [user] — bitcoin over Lightning — right
/// now. Pure, and deliberately conservative: it answers from what THIS
/// device knows, so it can never draw a button that leads nowhere. Needs an
/// address they published; the username directory carries none, so a
/// stranger offers no button at all rather than one that fails.
bool canSpark(AppUser? user) =>
    user != null && LightningAddress.isValid(user.lightningAddress);

/// Whether this device could Tip [user] — real money over Stripe — right
/// now. Needs a phone number, which the app only holds for a contact; same
/// conservative rule as [canSpark].
bool canTip(AppUser? user) => user != null && user.phone.trim().isNotEmpty;

/// Sparks [user] bitcoin over Lightning, straight from their profile or
/// contact card. A no-op when [canSpark] is false — see there for why a
/// button leading here is never drawn without it.
Future<void> offerSpark(
  BuildContext context, {
  required AppUser user,
  required String fallbackLabel,
}) async {
  if (!canSpark(user)) return;
  final name = user.name.trim().isEmpty ? fallbackLabel : user.name.trim();
  await showLightningSparkSheet(context,
      address: user.lightningAddress, name: name);
}

/// Tips [user] real money, straight from their profile or contact card. A
/// no-op when [canTip] is false.
Future<void> offerTip(
  BuildContext context, {
  required AppUser user,
  required String fallbackLabel,
}) async {
  if (!canTip(user)) return;
  final name = user.name.trim().isEmpty ? fallbackLabel : user.name.trim();
  await offerTipTo(context, toPhone: user.phone, toName: name);
}


/// Whom this device has already nudged about setting up payments, so the
/// button cannot be turned into a way to hammer somebody's chat. In memory
/// only: it is a courtesy brake, not a security control, and it resetting on
/// relaunch costs nothing.
final Set<String> _nudged = <String>{};

@visibleForTesting
void debugResetTipNudges() => _nudged.clear();

@visibleForTesting
bool debugWasTipNudged(String phone) =>
    _nudged.contains(phone.replaceAll(RegExp(r'\D'), ''));

/// Shown when a cash TIP cannot land: the recipient has not finished the
/// Stripe onboarding that gives the money somewhere to go. Lightning sparks
/// have no such check — a published address is always payable straight from
/// the sender's own wallet — so this sheet only ever fires from the Tip
/// flow, and offers Spark as the way through when the recipient has one.
///
/// The three things it has to get right, in order:
/// 1. **Nothing was charged.** Said outright, because a sheet appearing after
///    you picked an amount reads like a payment that half-happened.
/// 2. **Lightning needs no onboarding.** If they published an address, that
///    rail works right now — so it is offered here rather than making the
///    sender back out and find it.
/// 3. **The sender can nudge them**, once. Only the recipient can fix this,
///    and they cannot fix what nobody told them about.
Future<void> showCannotReceiveSheet(
  BuildContext context, {
  required String toPhone,
  required String toName,
}) {
  final digits = toPhone.replaceAll(RegExp(r'\D'), '');
  final contact = ChatStore.instance.chatWithContact(toPhone)?.contact;
  final lightning = contact?.lightningAddress ?? '';
  final canLightning = LightningAddress.isValid(lightning);

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$toName can\'t receive money yet',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Nothing was charged. A transfer needs them to set up payments '
              'first, which only they can do — there is nowhere for it to '
              'land until they have.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.4, color: AppColors.subtle(context)),
            ),
            const SizedBox(height: 16),
            if (canLightning) ...[
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  showLightningSparkSheet(context,
                      address: lightning, name: toName);
                },
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('Send bitcoin instead'),
              ),
              const SizedBox(height: 6),
              Text(
                'They take Lightning, which needs no setup on their side.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 14),
            ],
            _NudgeButton(phone: digits, toPhone: toPhone, toName: toName),
          ],
        ),
      ),
    ),
  );
}

/// "Let them know" — sends an ordinary message into the conversation.
///
/// Deliberately a real message rather than a silent system ping: it lands in
/// the transcript both people can see, which is what makes it a thing the
/// sender said rather than something the app did in their name.
class _NudgeButton extends StatefulWidget {
  final String phone;
  final String toPhone;
  final String toName;
  const _NudgeButton(
      {required this.phone, required this.toPhone, required this.toName});

  @override
  State<_NudgeButton> createState() => _NudgeButtonState();
}

class _NudgeButtonState extends State<_NudgeButton> {
  @override
  Widget build(BuildContext context) {
    final already = _nudged.contains(widget.phone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: already ? null : _send,
          icon: const Icon(Icons.send_outlined, size: 18),
          label: Text(already ? 'Already asked' : 'Let them know'),
        ),
        const SizedBox(height: 6),
        Text(
          already
              ? 'You have asked them once. Nagging is not a feature.'
              : 'Sends them a message in your chat — nothing else happens.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: AppColors.subtle(context)),
        ),
      ],
    );
  }

  void _send() {
    const text =
        'I tried to send you a tip — set up payments in your Wallet and '
        'I\'ll try again.';
    final chat = ChatStore.instance.chatWithContact(widget.toPhone);
    final msg = Message(
      id: 'tip_nudge_${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      time: DateTime.now(),
      isMe: true,
    );
    // The local copy first, so the sender sees what they sent even if the
    // relay is not up; send() deliberately does not store.
    if (chat != null) ChatStore.instance.addMessage(chat.id, msg);
    RelayService.instance.send(widget.toPhone, msg);
    _nudged.add(widget.phone);
    setState(() {});
    Navigator.of(context).maybePop();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Asked ${widget.toName} to set up payments')));
  }
}

class _TipSheet extends StatelessWidget {
  /// Who the money goes to, as the caller wants it shown — '@handle' on the
  /// feeds, a plain name in a chat.
  final String toLabel;
  const _TipSheet({required this.toLabel});

  static const presets = <int>[21, 100, 500, 2100];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.attach_money, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Text('Tip $toLabel',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Real money, straight to them — the same person-to-person '
              'transfer as Send money in a chat. Tips are final.',
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final cents in presets) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.of(context).pop(cents),
                      child: Text(
                        cents % 100 == 0
                            ? '\$${cents ~/ 100}'
                            : '\$${(cents / 100).toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (cents != presets.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
