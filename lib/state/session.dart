import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../util/account_code.dart';
import '../models/user.dart';

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
  }

  /// Signs in with a phone number, display name, and optional username,
  /// persisting locally.
  Future<void> signIn({
    required String phone,
    required String name,
    String username = '',
  }) async {
    final trimmedName = name.trim().isEmpty ? phone : name.trim();
    final me = AppUser(
      id: phone,
      name: trimmedName,
      avatarColor: colorForPhone(phone),
      about: 'Available',
      phone: phone,
      username: _normalizeUsername(username),
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(me.toJson()));
    user.value = me;
    AppState.profile.value = me;
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
  /// They reach you by your code or your username, and that is all.
  Future<void> signInWithoutNumber({
    required String name,
    String username = '',
  }) =>
      signIn(phone: AccountCode.mint(), name: name, username: username);

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
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  static const _kLast = 'last_account_v1';

  /// The identity that was signed in most recently — kept across sign-out so
  /// coming back is one tap, not a whole form.
  AppUser? lastAccount;

  /// Signs out and forgets the local identity (chats stay on the device).
  /// The account itself is remembered so signing back in is instant.
  Future<void> signOut() async {
    _prefs ??= await SharedPreferences.getInstance();
    final current = user.value;
    if (current != null) {
      lastAccount = current;
      await _prefs!.setString(_kLast, jsonEncode(current.toJson()));
    }
    await _prefs!.remove(_key);
    user.value = null;
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
