import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/backend_config.dart';
import '../../services/supabase_chat_service.dart';
import '../../services/supabase_service.dart';
import '../home_screen.dart';
import 'login_screen.dart';

/// Decides what to show at the root: in demo mode, straight to [HomeScreen];
/// with a backend configured, the [LoginScreen] until signed in, then the
/// home screen (after kicking off the realtime chat sync).
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _startedForUser;

  @override
  Widget build(BuildContext context) {
    if (!BackendConfig.isConfigured) {
      return const HomeScreen();
    }
    return StreamBuilder<AuthState>(
      stream: SupabaseService.instance.onAuthChange,
      builder: (context, _) {
        final userId = SupabaseService.instance.currentUserId;
        if (userId == null) {
          _startedForUser = null;
          SupabaseChatService.instance.stop();
          return const LoginScreen();
        }
        // Start (or restart, after a user switch) the realtime sync once.
        if (_startedForUser != userId) {
          _startedForUser = userId;
          SupabaseChatService.instance.start();
        }
        return const HomeScreen();
      },
    );
  }
}
