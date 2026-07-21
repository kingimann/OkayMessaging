import 'package:flutter/material.dart';

import '../../models/user.dart';
import '../../state/session.dart';
import '../home_screen.dart';
import 'phone_login_screen.dart';

/// Decides the root screen from the locally-stored phone identity: the
/// [PhoneLoginScreen] until you sign in, then the home screen. No server is
/// involved — the session lives only on this device.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUser?>(
      valueListenable: Session.instance.user,
      builder: (context, user, _) {
        if (user == null) return const PhoneLoginScreen();
        return const HomeScreen();
      },
    );
  }
}
