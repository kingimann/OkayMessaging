import 'package:flutter/material.dart';

import 'app_state.dart';
import 'relay/relay_service.dart';
import 'screens/auth/auth_gate.dart';
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
        );
      },
    );
  }
}
