import 'package:flutter/material.dart';

import 'app_state.dart';
import 'relay/relay_service.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/call_screen.dart';
import 'state/call_service.dart';
import 'state/persistence.dart';
import 'state/scheduler.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Everything lives on the device: the phone-number identity and all chats
  // are loaded from (and saved to) local storage. If a relay is configured,
  // messages are delivered device-to-device over an ephemeral broadcast
  // channel (nothing is stored on any server).
  await Session.instance.load();
  await Persistence.init();
  await RelayService.instance.init();
  await Scheduler.instance.init();
  runApp(const OkayMessagingApp());
}

/// Shows the full-screen call UI on top of everything whenever there's an
/// active call, so an incoming call rings no matter what screen you're on.
class _CallOverlay extends StatelessWidget {
  final Widget child;
  const _CallOverlay({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallSession?>(
      valueListenable: CallService.instance.current,
      builder: (context, session, _) {
        return Stack(
          children: [
            child,
            if (session != null)
              Positioned.fill(child: CallScreen(session: session)),
          ],
        );
      },
    );
  }
}

class OkayMessagingApp extends StatelessWidget {
  const OkayMessagingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Okay Messaging',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          home: const AuthGate(),
          builder: (context, child) =>
              _CallOverlay(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
