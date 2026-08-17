import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/user.dart';
import '../relay/app_pages.dart';
import '../relay/relay_config.dart';
import '../util/account_code.dart';
import '../util/email_identity.dart';
import '../util/phone_format.dart';
import '../util/voip_numbers.dart';
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
  /// enabled on the Supabase project, or (a backstop under the login form's
  /// own check) if the number is a toll-free / premium / VoIP range that can't
  /// stand behind an account.
  Future<void> sendCode(String phone) {
    final voip = VoipNumbers.reason(phone);
    if (voip != null) throw StateError(voip);
    return _client.auth.signInWithOtp(phone: _forProvider(phone));
  }

  /// The digits handed to the SMS provider. [e164] alone only strips
  /// punctuation, so a number that reached here without a country code went
  /// out as one — a local Toronto number became a Swiss one and the send was
  /// refused. Normalising here means no caller can skip it; it is a no-op on
  /// a number that already carries its country code.
  static String _forProvider(String phone) => e164(phoneToE164(phone));

  /// Verifies the SMS [code] for [phone], establishing an authenticated
  /// session (its JWT carries the verified phone for the registry's RLS).
  Future<void> verifyCode(String phone, String code) async {
    await _client.auth.verifyOTP(
      type: OtpType.sms,
      // Must match sendCode's normalisation exactly, or the code checks
      // against a different number than the one it was texted to.
      phone: _forProvider(phone),
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
      // Through the definer function, not the table: the directory no longer
      // lets one account read another's row, and asking "who holds this
      // handle" only ever needed the answer free/mine/taken — never the
      // number behind it (docs/directory_phone_privacy.sql).
      final r = await _client
          .rpc('username_status', params: {'uname': normalized});
      return switch (r as String?) {
        'available' => UsernameStatus.available,
        'mine' => UsernameStatus.mine,
        'taken' => UsernameStatus.taken,
        'invalid' => UsernameStatus.invalid,
        // An unrecognised answer is an older deployment; the unique index on
        // the table is the real guard, so let the claim try rather than
        // refusing a handle that may well be free.
        _ => UsernameStatus.available,
      };
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

  /// Hides or un-hides this account in the people directory — the server
  /// half of "deactivate temporarily" (docs/account_lifecycle.sql). Hidden
  /// rows answer no search while the handle stays reserved. Own-row RLS
  /// update, so it needs a session: numberless accounts have none, which is
  /// why the deactivate flow tells them their handle stays findable.
  /// Returns whether the server took it.
  Future<bool> setHidden(bool hidden) async {
    final me = Session.instance.user.value;
    if (me == null || AccountCode.isCode(me.phone)) return false;
    try {
      await _client.from(_table).update({
        'hidden': hidden,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('phone', e164(me.phone));
      return true;
    } catch (_) {
      return false; // migration not run yet, or offline
    }
  }

  /// Stamps this account's `last_seen = now()` in the directory, so the
  /// moderation roster can show who is online and when everyone else was last
  /// around (docs/admin_users.sql). Best-effort and silent: it needs a session,
  /// so a numberless account (no session) is a no-op — its last_seen stays null,
  /// which the roster reads honestly as "never seen". Called on sign-in and each
  /// time the app returns to the foreground.
  Future<void> touchLastSeen() async {
    final me = Session.instance.user.value;
    if (me == null || AccountCode.isCode(me.phone)) return;
    try {
      await _client.rpc('touch_last_seen');
    } catch (_) {
      // Migration not run yet, offline, or no session — none is worth a fuss.
    }
  }

  /// The one person who holds [username] exactly, with the phone needed to
  /// message or call them — or null when nobody does.
  ///
  /// This is the deliberate seam in docs/directory_phone_privacy.sql. A
  /// PREFIX search answers with handles and names and no numbers, because
  /// that is the shape that scales into a harvest; an EXACT handle is
  /// answered with a number, because that is what opening one conversation
  /// needs. So a screen that lists people asks once, and asks again — here —
  /// only when somebody actually picks one.
  Future<AppUser?> resolvePerson(String username) async {
    final normalized = normalizeUsername(username);
    if (!isValidUsername(normalized)) return null;
    for (final u in await searchByUsername(normalized)) {
      if (u.username.toLowerCase() == normalized && u.phone.isNotEmpty) {
        return u;
      }
    }
    return null;
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
    List<Map<String, dynamic>>? rows;
    try {
      final raw = await _client.rpc('find_people', params: {'q': q});
      rows = [
        if (raw is List)
          for (final r in raw)
            if (r is Map) Map<String, dynamic>.from(r)
      ];
    } catch (_) {
      // The supabase client attaches whatever session it holds — and a
      // session that EXPIRED server-side poisons every request with a 401,
      // which made the whole directory unsearchable on a phone whose
      // sign-in had lapsed. The search is public by design (the RPC serves
      // anon), so ask again with the anon key alone.
      rows = await _anonFindPeople(q);
    }
    // No table fallback any more. The directory's own rows are readable only
    // by the account they belong to, so a direct select answers nobody —
    // find_people IS the search now, for signed-in and signed-out alike.
    if (rows == null) return const [];
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

  /// The find_people RPC over bare HTTP with the anon key ALONE — no
  /// session token to be poisoned by. Null when unreachable (the caller
  /// falls to the table read).
  Future<List<Map<String, dynamic>>?> _anonFindPeople(String q) async {
    try {
      final res = await http
          .post(
            Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/rpc/find_people'),
            headers: {
              'apikey': RelayConfig.supabaseAnonKey,
              'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'q': q}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 300) return null;
      final raw = jsonDecode(res.body);
      return [
        if (raw is List)
          for (final r in raw)
            if (r is Map) Map<String, dynamic>.from(r)
      ];
    } catch (_) {
      return null;
    }
  }

  /// Looks up directory entries for a set of E.164 phone hashes — the contact
  /// sync path. Returns the matching people (those who use OkayMessenger).
  Future<List<AppUser>> lookupByPhoneHashes(List<String> hashes) async {
    if (hashes.isEmpty) return const [];
    final me = Session.instance.user.value?.phone;
    try {
      // A definer function rather than a table read. This one may still
      // answer with phones: the caller hashed them out of its own address
      // book, so the hash is proof it already holds every number that can
      // come back (docs/directory_phone_privacy.sql).
      final raw = await _client
          .rpc('find_people_by_hashes', params: {'hashes': hashes});
      final rows = [
        if (raw is List)
          for (final r in raw)
            if (r is Map) Map<String, dynamic>.from(r)
      ];
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

  /// Builds an [AppUser] from a directory row.
  ///
  /// **A phone-free row is normal now, not a broken one.** A prefix search
  /// answers with handles and names and no numbers
  /// (docs/directory_phone_privacy.sql), so this used to return null for
  /// every browsing result and the search screen would have shown nothing.
  /// Only a row with neither a phone nor a handle is unusable — there is
  /// nothing left to name or address the person by.
  ///
  /// [id] is what a chat is keyed on, so a phone-free user carries its
  /// '@handle' instead: unmistakably not a number, and the thing to resolve
  /// with when somebody actually opens the conversation. Avatar colour is
  /// derived rather than stored, from whichever of the two exists.
  static AppUser? _rowToUser(Map<String, dynamic> row) {
    final phone = (row['phone'] as String?) ?? '';
    final username = (row['username'] as String?) ?? '';
    if (phone.isEmpty && username.isEmpty) return null;
    final name = (row['name'] as String?)?.trim() ?? '';
    final key = phone.isNotEmpty ? phone : '@$username';
    return AppUser(
      id: key,
      name: name.isNotEmpty ? name : (username.isNotEmpty ? '@$username' : key),
      avatarColor: Session.colorForPhone(key),
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

  /// Whether [phone] already has an account. Used to refuse a SIGNUP (and a
  /// name-only account's attach) before a code is ever sent — two accounts on
  /// one number is a collision nobody can untangle afterwards.
  ///
  /// Signing IN with your own existing number is the normal path and must
  /// never consult this.
  ///
  /// FAILS OPEN (false) when it cannot be answered: a network hiccup must not
  /// lock a real new user out of signing up. The server is the real guard —
  /// the OTP still has to reach the number's owner.
  Future<bool> isPhoneTaken(String phone) async {
    final override = debugPhoneTakenOverride;
    if (override != null) return override(phone);
    if (!RelayConfig.isEnabled) return false;
    try {
      final r = await _client
          .rpc('is_phone_taken', params: {'p': e164(phone)})
          .timeout(const Duration(seconds: 6));
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// sha256 of the address exactly as written (lowercased and trimmed) — the
  /// ONLY form of an email that ever reaches the server, matching the
  /// `phone_hash` shape in schema.sql.
  ///
  /// Kept alongside [canonicalEmailHash] because every claim written before
  /// canonicalization existed is stored under this one. Reads check both.
  static String emailHash(String email) =>
      sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

  /// sha256 of the MAILBOX behind the address — plus-tags folded away, Gmail
  /// dots removed. This is what a claim is written under now, so one inbox
  /// can only ever hold one account however many aliases it is spelled with.
  static String canonicalEmailHash(String email) => sha256
      .convert(utf8.encode(EmailIdentity.canonical(email)))
      .toString();

  /// Whether [email] is already attached to a DIFFERENT account. Re-saving
  /// your own address is not "taken". Fails open, like [isPhoneTaken].
  ///
  /// Asks under BOTH hashes. The canonical one is what stops `you+1@` and
  /// `you+2@` being two accounts; the raw one is what still finds claims
  /// written before canonicalization, which would otherwise look free and be
  /// handed to somebody else. The second round trip is skipped in the
  /// ordinary case, where the two hashes are the same string.
  Future<bool> isEmailTaken(String email) async {
    final override = debugEmailTakenOverride;
    if (override != null) return override(email);
    if (!RelayConfig.isEnabled) return false;
    final canonical = canonicalEmailHash(email);
    final raw = emailHash(email);
    final answers = await Future.wait([
      _emailHashTaken(canonical),
      if (raw != canonical) _emailHashTaken(raw),
    ]);
    return answers.any((held) => held);
  }

  Future<bool> _emailHashTaken(String hash) async {
    try {
      final r = await _client
          .rpc('is_email_taken', params: {'h': hash})
          .timeout(const Duration(seconds: 6));
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// Records this account as the holder of [email]. Returns false when
  /// another account got there first.
  Future<bool> claimEmail(String email) async {
    final override = debugClaimEmailOverride;
    if (override != null) return override(email);
    if (!RelayConfig.isEnabled) return true;
    try {
      // The CANONICAL hash: claiming the address as written would let the
      // same inbox be claimed again tomorrow under a different tag, which is
      // the whole thing this closes. claim_email drops the caller's previous
      // claim, so an account that re-saves under a new spelling replaces its
      // own row rather than accumulating one per alias.
      final r = await _client
          .rpc('claim_email', params: {'h': canonicalEmailHash(email)})
          .timeout(const Duration(seconds: 6));
      return r == true;
    } catch (_) {
      return true; // fail open — the address is still saved on the device
    }
  }

  /// Gives up this account's email claim, so the address can be used again.
  Future<void> releaseEmail() async {
    if (!RelayConfig.isEnabled) return;
    try {
      await _client.rpc('release_email').timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  @visibleForTesting
  static Future<bool> Function(String phone)? debugPhoneTakenOverride;
  @visibleForTesting
  static Future<bool> Function(String email)? debugEmailTakenOverride;
  @visibleForTesting
  static Future<bool> Function(String email)? debugClaimEmailOverride;

  /// Looks up the username currently linked to [phone] (null if none).
  ///
  /// Through a definer function: both callers are at the SIGN-IN screen,
  /// where there is no session yet to read even your own directory row with.
  Future<String?> usernameForPhone(String phone) async {
    try {
      final r = await _client
          .rpc('username_for_phone', params: {'p': e164(phone)});
      final handle = r as String?;
      return (handle == null || handle.isEmpty) ? null : handle;
    } catch (_) {
      return null;
    }
  }

  /// Whether [phoneOrCode] belongs to an account on OkayMessenger, as far
  /// as the directory can say. Three answers on purpose:
  ///
  ///   true  — a directory row exists: they use the app;
  ///   false — the directory ANSWERED and holds nobody under that number;
  ///   null  — the question could not be answered (no relay, offline, or a
  ///           numberless viewer whose anon key reads the table as empty
  ///           rows — silence, not absence). Callers must fail OPEN on
  ///           null: refusing to message somebody over a network hiccup
  ///           would be worse than the spam this check prevents.
  Future<bool?> isOnApp(String phoneOrCode) async {
    if (!AccountService.isEnabled) return null;
    if (Session.instance.user.value == null || Session.instance.isNumberless) {
      return null;
    }
    try {
      // The caller supplied the number, so a yes/no tells it nothing it
      // could not learn by trying to message them — but it no longer needs
      // to read somebody else's directory row to find out.
      final r = await _client
          .rpc('is_on_app', params: {'p': e164(phoneOrCode)})
          .timeout(const Duration(seconds: 6));
      return r == true;
    } catch (_) {
      return null;
    }
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
      // Unreachable directory. There is no table fallback any more: a row
      // belongs to the account it names, and this caller is signed out.
    }
    return null;
  }

  /// Emails a one-time code to [email]. Sign-in only, never account
  /// creation: identity here is the phone, and an email is a door back to an
  /// account that attached one — not a substitute identity.
  Future<void> sendEmailCode(String email) => _client.auth
      .signInWithOtp(email: email.trim(), shouldCreateUser: false);

  /// Emails a one-time code to [email], CREATING the auth user if there isn't
  /// one — the numberless account's way to earn a real session.
  ///
  /// The sibling above passes `shouldCreateUser: false` because it is a
  /// sign-in door for an account that already exists. This one is the
  /// opposite case and the reason the distinction had to be made explicit: a
  /// name-only account has no Supabase user at all, so there is nothing for
  /// an OTP to sign in TO, and `false` here would simply refuse forever.
  ///
  /// Delegates rather than repeating the call, because the sibling below
  /// carries `emailRedirectTo` and this one did not — and the two are the
  /// same request. A missing redirect is what once sent Supabase's own mail
  /// to the project's Site URL, `http://localhost:3000`, so a tapped link
  /// opened a dead page.
  Future<void> sendEmailSignupCode(String email) =>
      sendNumberlessEmailCode(email);

  /// Verifies the emailed [code] for a NUMBERLESS account and returns the
  /// account code now stamped on the session — or null when the chain did not
  /// complete, in which case nothing about the account has changed.
  ///
  /// Three steps that have to happen in order, and the middle one is the
  /// whole point:
  ///
  ///   1. `verifyOTP` gives a real session — but one with NO phone claim,
  ///      which every RLS policy and `callerPhone()` reads as anonymous, so
  ///      on its own it unlocks nothing.
  ///   2. `email-account` stamps an account code into that user's `phone`
  ///      field, minted server-side from the user id (never sent from here —
  ///      account codes are public, so a caller-supplied one would be a way
  ///      to become somebody else).
  ///   3. `refreshSession` is what actually puts the claim in the JWT. The
  ///      stamp lands on the auth USER; the token this device is holding was
  ///      minted before it and still says nothing. Skipping this leaves the
  ///      app looking exactly as unverified as before, with the fault
  ///      invisible on both sides.
  ///
  /// Deliberately returns null rather than throwing on a refused stamp: the
  /// caller has a session it did not have before, and the honest state is
  /// "the email is confirmed but the account is not upgraded", which the
  /// screen can say. A thrown error would be indistinguishable from a wrong
  /// code.
  Future<String?> verifyEmailForNumberless(String email, String code) async {
    lastEmailUpgradeError = '';
    final res = await _client.auth.verifyOTP(
      type: OtpType.email,
      email: email.trim(),
      token: code.trim(),
    );
    if (res.user == null) {
      lastEmailUpgradeError = 'the code was accepted but no account came back';
      return null;
    }
    try {
      final claimed = await _client.functions
          .invoke('email-account', body: {'what': 'claim'});
      final data = claimed.data;
      final stamped =
          data is Map ? (data['code'] as String?)?.trim() ?? '' : '';
      if (stamped.isEmpty) {
        // The function answers a NAMED reason for every refusal it has —
        // "email not confirmed", "banned", "could not stamp the code". It
        // used to be thrown away here, leaving one vague sentence to stand
        // for six different faults.
        final said = data is Map ? (data['error'] as String?)?.trim() ?? '' : '';
        lastEmailUpgradeError = said.isEmpty ? 'no code came back' : said;
        return null;
      }
      await _client.auth.refreshSession();
      return stamped;
    } catch (e) {
      lastEmailUpgradeError = _shortError(e);
      return null;
    }
  }

  /// Why the last [verifyEmailForNumberless] did not upgrade the account —
  /// the function's own word for it, or the exception's.
  ///
  /// Kept rather than swallowed, and shown on screen. This app has now spent
  /// three separate rounds of debugging (the payment sheet, marketplace
  /// listings, marketplace reviews) guessing at a failure the device had
  /// already been told about and thrown away; `RelayService.lastMarketError`
  /// exists for the same reason.
  String lastEmailUpgradeError = '';

  /// The useful half of an exception, without the class name in front.
  static String _shortError(Object e) {
    // A refused Edge Function arrives as a FunctionException whose body is
    // the JSON the function returned, and that body is the answer.
    final details = e is FunctionException ? e.details : null;
    if (details is Map) {
      final said = (details['error'] as String?)?.trim() ?? '';
      if (said.isNotEmpty) return said;
    }
    if (details is String && details.trim().isNotEmpty) return details.trim();
    return e
        .toString()
        .replaceFirst(RegExp(r'^[A-Za-z]*(Error|Exception):\s*'), '');
  }


  /// Emails a one-time code proving ownership of [email], for a NUMBERLESS
  /// account's own email-verification checklist item — never sign-in, never
  /// account creation. A numberless account has no Supabase session (see the
  /// "no session at all" numberless-accounts section), so the normal
  /// clicked-confirmation-link flow (`AccountEmail._requestVerification`,
  /// which needs `auth.currentUser` to attach the address to) can never fire
  /// for one. `shouldCreateUser: true` is required here — unlike
  /// [sendEmailCode]'s sign-in-only `false` — because this is the FIRST time
  /// Supabase has ever heard of this address; there is no existing user to
  /// send an OTP to sign in AS.
  ///
  /// `emailRedirectTo` is passed for the same reason [AccountEmail.
  /// _requestVerification] passes it: with no redirect, Supabase falls back
  /// to the project's Site URL — `http://localhost:3000` until someone
  /// changes it — so a tapped link (this path's email uses the "Confirm
  /// signup" template, which by default shows a LINK, not the `{{ .Token }}`
  /// code this screen actually needs) opened a dead page on the reader's own
  /// phone instead of the app's real hosted page. Whether the email shows a
  /// usable code at all is a Supabase Auth email-template setting, not
  /// something this call controls — see the numberless-email-code section.
  Future<void> sendNumberlessEmailCode(String email) => _client.auth
      .signInWithOtp(
        email: email.trim(),
        shouldCreateUser: true,
        emailRedirectTo: AppPages.emailConfirmed,
      );

  /// Verifies the code from [sendNumberlessEmailCode]. Returns true only
  /// when Supabase confirms the caller really controls [email] — then
  /// immediately signs the transient session back out: a numberless
  /// account's identity stays its account code, never a Supabase Auth
  /// session, and nothing else in the app is built to see one appear (there
  /// is deliberately no `onAuthStateChange` listener anywhere in this app).
  /// This is proof-of-inbox-ownership only, not a way in.
  Future<bool> verifyNumberlessEmailCode(String email, String code) async {
    bool ok = false;
    try {
      final res = await _client.auth.verifyOTP(
        type: OtpType.email,
        email: email.trim(),
        token: code.trim(),
      );
      ok = res.session != null;
    } catch (_) {
      ok = false;
    }
    try {
      await _client.auth.signOut();
    } catch (_) {}
    return ok;
  }

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
