/// Backend configuration, supplied at build time via --dart-define so no
/// secrets live in the repo:
///
///   flutter run --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///               --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
///
/// When both values are present the app runs against a real Supabase backend
/// (accounts + realtime messaging + storage). When they're absent it falls
/// back to the self-contained local demo, so the app always runs.
class BackendConfig {
  BackendConfig._();

  static const String supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');

  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// True when a real backend is configured; otherwise the app is in demo mode.
  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
