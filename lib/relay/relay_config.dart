/// Configuration for the optional message relay, supplied at build time:
///
///   flutter run --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///               --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
///
/// The relay uses **only** Supabase Realtime broadcast — an ephemeral pub/sub
/// channel. Messages are passed live between devices and are never written to
/// any database or storage. Each device keeps its own local copy. When these
/// values are absent the app is fully local (no cross-device delivery).
class RelayConfig {
  RelayConfig._();

  static const String supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');

  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// True when a relay is configured; otherwise messaging stays on-device only.
  static bool get isEnabled =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// When true, sign-in requires real SMS verification and a server-checked
  /// username (see [AccountService]). Left off until the Supabase project has
  /// an SMS provider enabled and the `usernames` table created — flip it on
  /// with `--dart-define=REQUIRE_OTP=true`. Keeping it off preserves the
  /// instant local login, so deploying the flow early never breaks sign-in.
  static const bool requireOtp =
      bool.fromEnvironment('REQUIRE_OTP', defaultValue: false);
}
