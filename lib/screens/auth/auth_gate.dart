import 'package:flutter/material.dart';

import '../../models/user.dart';
import '../../relay/relay_service.dart';
import '../../state/session.dart';
import '../home_screen.dart';
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
        }
        return const HomeScreen();
      },
    );
  }
}
