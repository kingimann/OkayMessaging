import 'package:flutter/material.dart';

import '../screens/auth/numberless_verify_screen.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';

/// Stands in front of everything a username-only account cannot use.
///
/// Signing up without a phone number is a real choice, not a lesser one — but
/// it is a choice with consequences, and every one of them is somebody else's
/// problem to trust. An account with no number cannot be found from anybody's
/// contacts, cannot pass the ID check, and — this is the part that decides the
/// gate — has no Supabase session at all, because Supabase authenticates a
/// phone. So the directory, the newsfeed, payments and moderation have nothing
/// to answer with.
///
/// **Chat is the exception, and it is not a concession.** Message delivery
/// rides Realtime broadcast on `inbox_<digits>` and the `mailbox` table, both
/// of which the anon key reaches. So chat genuinely works — the same
/// encryption, the same delivery, the same store-and-forward — and the account
/// code takes the place of the number everywhere the addressing needs one.
///
/// WRAPPED AROUND THE SCREEN, not bolted onto the row that opens it, for the
/// same reason as [VerifiedGate]: a drawer row is one way in, and a deep link
/// or a shared listing is another.
///
/// This gate is deliberately blunt where the verified one is careful. There is
/// no owner waiver: an owner without a phone number has no session either, so
/// letting them through would show them a screen that cannot load.
class PhoneGate extends StatelessWidget {
  const PhoneGate({
    super.key,
    required this.title,
    required this.reason,
    required this.child,
    this.scaffold = true,
  });

  /// What is behind the gate — "Wallet", "Newsfeed", "Calls".
  final String title;

  /// Why this one needs a number. Generic text on eight screens reads as a
  /// policy nobody thought about, and each of these is locked for its own
  /// reason: some need the directory, some need a verified identity, some
  /// need a server session to exist at all.
  final String reason;

  /// False when this is a tab body rather than a pushed screen — the home
  /// screen already has an app bar, and a second one inside it is a bar with
  /// nothing to do stacked under the real one.
  final bool scaffold;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Session.instance.user,
      builder: (context, _) {
        if (!Session.instance.isNumberless) return child;
        final body = Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_locked_outlined,
                    size: 54, color: AppColors.subtle(context)),
                const SizedBox(height: 18),
                Text(
                  '$title needs a phone number',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14.5,
                      height: 1.45,
                      color: AppColors.subtle(context)),
                ),
                const SizedBox(height: 8),
                Text(
                  'Chats work as they are. Verify a number to use the rest — '
                  'your account and everything on this device are kept.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.45,
                      color: AppColors.subtle(context)),
                ),
                const SizedBox(height: 18),
                // An in-place upgrade, not "sign out and start over": the
                // account and all its on-device data are kept.
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                        builder: (_) => const NumberlessVerifyScreen()),
                  ),
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: const Text('Verify your number'),
                ),
              ],
            ),
          ),
        );
        if (!scaffold) return body;
        return Scaffold(appBar: AppBar(title: Text(title)), body: body);
      },
    );
  }
}

/// The read-only rule for the public surfaces (newsfeed, servers): a
/// username-only account may LOOK but not create content. Reading is served by
/// the anon key, so browsing works; but every write needs the Supabase session
/// a numberless account doesn't have, and — the part that decides it — a public
/// post with no number behind it has nobody to answer for it, which is exactly
/// the spam a name-only signup would otherwise wave through.
///
/// Returns true (and shows the reason) when this account may not post, so a
/// caller reads as `if (postNeedsPhone(context)) return;`.
bool postNeedsPhone(BuildContext context, {String what = 'Posting'}) {
  if (!Session.instance.isNumberless) return false;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.phone_locked_outlined,
              size: 44, color: AppColors.subtle(context)),
          const SizedBox(height: 14),
          Text('$what needs a phone number',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(
            'You can read and follow along with a name-only account. Adding a '
            'post, reply or reaction needs a phone number — it\'s what a public '
            'post is answered for. Verify a number to post; your account and '
            'everything on this device are kept.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13.5, height: 1.45, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop(); // close the sheet first
              Navigator.of(context).push(
                MaterialPageRoute<bool>(
                    builder: (_) => const NumberlessVerifyScreen()),
              );
            },
            icon: const Icon(Icons.verified_user_outlined, size: 18),
            label: const Text('Verify your number'),
          ),
        ],
      ),
    ),
  );
  return true;
}

/// A quiet padlock on a row that leads somewhere a username-only account
/// cannot go, so the gate is not a surprise at the end of a tap. Nothing at
/// all on an account that has a number.
///
/// Mirrors [PhoneGate] exactly, and has to keep mirroring it: a padlock on a
/// row that opens is a worse lie than no padlock at all.
class PhoneOnlyHint extends StatelessWidget {
  const PhoneOnlyHint({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Session.instance.user,
        builder: (context, _) => Session.instance.isNumberless
            ? Tooltip(
                message: 'Needs a phone number',
                child: Icon(Icons.lock_outline,
                    size: 17, color: AppColors.subtle(context)),
              )
            : const SizedBox.shrink(),
      );
}
