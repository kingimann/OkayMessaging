import 'package:flutter/material.dart';

import '../../models/user.dart';
import '../../relay/relay_service.dart';
import '../../state/identity_verification.dart';
import '../../state/legal_consent.dart';
import '../../state/platform_moderation.dart';
import '../../state/push_service.dart';
import '../../state/session.dart';
import '../home_screen.dart';
import 'legal_consent_screen.dart';
import 'phone_login_screen.dart';

/// Decides the root screen from the locally-stored phone identity: the
/// [PhoneLoginScreen] until you sign in, then the home screen. The session
/// lives only on this device; on sign-in we also start the (optional) relay
/// so messages can reach other devices.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _startedForPhone;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUser?>(
      valueListenable: Session.instance.user,
      builder: (context, user, _) {
        if (user == null) {
          if (_startedForPhone != null) {
            _startedForPhone = null;
            RelayService.instance.stop();
          }
          return const PhoneLoginScreen();
        }
        if (_startedForPhone != user.phone) {
          _startedForPhone = user.phone;
          RelayService.instance.start();
          PushService.instance.register();
          // Both of these are answers about *this account*, keyed on the
          // phone in the session JWT — so they have to be asked again when
          // the account changes, and when one appears at all. The launch-time
          // read happens before anybody has signed in, so on the first run
          // after a sign-in it asked on behalf of nobody.
          //
          // This is also what makes a role granted in SQL show up: sign out,
          // sign back in, and the console is there.
          PlatformModeration.instance.refresh();
          IdentityVerification.instance.refresh();
        }
        // The current Terms & Privacy Policy must be agreed to before the
        // app opens — on first sign-in, and again after any update to them.
        return ListenableBuilder(
          listenable: LegalConsent.instance,
          builder: (context, _) => LegalConsent.instance.needsConsent
              ? const LegalConsentScreen()
              : const HomeScreen(),
        );
      },
    );
  }
}
