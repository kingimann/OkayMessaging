import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';

/// Result of checking a username against the server registry.
enum UsernameStatus {
  /// Free to claim.
  available,

  /// Already linked to a different verified number.
  taken,

  /// Already linked to *this* number (re-signing in with your own handle).
  mine,

  /// The username failed the format rules (too short / bad characters).
  invalid,
}

/// Talks to the server for the two — and only two — things it is allowed to
/// know about a user: that their phone number is verified (SMS OTP), and which
/// username is linked to that number. Everything else (messages, calls, chats)
/// stays on the device and is relayed without being stored.
///
/// All server calls use Supabase Auth (phone OTP) and the `usernames` table
/// created by `supabase/schema.sql`. The pure helpers are unit-tested; the
/// networked methods are thin wrappers so the logic stays verifiable.
class AccountService {
  AccountService._();
  static final AccountService instance = AccountService._();

  static const _table = 'usernames';

  SupabaseClient get _client => Supabase.instance.client;

  /// E.164 digits (no spaces, no '+') — the format Supabase Auth stores the
  /// verified phone as, and the key used in the registry.
  static String e164(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Lowercases and strips a leading '@' / invalid characters.
  static String normalizeUsername(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]'), '');

  /// True when [username] passes the format rules (3+ of letters/digits/_/.).
  static bool isValidUsername(String username) =>
      RegExp(r'^[a-z0-9_.]{3,}$').hasMatch(normalizeUsername(username));

  /// Sends a one-time SMS code to [phone]. Throws if the SMS provider is not
  /// enabled on the Supabase project.
  Future<void> sendCode(String phone) {
    return _client.auth.signInWithOtp(phone: e164(phone));
  }

  /// Verifies the SMS [code] for [phone], establishing an authenticated
  /// session (its JWT carries the verified phone for the registry's RLS).
  Future<void> verifyCode(String phone, String code) async {
    await _client.auth.verifyOTP(
      type: OtpType.sms,
      phone: e164(phone),
      token: code.trim(),
    );
  }

  /// Checks whether [username] can be used by the (already verified) [phone].
  ///
  /// Degrades gracefully: if the registry can't be reached (e.g. the
  /// `usernames` table hasn't been created yet, or a transient network error),
  /// it returns [UsernameStatus.available] so sign-in is never blocked —
  /// uniqueness enforcement simply activates once the table exists.
  Future<UsernameStatus> checkUsername(String phone, String username) async {
    final normalized = normalizeUsername(username);
    if (!isValidUsername(normalized)) return UsernameStatus.invalid;

    try {
      final rows = await _client
          .from(_table)
          .select('phone, username')
          .eq('username', normalized)
          .limit(1);
      if (rows.isEmpty) return UsernameStatus.available;
      final owner = rows.first['phone'] as String?;
      return owner == e164(phone) ? UsernameStatus.mine : UsernameStatus.taken;
    } catch (_) {
      return UsernameStatus.available;
    }
  }

  /// Claims (or updates) [username] for the verified [phone] in the registry.
  /// Best-effort: a failure here never blocks sign-in (the username is still
  /// stored locally by [Session]).
  Future<void> claimUsername(String phone, String username) async {
    try {
      await _client.from(_table).upsert({
        'phone': e164(phone),
        'username': normalizeUsername(username),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Registry not ready yet — proceed with the locally-stored username.
    }
  }

  /// Looks up the username currently linked to [phone] (null if none).
  Future<String?> usernameForPhone(String phone) async {
    final rows = await _client
        .from(_table)
        .select('username')
        .eq('phone', e164(phone))
        .limit(1);
    if (rows.isEmpty) return null;
    return rows.first['username'] as String?;
  }

  /// Whether the real (SMS-verified, server-checked) sign-in flow is active.
  /// Requires both a configured relay and the REQUIRE_OTP build flag.
  static bool get isEnabled => RelayConfig.isEnabled && RelayConfig.requireOtp;
}
