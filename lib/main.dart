import 'package:flutter/material.dart';

import 'app_state.dart';
import 'config/backend_config.dart';
import 'screens/auth/auth_gate.dart';
import 'services/supabase_service.dart';
import 'state/persistence.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Real backend when configured; otherwise the local demo data is used.
  await SupabaseService.instance.init();
  if (!BackendConfig.isConfigured) {
    await Persistence.init();
  } else {
    await Persistence.initPreferencesOnly();
  }
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
