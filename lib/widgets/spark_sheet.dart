import 'package:flutter/material.dart';

import '../app_state.dart';
import '../payments/payment_service.dart';
import '../state/identity_verification.dart';
import '../state/push_service.dart';
import '../theme/app_theme.dart';

/// One-tap preset amounts for a Spark — 21 is the community's number.
/// Shared by the server feed and the public one, so the gesture costs the
/// same everywhere. Returns the chosen cents, or null.
Future<int?> showSparkSheet(BuildContext context, {required String toLabel}) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (_) => _SparkSheet(toLabel: toLabel),
  );
}

/// The whole spark flow against a known recipient — the same ladder the
/// feeds walk (can this device send, is the sender verified, can the
/// receiver be paid), then the one-tap sheet, then the REAL transfer, then
/// the push that tells them. Used wherever a message's sender can be
/// sparked directly: server channels, and anywhere else that holds a name
/// and digits rather than a post id. Returns true when money moved.
Future<bool> offerSparkTo(BuildContext context,
    {required String toPhone, required String toName}) async {
  final svc = PaymentService.instance;
  final messenger = ScaffoldMessenger.of(context);
  if (!svc.isConfigured) return false;
  if (!svc.canSendOnThisDevice && !svc.testMode.value) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Sparks are sent from the iPhone app.')));
    return false;
  }
  if (!IdentityVerification.instance.allowsTrusted) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Verify your ID to send money.')));
    return false;
  }
  if (!svc.testMode.value && !await svc.canReceive(toPhone)) {
    messenger.showSnackBar(SnackBar(
        content: Text('$toName hasn\'t set up payments, so sparks can\'t '
            'reach them yet.')));
    return false;
  }
  if (!context.mounted) return false;
  final cents = await showSparkSheet(context, toLabel: toName);
  if (cents == null || cents <= 0) return false;
  bool ok;
  try {
    ok = await svc.sendMoney(
      toPhone: toPhone,
      amountCents: cents,
      note: 'Spark ⚡',
      // The sheet said sparks are final before offering an amount.
      acknowledged: true,
    );
  } on PaymentException catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(switch (e.code) {
      'receiver_not_onboarded' =>
        '$toName hasn\'t set up payments, so sparks can\'t reach them yet.',
      'parental_locked' =>
        'Payments are turned off by parental controls on this phone.',
      _ => 'The spark couldn\'t be sent — ${e.code}.',
    })));
    return false;
  } catch (_) {
    return false;
  }
  if (!ok) return false;
  final myName = AppState.profile.value.name;
  PushService.instance.notify(toPhone,
      title: myName.isEmpty ? 'Spark' : myName,
      body: 'Sparked you \$${(cents / 100).toStringAsFixed(2)} ⚡');
  messenger.showSnackBar(SnackBar(
      content:
          Text('Sparked $toName \$${(cents / 100).toStringAsFixed(2)} ⚡')));
  return true;
}

class _SparkSheet extends StatelessWidget {
  /// Who the money goes to, as the caller wants it shown — '@handle' on the
  /// feeds, a plain name in a chat.
  final String toLabel;
  const _SparkSheet({required this.toLabel});

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
                const Icon(Icons.bolt, color: Color(0xFFF7931A)),
                const SizedBox(width: 8),
                Text('Spark $toLabel',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Real money, straight to them — the same person-to-person '
              'transfer as Send money in a chat. Sparks are final.',
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
