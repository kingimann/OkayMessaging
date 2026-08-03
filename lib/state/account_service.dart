import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/user.dart';
import '../relay/relay_config.dart';
import '../util/account_code.dart';
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
    // An account code has no session, so the row goes through the
    // claim_numberless RPC (docs/directory_numberless.sql) — the one write
    // path anon holds, and it only opens code-shaped rows. Without this a
    // numberless account was simply absent from the directory, which is why
    // nobody could find one by its handle.
    if (AccountCode.isCode(phone)) {
      try {
        final ok = await _client.rpc('claim_numberless', params: {
          'code': e164(phone),
          'uname': normalizeUsername(username),
          'display': name.trim(),
        });
        return ok != false; // false = handle taken; anything else best-effort
      } catch (_) {
        return true; // migration not run / offline — keep sign-up working
      }
    }
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

  /// Directory rows for a select+filter, asking for the verified column and
  /// falling back without it — the column exists only after
  /// docs/identity_directory_badge.sql has run, and a missing column must
  /// cost the badge, never the search.
  Future<List<Map<String, dynamic>>> _directoryRows(
      Future<List<Map<String, dynamic>>> Function(String columns)
          run) async {
    try {
      return await run('phone, username, name, verified');
    } catch (_) {
      return run('phone, username, name');
    }
  }

  /// Finds people whose username starts with [query] (case-insensitive) in the
  /// server directory — those who allow it. Returns an empty list when the
  /// backend is unavailable or nothing matches. Never throws.
  ///
  /// Asks through the `find_people` RPC first (docs/directory_numberless.sql):
  /// the directory's RLS speaks only to `authenticated`, so a numberless
  /// account querying the table directly got an empty answer FOREVER — not an
  /// error, an empty answer, which is why "search doesn't work" never showed
  /// up in a log. The RPC serves anon and authenticated the same rows an
  /// authenticated table read shows. The table read stays as the fallback for
  /// a project that has not run the migration yet.
  Future<List<AppUser>> searchByUsername(String query) async {
    final q = normalizeUsername(query);
    if (q.length < 2) return const [];
    final me = Session.instance.user.value?.phone;
    List<Map<String, dynamic>> rows;
    try {
      final raw = await _client.rpc('find_people', params: {'q': q});
      rows = [
        if (raw is List)
          for (final r in raw)
            if (r is Map) Map<String, dynamic>.from(r)
      ];
    } catch (_) {
      try {
        rows = await _directoryRows((columns) => _client
            .from(_table)
            .select(columns)
            .ilike('username', '$q%')
            // Reachability choice: rows that closed the username door stay
            // out of results. neq keeps unmigrated rows (null) visible.
            .neq('find_by_username', false)
            .limit(25));
      } catch (_) {
        return const [];
      }
    }
    final out = <AppUser>[];
    for (final row in rows) {
      final user = _rowToUser(row);
      // Don't offer to message/call yourself.
      if (user != null && (me == null || e164(user.phone) != e164(me))) {
        out.add(user);
      }
    }
    out.sort((a, b) => a.username.compareTo(b.username));
    return out;
  }

  /// Looks up directory entries for a set of E.164 phone hashes — the contact
  /// sync path. Returns the matching people (those who use OkayMessenger).
  Future<List<AppUser>> lookupByPhoneHashes(List<String> hashes) async {
    if (hashes.isEmpty) return const [];
    final me = Session.instance.user.value?.phone;
    try {
      final rows = await _directoryRows((columns) => _client
          .from(_table)
          .select(columns)
          .inFilter('phone_hash', hashes)
          .neq('find_by_phone', false)
          .limit(500));
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
      // The server's own verdict, written only by the identity webhook —
      // stronger than the self-attested badge on relay traffic.
      verified: row['verified'] as bool? ?? false,
    );
  }

  /// [_rowToUser], reachable from tests.
  @visibleForTesting
  static AppUser? debugRowToUser(Map<String, dynamic> row) => _rowToUser(row);

  /// Test hook: replaces the reachability round trip.
  @visibleForTesting
  static Future<(bool, bool)> Function()? debugGetReachabilityOverride;
  @visibleForTesting
  static Future<bool> Function(bool byUsername, bool byPhone)?
      debugSetReachabilityOverride;

  /// Which doors this account keeps open: (byUsername, byPhone). Defaults to
  /// both when the row or the migrated columns don't exist yet.
  Future<(bool, bool)> getReachability() async {
    final debug = debugGetReachabilityOverride;
    if (debug != null) return debug();
    final phone = Session.instance.user.value?.phone;
    if (phone == null) return (true, true);
    try {
      final rows = await _client
          .from(_table)
          .select('find_by_username, find_by_phone')
          .eq('phone', e164(phone))
          .limit(1);
      if (rows.isEmpty) return (true, true);
      return (
        rows.first['find_by_username'] as bool? ?? true,
        rows.first['find_by_phone'] as bool? ?? true,
      );
    } catch (_) {
      return (true, true); // unmigrated directory: both doors open, as ever
    }
  }

  /// Stores which doors stay open. False when it could not be saved (offline,
  /// unmigrated directory, or no signed-in row to save onto).
  Future<bool> setReachability(
      {required bool byUsername, required bool byPhone}) async {
    final debug = debugSetReachabilityOverride;
    if (debug != null) return debug(byUsername, byPhone);
    final phone = Session.instance.user.value?.phone;
    if (phone == null) return false;
    try {
      await _client.from(_table).update({
        'find_by_username': byUsername,
        'find_by_phone': byPhone,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('phone', e164(phone));
      return true;
    } catch (_) {
      return false;
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

  /// The account behind [username]: its E.164 phone and display name, or
  /// null when nobody owns it (or the directory is unreachable).
  ///
  /// This is what makes "sign in with username" possible without any new
  /// credential: the username locates the account, and the SMS code to its
  /// phone stays the thing that proves you own it.
  Future<(String, String)?> accountForUsername(String username) async {
    final normalized = normalizeUsername(username);
    if (!isValidUsername(normalized)) return null;
    // The RPC first, for the same reason searchByUsername asks it first: at
    // the sign-in screen the caller is ANONYMOUS, and the directory's RLS
    // answers anon with empty rows — so the table read below found nobody,
    // ever, and every signed-out username lookup (numberless accounts above
    // all, which have no other way back in) died with "no account found".
    try {
      final raw = await _client.rpc('find_people', params: {'q': normalized});
      if (raw is List) {
        for (final r in raw) {
          if (r is! Map) continue;
          if ((r['username'] as String?) != normalized) continue;
          final phone = r['phone'] as String?;
          if (phone != null && phone.isNotEmpty) {
            return (phone, (r['name'] as String?)?.trim() ?? '');
          }
        }
      }
    } catch (_) {
      // The migration may not be run — the table read below still answers
      // for signed-in callers.
    }
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

  /// The reason [password] is not good enough, or null when it is. Pure, so
  /// the rule is checked before a round trip rather than by reading a server
  /// error back to somebody.
  ///
  /// Eight characters and nothing else. Composition rules — a capital, a
  /// digit, a symbol — push people towards Password1! and are worse than
  /// length; Supabase enforces its own minimum on top of this.
  static String? passwordProblem(String password) {
    if (password.isEmpty) return 'Enter a password.';
    if (password.length < minPasswordLength) {
      return 'At least $minPasswordLength characters.';
    }
    return null;
  }

  static const int minPasswordLength = 8;

  /// Sets (or replaces) the password on the signed-in account.
  ///
  /// Needs a live Supabase session, which means a build that verifies numbers
  /// and somebody who has just signed in — the password is a second way back
  /// into an account that already exists, not a way to make one.
  Future<void> setPassword(String password) =>
      _client.auth.updateUser(UserAttributes(password: password));

  /// Signs in with an email and a password, returning the E.164 phone of the
  /// account behind them — or null when that account carries no phone.
  ///
  /// SAME CONTRACT AS [verifyEmailCode], and for the same reason: messaging
  /// identity here is the number, so a session with none is a half sign-in
  /// and is discarded rather than carried into the app.
  Future<String?> signInWithPassword(String email, String password) async {
    final res = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
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

  /// Whether this account already has a password set on it.
  ///
  /// Supabase does not expose the hash, and there is no flag for it — what it
  /// does expose is which providers are on the identity. 'email' appears once
  /// an email credential exists.
  /// False wherever there is no Supabase to ask — a build with no relay, and
  /// every test. Reading [_client] there throws, and a getter used to choose
  /// a label must not be able to take a screen down.
  bool get hasPassword {
    if (!RelayConfig.isEnabled) return false;
    try {
      final identities = _client.auth.currentUser?.identities ?? const [];
      return identities.any((i) => i.provider == 'email');
    } catch (_) {
      return false;
    }
  }

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
