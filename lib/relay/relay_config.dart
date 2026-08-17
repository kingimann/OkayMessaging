import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  /// Whether this device holds a Supabase session carrying a PHONE CLAIM —
  /// the only condition under which any `authenticated`-granted table or RPC
  /// will answer.
  ///
  /// **Every write that needs one has to ask before sending.** A name-only
  /// account has no session at all, so it reaches Postgres as `anon` — which
  /// holds no grant on those tables — and is refused with
  /// `42501 permission denied for table …` BEFORE RLS is ever consulted.
  /// Every one of those calls is swallowed by a bare catch, so the only place
  /// it shows up is the project's own Postgres log, as a storm: one line per
  /// chat, per server, per sync, on every launch and every pull-to-refresh.
  /// That is what this getter exists to stop.
  ///
  /// The claim, not merely a session: a session with no phone reads as
  /// anonymous to `callerPhone()` and to all 135 `auth.jwt() ->> 'phone'`
  /// conditions, so its writes fail too — just at RLS instead of at the
  /// grant.
  ///
  /// Lives HERE rather than beside the other session helpers because
  /// `account_verification.dart` reaches `session.dart`, which imports the
  /// relay: this file is the leaf both sides can see.
  ///
  /// False wherever there is nothing to ask — a relay-less build, and every
  /// test — so reading it can never take a caller down.
  static bool get hasSession {
    final override = debugHasSession;
    if (override != null) return override;
    if (!isEnabled) return false;
    try {
      return (Supabase.instance.client.auth.currentUser?.phone ?? '')
          .isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Test seam: there is no Supabase in the suite, so the true branch could
  /// not otherwise be exercised.
  @visibleForTesting
  static bool? debugHasSession;
}
