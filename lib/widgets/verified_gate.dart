import 'package:flutter/material.dart';

import '../screens/score_screen.dart';
import '../state/identity_verification.dart';
import '../state/platform_moderation.dart';
import '../state/session.dart';
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
///
/// **The owner waives it where it is ours to waive** ([ownerMayPass]). The
/// check exists so a stranger has a reason to trust an account; whoever runs
/// the app is answerable by definition, and locking them out of their own
/// marketplace is a rule enforcing itself against the person who set it.
///
/// That stops at the point the requirement stops being the app's. Sending
/// money needs a verified legal name to put on the Stripe intent, and the
/// capture gate compares against it — `payments-create-intent` returns
/// `identity_required` without one, whatever role the caller holds. Opening
/// that screen for an owner would replace an explanation with a dead end, so
/// [ownerMayPass] defaults to false and the wallet leaves it there.
class VerifiedGate extends StatelessWidget {
  const VerifiedGate({
    super.key,
    required this.title,
    required this.reason,
    required this.child,
    this.ownerMayPass = false,
    this.ownerReason = '',
    this.numberlessMayPass = false,
    this.scaffold = true,
  });

  /// False when this stands inside something that already has an app bar — a
  /// home tab, or a tab of the Money screen. Same flag [PhoneGate] and
  /// [ParentalGate] already carry, and for the same reason: a second bar
  /// under the real one is a bar with nothing to do.
  final bool scaffold;

  /// Whether running the app is enough to get in. True only where the ID check
  /// is this app's own policy — false where something outside it needs the
  /// verified identity itself. Defaults to false so a gate added later closes
  /// rather than opens by accident.
  final bool ownerMayPass;

  /// Whether an account with no phone number passes. False almost everywhere:
  /// verification needs a session and a numberless account has none, so the
  /// gate would otherwise be a door with no key. True only where the check is
  /// the app's own policy AND the feature itself needs no server (Okay Drop —
  /// two phones and a radio), where holding the gate would lock the feature
  /// forever rather than until verification.
  final bool numberlessMayPass;

  /// What to say to an owner who is still held — because "needs a verified
  /// account" reads as a bug to the person who owns the account.
  final String ownerReason;

  /// What is behind the gate, for the bar at the top and the sentence under
  /// it — "Marketplace", "Wallet", "Okay Drop".
  final String title;

  /// Why this one in particular needs it. Generic text on three different
  /// screens reads as a policy nobody thought about.
  final String reason;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        IdentityVerification.instance,
        PlatformModeration.instance,
        Session.instance.user,
      ]),
      builder: (context, _) {
        final identity = IdentityVerification.instance;
        final owner = PlatformModeration.instance.isOwner;
        // The waiver covers the owner's TEAM (admin + owner, 2026-08-04):
        // a role only the owner can grant, from a table no client can
        // write — a stronger identity claim than a document check, on the
        // surfaces where the check is ours to waive at all.
        if (identity.allowsTrusted ||
            (PlatformModeration.instance.canAdminister && ownerMayPass) ||
            (numberlessMayPass && Session.instance.isNumberless)) {
          return child;
        }
        final body = Center(
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
                        : owner
                            ? 'Even you need this one'
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
                        : owner && ownerReason.isNotEmpty
                            ? ownerReason
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
          );
        return scaffold
            ? Scaffold(appBar: AppBar(title: Text(title)), body: body)
            : body;
      },
    );
  }
}
