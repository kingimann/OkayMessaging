import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
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
      avatarColor: _colorForPhone(phone),
      about: 'Available',
      phone: phone,
      username: _normalizeUsername(username),
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(me.toJson()));
    user.value = me;
    AppState.profile.value = me;
  }

  /// Lowercases and strips a leading '@' / invalid characters from a username.
  static String _normalizeUsername(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]'), '');

  /// Updates the signed-in user's name/about and persists it on the device,
  /// keeping the phone number (identity) and avatar color.
  Future<void> updateProfile({
    required String name,
    required String about,
  }) async {
    final current = user.value;
    if (current == null) return;
    final updated = AppUser(
      id: current.id,
      name: name.trim().isEmpty ? current.name : name.trim(),
      avatarColor: current.avatarColor,
      about: about.trim().isEmpty ? current.about : about.trim(),
      phone: current.phone,
      username: current.username,
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  /// Signs out and forgets the local identity (chats stay on the device).
  Future<void> signOut() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_key);
    user.value = null;
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
      avatarColor: _colorForPhone(phone),
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

  static String _colorForPhone(String phone) {
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
