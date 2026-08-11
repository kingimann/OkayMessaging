import 'package:flutter/material.dart';

import '../screens/auth/numberless_verify_screen.dart';
import '../state/numberless_grace.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';

/// The standing reminder that a name-only account is on a 14-day clock.
///
/// It exists because the deletion is irreversible and takes somebody's chats
/// with it. A warning shown once at sign-up is not consent to that two weeks
/// later, so this says the same thing every day the account is open, names
/// the days remaining, and carries the one action that stops it.
///
/// It cannot be dismissed. A dismissed warning is exactly the one somebody
/// swipes away on day two and never sees again on day thirteen.
class NumberlessGraceBanner extends StatelessWidget {
  const NumberlessGraceBanner({super.key});

  /// Whether it will draw anything right now.
  ///
  /// Home has to know BEFORE it lays out, not merely render the widget and
  /// let it decide: on the two tabs that hide home's own app bar (Newsfeed
  /// and Okay AI) the body starts at the very top of the SCREEN, so whoever
  /// is first in that column is the thing standing in the status bar. If it
  /// is this banner, it has to take the inset — and the tab under it must
  /// then stop taking it a second time.
  static bool get showing =>
      Session.instance.isNumberless && NumberlessGrace.instance.running;

  /// What home listens to so it re-lays-out the moment [showing] flips.
  static Listenable get listenable =>
      Listenable.merge([NumberlessGrace.instance, Session.instance.user]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [NumberlessGrace.instance, Session.instance.user]),
      builder: (context, _) {
        final grace = NumberlessGrace.instance;
        if (!Session.instance.isNumberless || !grace.running) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        // Amber while there is time, the error colour in the last three days.
        // The change is the point: a banner that looks the same on day one
        // and day fourteen has stopped being information.
        final urgent = grace.urgent;
        final bg = urgent
            ? scheme.errorContainer
            : scheme.tertiaryContainer.withValues(alpha: 0.55);
        final fg = urgent ? scheme.onErrorContainer : AppColors.subtle(context);
        return Material(
          color: bg,
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NumberlessVerifyScreen())),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Icon(urgent ? Icons.warning_amber : Icons.schedule,
                      size: 18, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          grace.bannerText,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: fg),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Add a phone number to keep it — and pick your own '
                          'username.',
                          style: TextStyle(
                              fontSize: 12, height: 1.3, color: fg),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right, size: 18, color: fg),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
