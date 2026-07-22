import 'package:flutter/material.dart';

import 'data/mock_data.dart';
import 'models/user.dart';

/// Lightweight global app state. Kept intentionally simple (a couple of
/// [ValueNotifier]s) since this is a UI-only demo with no persistence layer.
class AppState {
  AppState._();

  /// The active theme mode; toggled from the Settings screen.
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  /// The current user's editable profile (name + about).
  static final ValueNotifier<AppUser> profile =
      ValueNotifier<AppUser>(MockData.me);

  /// The chat background color; null uses the default wallpaper.
  static final ValueNotifier<Color?> chatWallpaper =
      ValueNotifier<Color?>(null);

  /// Whether to broadcast your online / last-seen status to people you chat
  /// with. When off, peers won't see you as "online".
  static final ValueNotifier<bool> shareLastSeen = ValueNotifier<bool>(true);

  /// Resets global state; used by tests to isolate cases.
  @visibleForTesting
  static void resetForTest() {
    themeMode.value = ThemeMode.light;
    profile.value = MockData.me;
    chatWallpaper.value = null;
    shareLastSeen.value = true;
  }

  /// Updates the current user's name and about text.
  static void updateProfile({required String name, required String about}) {
    final p = profile.value;
    profile.value = AppUser(
      id: p.id,
      name: name.trim().isEmpty ? p.name : name.trim(),
      avatarColor: p.avatarColor,
      about: about.trim().isEmpty ? p.about : about.trim(),
      phone: p.phone,
    );
  }
}
