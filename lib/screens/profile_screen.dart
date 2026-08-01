// What was the "You" tab lives in one profile screen now
// (PublicProfileScreen), used for everybody. Two implementations meant two
// layouts and two sets of facts for one person, and any field added to a
// profile had to be added twice or it existed on one and not the other.
//
// What is left here are the pieces that screen uses.
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../state/account_email.dart';
import '../state/account_service.dart';
import '../state/identity_verification.dart';
import '../state/session.dart';
import 'account_email_screen.dart';
import 'score_screen.dart';

/// One number on a profile.
class ProfileStat extends StatelessWidget {
  final String value;
  final String label;
  final VoidCallback? onTap;
  const ProfileStat(
      {super.key, required this.value, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        // The number and what it counts on one line. Stacked, four of them
        // needed more width than a phone has, and the row they sat in was
        // scaled down to fit — which is how a profile ends up with counts too
        // small to read.
        child: Row(
          mainAxisSize: MainAxisSize.min,
          // Two sizes on one line only look like one line if they sit on the
          // same baseline.
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(fontSize: 14.5, color: AppColors.subtle(context))),
          ],
        ),
      ),
    );
  }
}

/// Three chips saying what this account has proven: phone, email, identity.
/// What this account has proven, at a glance. Public because there is one
/// profile screen now and it lives elsewhere.
class ProfileVerificationRow extends StatelessWidget {
  const ProfileVerificationRow({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [AccountEmail.instance, IdentityVerification.instance]),
      builder: (context, _) {
        // The phone is verified when sign-in went through the SMS code —
        // that is what "verified" means here. Local mode never claims it.
        final phoneVerified =
            AccountService.isEnabled && Session.instance.isSignedIn;
        final email = AccountEmail.instance;
        final identity = IdentityVerification.instance;
        return Wrap(
          // Left, like the name, the handle, the bio and the counts above it.
          // Centred, these three chips were the only thing on the profile that
          // did not start at the same margin, which reads as a stray block.
          alignment: WrapAlignment.start,
          spacing: 6,
          runSpacing: 6,
          children: [
            _chip(
              context,
              icon: Icons.sms_outlined,
              label: phoneVerified ? 'Phone verified' : 'Verify phone',
              done: phoneVerified,
              onTap: null, // nothing to do from here; sign-in decides it
            ),
            _chip(
              context,
              icon: Icons.alternate_email,
              label: !email.isSet
                  ? 'Add email'
                  : email.isVerified
                      ? 'Email verified'
                      : 'Confirm email',
              done: email.isSet && email.isVerified,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const AccountEmailScreen())),
            ),
            _chip(
              context,
              icon: Icons.verified_outlined,
              // Short enough that all three fit one line on a 390pt phone.
              // "Get the blue check" is what the score screen calls it, but
              // spelled out here it pushed the third chip onto a second row.
              label: identity.isVerified
                  ? 'ID verified'
                  : identity.isPending
                      ? 'ID pending'
                      : 'Get verified',
              done: identity.isVerified,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const ScoreScreen())),
            ),
          ],
        );
      },
    );
  }

  /// One state, as small as it can be and still be read.
  ///
  /// These were filled pills at 13pt with 13 points of side padding, and three
  /// of them do not fit a 390pt phone — so the row wrapped, and a profile had
  /// two ragged lines of grey lozenges in the middle of it. Smaller type, less
  /// padding, and an outline instead of a fill: they sit on one line and read
  /// as status rather than as three more buttons.
  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool done,
    VoidCallback? onTap,
  }) {
    final fg = done ? const Color(0xFF12B76A) : AppColors.subtle(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: done
                  ? const Color(0xFF12B76A).withValues(alpha: 0.45)
                  : Theme.of(context).dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(done ? Icons.check_circle : icon, size: 13, color: fg),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}
