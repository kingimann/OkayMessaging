import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/user.dart';
import '../relay/relay_config.dart';
import 'session.dart';

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

  /// SHA-256 (hex) of the E.164 phone. The directory stores this so contact
  /// sync can match people by hash — the client sends hashes, never its raw
  /// address book — instead of uploading everyone's number in the clear.
  static String phoneHashHex(String phone) =>
      sha256.convert(utf8.encode(e164(phone))).toString();

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
  ///
  /// Returns false when the username is already taken by someone else — the
  /// database's case-insensitive unique index rejects the write with a unique
  /// violation (23505), which makes uniqueness authoritative even if the
  /// pre-check was bypassed. Other/transient errors return true (best-effort;
  /// the username is still stored locally by [Session]).
  Future<bool> claimUsername(String phone, String username,
      {String name = ''}) async {
    final core = {
      'phone': e164(phone),
      'username': normalizeUsername(username),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    // The directory columns (name, phone_hash) only exist once the schema
    // migration has been run; if the write fails because they're missing we
    // retry with just the core fields so username claiming still works.
    final full = {
      ...core,
      'name': name.trim(),
      'phone_hash': phoneHashHex(phone),
    };
    try {
      await _client.from(_table).upsert(full);
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return false; // username taken (unique violation)
      try {
        await _client.from(_table).upsert(core);
      } catch (_) {}
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Finds people whose username starts with [query] (case-insensitive) in the
  /// server directory. Returns an empty list when the backend is unavailable
  /// or nothing matches. Never throws.
  Future<List<AppUser>> searchByUsername(String query) async {
    final q = normalizeUsername(query);
    if (q.length < 2) return const [];
    final me = Session.instance.user.value?.phone;
    try {
      final rows = await _client
          .from(_table)
          .select('phone, username, name')
          .ilike('username', '$q%')
          .limit(25);
      final out = <AppUser>[];
      for (final row in rows) {
        final user = _rowToUser(Map<String, dynamic>.from(row));
        // Don't offer to message/call yourself.
        if (user != null && (me == null || e164(user.phone) != e164(me))) {
          out.add(user);
        }
      }
      out.sort((a, b) => a.username.compareTo(b.username));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Looks up directory entries for a set of E.164 phone hashes — the contact
  /// sync path. Returns the matching people (those who use OkayMessenger).
  Future<List<AppUser>> lookupByPhoneHashes(List<String> hashes) async {
    if (hashes.isEmpty) return const [];
    final me = Session.instance.user.value?.phone;
    try {
      final rows = await _client
          .from(_table)
          .select('phone, username, name')
          .inFilter('phone_hash', hashes)
          .limit(500);
      final out = <AppUser>[];
      for (final row in rows) {
        final user = _rowToUser(Map<String, dynamic>.from(row));
        if (user != null && (me == null || e164(user.phone) != e164(me))) {
          out.add(user);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Builds an [AppUser] from a directory row. Avatar colour is derived from
  /// the phone number so it isn't stored server-side. Returns null if the row
  /// is missing the phone key.
  static AppUser? _rowToUser(Map<String, dynamic> row) {
    final phone = row['phone'] as String?;
    if (phone == null || phone.isEmpty) return null;
    final username = (row['username'] as String?) ?? '';
    final name = (row['name'] as String?)?.trim() ?? '';
    return AppUser(
      id: phone,
      name: name.isNotEmpty ? name : (username.isNotEmpty ? '@$username' : phone),
      avatarColor: Session.colorForPhone(phone),
      phone: phone,
      username: username,
    );
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

  /// The account behind [username]: its E.164 phone and display name, or
  /// null when nobody owns it (or the directory is unreachable).
  ///
  /// This is what makes "sign in with username" possible without any new
  /// credential: the username locates the account, and the SMS code to its
  /// phone stays the thing that proves you own it.
  Future<(String, String)?> accountForUsername(String username) async {
    final normalized = normalizeUsername(username);
    if (!isValidUsername(normalized)) return null;
    try {
      final rows = await _client
          .from(_table)
          .select('phone, name')
          .eq('username', normalized)
          .limit(1);
      if (rows.isEmpty) return null;
      final phone = rows.first['phone'] as String?;
      if (phone == null || phone.isEmpty) return null;
      return (phone, (rows.first['name'] as String?)?.trim() ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Emails a one-time code to [email]. Sign-in only, never account
  /// creation: identity here is the phone, and an email is a door back to an
  /// account that attached one — not a substitute identity.
  Future<void> sendEmailCode(String email) => _client.auth
      .signInWithOtp(email: email.trim(), shouldCreateUser: false);

  /// Verifies the emailed [code] and returns the E.164 phone of the account
  /// the email belongs to — or null when that account carries no phone, in
  /// which case the caller must not proceed (messaging identity IS the
  /// phone) and the half-made session is discarded.
  Future<String?> verifyEmailCode(String email, String code) async {
    final res = await _client.auth.verifyOTP(
      type: OtpType.email,
      email: email.trim(),
      token: code.trim(),
    );
    final phone = res.user?.phone ?? '';
    if (phone.isEmpty) {
      try {
        await _client.auth.signOut();
      } catch (_) {}
      return null;
    }
    return phone;
  }

  /// "••• ••• 1234" — enough of a phone to recognise your own, not enough to
  /// harvest someone else's from their username. Pure.
  static String maskPhone(String phone) {
    final digits = e164(phone);
    if (digits.length <= 4) return digits;
    return '••• ••• ${digits.substring(digits.length - 4)}';
  }

  /// What a login identifier is: 'email', 'username', or 'invalid'. Pure.
  ///
  /// An email has an @ with a domain after it; a username is bare word
  /// characters (a leading @ is tolerated, people type their handle that
  /// way). Anything else — spaces, half an email — is refused with a message
  /// rather than guessed at.
  static String loginIdentifierKind(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'invalid';
    if (RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$').hasMatch(t)) {
      return 'email';
    }
    // Judged as typed, not as normalizeUsername would repair it: "ada@" and
    // "has spaces" normalize to valid handles, but someone who typed them
    // meant something else — tell them, don't guess.
    final handle = t.startsWith('@') ? t.substring(1) : t;
    if (RegExp(r'^[A-Za-z0-9_.]{3,}$').hasMatch(handle)) return 'username';
    return 'invalid';
  }

  /// Whether the real (SMS-verified, server-checked) sign-in flow is active.
  /// Requires both a configured relay and the REQUIRE_OTP build flag.
  static bool get isEnabled => RelayConfig.isEnabled && RelayConfig.requireOtp;
}
