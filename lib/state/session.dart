import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../app_state.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../util/account_code.dart';
import '../models/user.dart';
import 'account_wipe.dart';
import 'voice_presence_store.dart';
import 'push_service.dart';

/// The signed-in identity, keyed by phone number and stored **only on this
/// device**. There is no server: signing in just records who you are locally
/// so the app can show your profile and stamp your messages.
class Session {
  Session._();
  static final Session instance = Session._();

  static const _key = 'session_v1';

  /// The current signed-in user, or null when signed out.
  final ValueNotifier<AppUser?> user = ValueNotifier<AppUser?>(null);

  bool get isSignedIn => user.value != null;

  SharedPreferences? _prefs;

  /// Loads any saved identity from device storage at startup.
  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        final saved =
            AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        user.value = saved;
        AppState.profile.value = saved;
      } catch (_) {}
    }
    final rawLast = _prefs!.getString(_kLast);
    if (rawLast != null) {
      try {
        lastAccount =
            AppUser.fromJson(jsonDecode(rawLast) as Map<String, dynamic>);
      } catch (_) {}
    }
    final rawKnown = _prefs!.getString(_kKnown);
    if (rawKnown != null) {
      try {
        knownAccounts = [
          for (final e in jsonDecode(rawKnown) as List)
            AppUser.fromJson(Map<String, dynamic>.from(e as Map))
        ];
      } catch (_) {}
    }
    // Upgrades from before the list: the single remembered account seeds it.
    if (knownAccounts.isEmpty && lastAccount != null) {
      await rememberAccount(lastAccount!);
    }
    // Builds from before the account wipe never recorded who the device's
    // data belongs to. Stamp it from whoever is (or was last) signed in, or
    // the FIRST sign-in on an upgraded install finds no owner on record,
    // skips the wipe, and inherits everything — the exact bug the wipe
    // exists to stop, surviving one build longer through the upgrade.
    final owner = user.value ?? lastAccount;
    if (owner != null && !_prefs!.containsKey(AccountWipe.ownerKey)) {
      await _prefs!.setString(
          AccountWipe.ownerKey, owner.phone.replaceAll(RegExp(r'\D'), ''));
    }
  }

  /// Signs in with a phone number, display name, and optional username,
  /// persisting locally.
  Future<void> signIn({
    required String phone,
    required String name,
    String username = '',
  }) async {
    // A DIFFERENT account signing in must not inherit this device's data —
    // chats, the verification badge, the score, any of it. Same account
    // returning keeps everything; that is the difference between signing
    // back in and switching.
    await AccountWipe.onSignIn(phone);
    // "Keeps everything" includes the PROFILE: this used to rebuild a bare
    // one — about back to 'Available', the avatar look, pronouns, link and
    // location gone — on every sign-back-in, while the comment above
    // promised otherwise. The remembered identity for the same digits is
    // the base; what was typed on the form only overrides what it names.
    final d = phone.replaceAll(RegExp(r'\D'), '');
    AppUser? prior;
    for (final a in [
      if (lastAccount != null) lastAccount!,
      ...knownAccounts,
    ]) {
      if (a.phone.replaceAll(RegExp(r'\D'), '') == d) {
        prior = a;
        break;
      }
    }
    final trimmedName = name.trim().isEmpty
        ? (prior?.name ?? phone)
        : name.trim();
    final handle = _normalizeUsername(username);
    final me = AppUser(
      id: phone,
      name: trimmedName,
      avatarColor: prior?.avatarColor ?? colorForPhone(phone),
      about: prior?.about ?? 'Available',
      phone: phone,
      username: handle.isNotEmpty ? handle : (prior?.username ?? ''),
      verified: prior?.verified ?? false,
      score: prior?.score ?? 0,
      emoji: prior?.emoji ?? '',
      pronouns: prior?.pronouns ?? '',
      link: prior?.link ?? '',
      avatarColor2: prior?.avatarColor2 ?? '',
      bannerColor: prior?.bannerColor ?? '',
      location: prior?.location ?? '',
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(me.toJson()));
    user.value = me;
    AppState.profile.value = me;
    // Remembered NOW rather than only at sign-out, so a crash or reinstall
    // that skips sign-out still offers this profile next time. (The wipe
    // keeps the list: it is device history, like last_account_v1.)
    await rememberAccount(me);
    // Attach this device's push token to the account that now owns it (and
    // release any previous account's claim on it, server-side).
    if (RelayConfig.isEnabled) {
      try {
        await PushService.instance.reupload();
      } catch (_) {}
      // Reactivation IS the sign-in: a deactivated account's directory row
      // is hidden (docs/account_lifecycle.sql), and coming back has to
      // clear that or "temporarily" was a lie. Own-row RLS; best-effort —
      // a project without the column just answers with an error.
      if (!AccountCode.isCode(phone)) {
        try {
          await supa.Supabase.instance.client.from('usernames').update({
            'hidden': false,
          }).eq('phone', phone.replaceAll(RegExp(r'\D'), ''));
        } catch (_) {}
      }
    }
  }

  /// Signs in with no phone number at all.
  ///
  /// For anyone who does not want to hand over a number, and for the ordinary
  /// case of putting the app on a second device to try it. What they get
  /// instead is an [AccountCode] — a digit string that cannot be mistaken for
  /// a real number — which is what the relay listens on and what the mesh
  /// addresses, so everything downstream works unchanged.
  ///
  /// The consequence, said rather than discovered: nobody can find you from
  /// their contacts, because there is no number of yours in anybody's phone.
  /// They reach you by your code or your username, and that is all. It also
  /// means no Supabase session — Supabase authenticates a phone — so every
  /// server-backed part of the app is locked behind [PhoneGate]. Chat is not
  /// one of them: broadcast and the mailbox are both reachable with the anon
  /// key, so messages work exactly as they do for anybody else.
  ///
  /// [name] may be empty, and usually is: signing up this way is one field.
  /// The username stands in for it rather than the account code, which is a
  /// display name nobody would choose and nobody would recognise.
  Future<void> signInWithoutNumber({
    String name = '',
    required String username,
    String? code,
  }) {
    final handle = _normalizeUsername(username);
    return signIn(
      // Callers that claimed the handle in the directory pass the code they
      // claimed it under; minting a fresh one here would orphan that claim.
      phone: code ?? AccountCode.mint(),
      name: name.trim().isEmpty ? handle : name.trim(),
      username: handle,
    );
  }

  /// Whether the signed-in account has no phone number behind it.
  bool get isNumberless {
    final phone = user.value?.phone ?? '';
    return phone.isNotEmpty && AccountCode.isCode(phone);
  }

  /// Lowercases and strips a leading '@' / invalid characters from a username.
  static String _normalizeUsername(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]'), '');

  /// Updates the signed-in user's name/about (and optionally username / avatar
  /// color) and persists it on the device, keeping the phone number (identity).
  Future<void> updateProfile({
    required String name,
    required String about,
    String? username,
    String? avatarColor,
    String? emoji,
    String? pronouns,
    String? link,
    String? avatarColor2,
    String? bannerColor,
    String? location,
  }) async {
    final current = user.value;
    if (current == null) return;
    final updated = AppUser(
      id: current.id,
      name: name.trim().isEmpty ? current.name : name.trim(),
      avatarColor: (avatarColor == null || avatarColor.isEmpty)
          ? current.avatarColor
          : avatarColor,
      about: about.trim().isEmpty ? current.about : about.trim(),
      phone: current.phone,
      username:
          username == null ? current.username : _normalizeUsername(username),
      verified: current.verified,
      score: current.score,
      emoji: emoji ?? current.emoji,
      pronouns: pronouns ?? current.pronouns,
      link: link ?? current.link,
      avatarColor2: avatarColor2 ?? current.avatarColor2,
      bannerColor: bannerColor ?? current.bannerColor,
      location: location ?? current.location,
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  /// Sets the verified (blue check) flag on the signed-in identity and
  /// persists it, mirroring the change into [AppState.profile].
  Future<void> setVerified(bool value) async {
    final current = user.value;
    if (current == null || current.verified == value) return;
    final updated = AppUser(
      id: current.id,
      name: current.name,
      avatarColor: current.avatarColor,
      about: current.about,
      phone: current.phone,
      username: current.username,
      isOnline: current.isOnline,
      isGroup: current.isGroup,
      verified: value,
      score: current.score,
      // Everything else rides along untouched — this rebuild used to drop
      // emoji, pronouns and link on the floor whenever the badge changed.
      emoji: current.emoji,
      pronouns: current.pronouns,
      link: current.link,
      avatarColor2: current.avatarColor2,
      bannerColor: current.bannerColor,
      location: current.location,
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  static const _kLast = 'last_account_v1';
  static const _kKnown = 'known_accounts_v1';

  /// The identity that was signed in most recently — kept across sign-out so
  /// coming back is one tap, not a whole form.
  AppUser? lastAccount;

  /// Every account that has signed in on this device, most recent first —
  /// the login screen offers each as a one-tap way back in. Identity only
  /// (name, handle, number/code, avatar color): the account's DATA is wiped
  /// on switch as always; this remembers who, never what.
  List<AppUser> knownAccounts = [];

  static const _maxKnown = 5;

  /// Records [account] at the head of the remembered list, deduped by
  /// digits and capped. Called on both sign-in and sign-out, so a crash
  /// that skips sign-out still leaves the profile offered next time.
  Future<void> rememberAccount(AppUser account) async {
    final d = account.phone.replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return;
    knownAccounts = [
      account,
      ...knownAccounts
          .where((a) => a.phone.replaceAll(RegExp(r'\D'), '') != d),
    ];
    if (knownAccounts.length > _maxKnown) {
      knownAccounts = knownAccounts.sublist(0, _maxKnown);
    }
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
        _kKnown, jsonEncode([for (final a in knownAccounts) a.toJson()]));
  }

  /// Forgets every remembered profile, memory and disk — for **Delete
  /// account**: the erase clears the prefs file, but the in-memory list
  /// would re-persist the deleted identity with the next sign-in, offering
  /// one-tap entry into an account that no longer exists.
  Future<void> clearKnownAccounts() async {
    knownAccounts = [];
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kKnown);
  }

  /// Drops one remembered profile (long-press → remove on the login list).
  Future<void> forgetAccount(String phone) async {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    knownAccounts.removeWhere(
        (a) => a.phone.replaceAll(RegExp(r'\D'), '') == d);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
        _kKnown, jsonEncode([for (final a in knownAccounts) a.toJson()]));
    if (lastAccount != null &&
        lastAccount!.phone.replaceAll(RegExp(r'\D'), '') == d) {
      await clearLastAccount();
    }
  }

  /// Signs out and forgets the local identity (chats stay on the device).
  /// The account itself is remembered so signing back in is instant.
  Future<void> signOut() async {
    _prefs ??= await SharedPreferences.getInstance();
    final current = user.value;
    if (current != null) {
      lastAccount = current;
      await _prefs!.setString(_kLast, jsonEncode(current.toJson()));
      await rememberAccount(current);
      // Belt and braces for the upgrade path: whoever is leaving owns the
      // data they leave behind, so the next sign-in can tell whether it is
      // them coming back.
      await _prefs!.setString(AccountWipe.ownerKey,
          current.phone.replaceAll(RegExp(r'\D'), ''));
    }
    await _prefs!.remove(_key);
    user.value = null;
    // The SERVER session belongs to the account that just left, and keeping
    // it around is why the next sign-in demanded the PREVIOUS account's
    // second factor: the auth client was still that person. Token first
    // (deleting it needs the session), then the subscriptions, then the
    // session itself. All best-effort — sign-out must never block on the
    // network, and in a build with no relay there is nothing to clear.
    // Announced while the relay is still up: an account that signs out
    // mid-voice must not keep sitting in the room under its old identity
    // until the heartbeat ages it out.
    try {
      VoicePresenceStore.instance.leave();
    } catch (_) {}
    if (RelayConfig.isEnabled) {
      try {
        await PushService.instance.removeToken();
      } catch (_) {}
      try {
        await RelayService.instance.stop();
      } catch (_) {}
      try {
        await supa.Supabase.instance.client.auth.signOut();
      } catch (_) {}
    }
  }

  /// Forgets the remembered account (Settings → sign-in screen → "Use a
  /// different account" keeps it; this is the hard erase).
  Future<void> clearLastAccount() async {
    lastAccount = null;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kLast);
  }

  /// Establishes a signed-in identity synchronously for tests.
  @visibleForTesting
  void signInForTest({
    String phone = '+1 555 0100',
    String name = 'You',
    String username = 'you',
  }) {
    final me = AppUser(
      id: phone,
      name: name,
      avatarColor: colorForPhone(phone),
      about: 'Available',
      phone: phone,
      username: username,
    );
    user.value = me;
    AppState.profile.value = me;
  }

  @visibleForTesting
  void resetForTest() {
    user.value = null;
  }

  /// Deterministic avatar colour for a phone number (shared with the server
  /// directory so a person looks the same everywhere).
  static String colorForPhone(String phone) {
    const palette = [
      '#E57373', '#64B5F6', '#BA68C8', '#4DB6AC',
      '#FFB74D', '#A1887F', '#4DD0E1', '#81C784',
    ];
    var hash = 0;
    for (final unit in phone.codeUnits) {
      hash = (hash + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}
