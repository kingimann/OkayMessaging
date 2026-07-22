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
  static const _kReadReceipts = 'send_read_receipts';
  static const _kTypingIndicators = 'send_typing_indicators';
  static const _kSilenceUnknown = 'silence_unknown_callers';
  static const _kContactsOnly = 'messages_from_contacts_only';
  static const _kNotifications = 'notifications_enabled';
  static const _kEnterToSend = 'enter_to_send';
  static const _kTextScale = 'message_text_scale';
  static const _kBlocked = 'blocked_contacts_v1';

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
    } else if (theme == 'system') {
      AppState.themeMode.value = ThemeMode.system;
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
    if (prefs.containsKey(_kReadReceipts)) {
      AppState.sendReadReceipts.value = prefs.getBool(_kReadReceipts) ?? true;
    }
    if (prefs.containsKey(_kTypingIndicators)) {
      AppState.sendTypingIndicators.value =
          prefs.getBool(_kTypingIndicators) ?? true;
    }
    if (prefs.containsKey(_kSilenceUnknown)) {
      AppState.silenceUnknownCallers.value =
          prefs.getBool(_kSilenceUnknown) ?? false;
    }
    if (prefs.containsKey(_kContactsOnly)) {
      AppState.messagesFromContactsOnly.value =
          prefs.getBool(_kContactsOnly) ?? false;
    }
    if (prefs.containsKey(_kNotifications)) {
      AppState.notificationsEnabled.value =
          prefs.getBool(_kNotifications) ?? true;
    }
    if (prefs.containsKey(_kEnterToSend)) {
      AppState.enterToSend.value = prefs.getBool(_kEnterToSend) ?? true;
    }
    if (prefs.containsKey(_kTextScale)) {
      AppState.messageTextScale.value =
          (prefs.getDouble(_kTextScale) ?? 1.0).clamp(0.85, 1.30);
    }
    final blocked = prefs.getStringList(_kBlocked);
    if (blocked != null) {
      AppState.blockedContacts.value = blocked.toSet();
    }

    AppState.themeMode.addListener(_saveTheme);
    AppState.profile.addListener(_saveProfile);
    AppState.chatWallpaper.addListener(_saveWallpaper);
    AppState.shareLastSeen.addListener(_saveShareLastSeen);
    AppState.sendReadReceipts.addListener(_saveReadReceipts);
    AppState.sendTypingIndicators.addListener(_saveTypingIndicators);
    AppState.silenceUnknownCallers.addListener(_saveSilenceUnknown);
    AppState.messagesFromContactsOnly.addListener(_saveContactsOnly);
    AppState.notificationsEnabled.addListener(_saveNotifications);
    AppState.enterToSend.addListener(_saveEnterToSend);
    AppState.messageTextScale.addListener(_saveTextScale);
    AppState.blockedContacts.addListener(_saveBlocked);
    ChatStore.instance.onChanged = _saveChats;
  }

  static void _saveTypingIndicators() {
    _prefs?.setBool(_kTypingIndicators, AppState.sendTypingIndicators.value);
  }

  static void _saveSilenceUnknown() {
    _prefs?.setBool(_kSilenceUnknown, AppState.silenceUnknownCallers.value);
  }

  static void _saveContactsOnly() {
    _prefs?.setBool(_kContactsOnly, AppState.messagesFromContactsOnly.value);
  }

  static void _saveEnterToSend() {
    _prefs?.setBool(_kEnterToSend, AppState.enterToSend.value);
  }

  static void _saveTextScale() {
    _prefs?.setDouble(_kTextScale, AppState.messageTextScale.value);
  }

  static void _saveBlocked() {
    _prefs?.setStringList(_kBlocked, AppState.blockedContacts.value.toList());
  }

  static void _saveShareLastSeen() {
    _prefs?.setBool(_kShareLastSeen, AppState.shareLastSeen.value);
  }

  static void _saveReadReceipts() {
    _prefs?.setBool(_kReadReceipts, AppState.sendReadReceipts.value);
  }

  static void _saveNotifications() {
    _prefs?.setBool(_kNotifications, AppState.notificationsEnabled.value);
  }

  static void _saveTheme() {
    _prefs?.setString(_kTheme, switch (AppState.themeMode.value) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    });
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
