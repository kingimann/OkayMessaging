import 'package:flutter/material.dart';

import '../screens/score_screen.dart';
import '../state/identity_verification.dart';
import '../theme/app_theme.dart';

/// Stands in front of the parts of the app that involve money or strangers.
///
/// The marketplace, the wallet, and handing something to somebody nearby all
/// put an account in front of people who have no other reason to trust it —
/// a seller taking money, a card being charged, a stranger in the room being
/// offered a file. Passing the ID check is what turns a handle into a person
/// somebody can be answerable as.
///
/// WRAPPED AROUND THE SCREEN, not bolted onto the button that opens it. A
/// drawer row is one way in; a deep link, a listing in a chat and a share
/// sheet are others, and a gate on the row is a gate on one of them.
///
/// It is not a lock on a door with no key: [IdentityVerification.allowsTrusted]
/// is true wherever verification is impossible, which is every build without a
/// server behind it.
class VerifiedGate extends StatelessWidget {
  const VerifiedGate({
    super.key,
    required this.title,
    required this.reason,
    required this.child,
  });

  /// What is behind the gate, for the bar at the top and the sentence under
  /// it — "Marketplace", "Wallet", "Send nearby".
  final String title;

  /// Why this one in particular needs it. Generic text on three different
  /// screens reads as a policy nobody thought about.
  final String reason;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: IdentityVerification.instance,
      builder: (context, _) {
        final identity = IdentityVerification.instance;
        if (identity.allowsTrusted) return child;
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_outlined,
                      size: 54, color: AppColors.subtle(context)),
                  const SizedBox(height: 18),
                  Text(
                    identity.isPending
                        ? 'Your ID check is still being read'
                        : '$title needs a verified account',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    identity.isPending
                        ? 'Stripe is still working through your documents. '
                            'This opens as soon as they are done.'
                        : reason,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        color: AppColors.subtle(context)),
                  ),
                  const SizedBox(height: 24),
                  if (!identity.isPending)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        shape: const StadiumBorder(),
                      ),
                      // Where the check is actually started, and where the
                      // badge and what it is for are already explained.
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ScoreScreen())),
                      child: const Text('Get verified'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
