import 'package:flutter/material.dart';

/// Lightweight global app state. Kept intentionally simple (a couple of
/// [ValueNotifier]s) since this is a UI-only demo with no persistence layer.
class AppState {
  AppState._();

  /// The active theme mode; toggled from the Settings screen.
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.light);
}
