import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/backend_config.dart';

/// Thin wrapper around Supabase initialization and auth. All backend access
/// goes through here so the rest of the app never imports Supabase directly.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  bool _initialized = false;

  /// Initializes Supabase when a backend is configured. No-ops in demo mode.
  Future<void> init() async {
    if (!BackendConfig.isConfigured || _initialized) return;
    await Supabase.initialize(
      url: BackendConfig.supabaseUrl,
      // The publishable ("anon") key is safe to ship in a web client; RLS
      // policies (see supabase/schema.sql) enforce access, not key secrecy.
      publishableKey: BackendConfig.supabaseAnonKey,
    );
    _initialized = true;
  }

  SupabaseClient get client => Supabase.instance.client;
  GoTrueClient get auth => client.auth;

  /// The signed-in user's id, or null when signed out / in demo mode.
  String? get currentUserId => _initialized ? auth.currentUser?.id : null;

  bool get isSignedIn => currentUserId != null;

  /// Emits on every sign-in / sign-out so the UI can react (an auth gate).
  Stream<AuthState> get onAuthChange => auth.onAuthStateChange;

  /// Creates an account and a matching profile row.
  Future<void> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    final res = await auth.signUp(email: email, password: password);
    final user = res.user;
    if (user != null) {
      await client.from('profiles').upsert({
        'id': user.id,
        'name': name,
        'about': 'Hey there! I am using Okay Messaging.',
        'avatar_color': _colorForName(name),
      });
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() => auth.signOut();

  /// A stable placeholder avatar color derived from the display name.
  static String _colorForName(String name) {
    const palette = [
      '#E57373', '#64B5F6', '#BA68C8', '#4DB6AC',
      '#FFB74D', '#A1887F', '#4DD0E1', '#81C784',
    ];
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}
