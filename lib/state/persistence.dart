import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/user.dart';
import 'chat_store.dart';

/// Persists app state (theme, profile, wallpaper, and conversations) to
/// [SharedPreferences] so it survives an app restart / page reload.
class Persistence {
  Persistence._();

  static const _kTheme = 'theme';
  static const _kProfile = 'profile';
  static const _kWallpaper = 'wallpaper';
  static const _kChats = 'chats_v1';
  static const _kShareLastSeen = 'share_last_seen';

  static SharedPreferences? _prefs;

  /// Loads any saved state into the app, then wires up auto-save listeners.
  /// Safe to call once at startup; failures fall back to the default data.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final theme = prefs.getString(_kTheme);
    if (theme == 'dark') {
      AppState.themeMode.value = ThemeMode.dark;
    } else if (theme == 'light') {
      AppState.themeMode.value = ThemeMode.light;
    }

    final profile = prefs.getString(_kProfile);
    if (profile != null) {
      try {
        AppState.profile.value =
            AppUser.fromJson(jsonDecode(profile) as Map<String, dynamic>);
      } catch (_) {}
    }

    if (prefs.containsKey(_kWallpaper)) {
      final value = prefs.getInt(_kWallpaper);
      AppState.chatWallpaper.value = value == null ? null : Color(value);
    }

    final chats = prefs.getString(_kChats);
    if (chats != null) {
      try {
        ChatStore.instance.hydrate(jsonDecode(chats) as Map<String, dynamic>);
      } catch (_) {}
    }

    if (prefs.containsKey(_kShareLastSeen)) {
      AppState.shareLastSeen.value = prefs.getBool(_kShareLastSeen) ?? true;
    }

    AppState.themeMode.addListener(_saveTheme);
    AppState.profile.addListener(_saveProfile);
    AppState.chatWallpaper.addListener(_saveWallpaper);
    AppState.shareLastSeen.addListener(_saveShareLastSeen);
    ChatStore.instance.onChanged = _saveChats;
  }

  static void _saveShareLastSeen() {
    _prefs?.setBool(_kShareLastSeen, AppState.shareLastSeen.value);
  }

  static void _saveTheme() {
    _prefs?.setString(
      _kTheme,
      AppState.themeMode.value == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  static void _saveProfile() {
    _prefs?.setString(_kProfile, jsonEncode(AppState.profile.value.toJson()));
  }

  static void _saveWallpaper() {
    final color = AppState.chatWallpaper.value;
    if (color == null) {
      _prefs?.remove(_kWallpaper);
    } else {
      _prefs?.setInt(_kWallpaper, color.toARGB32());
    }
  }

  static void _saveChats() {
    _prefs?.setString(_kChats, jsonEncode(ChatStore.instance.toJson()));
  }
}
