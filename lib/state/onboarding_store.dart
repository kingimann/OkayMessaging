import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the one-time new-user "get started" nudge has been dismissed.
/// Stored on-device; once dismissed it never shows again.
class OnboardingStore extends ChangeNotifier {
  OnboardingStore._();
  static final OnboardingStore instance = OnboardingStore._();
  static const _key = 'onboarding_done_v1';

  bool _done = false;
  bool get done => _done;

  SharedPreferences? _prefs;

  Future<void> load() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      _done = _prefs!.getBool(_key) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> complete() async {
    if (_done) return;
    _done = true;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool(_key, true);
    } catch (_) {}
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _done = false;
    _prefs = null;
    notifyListeners();
  }

  /// Synchronously marks onboarding done in tests (no persistence), so the
  /// nudge doesn't overlay unrelated screens.
  @visibleForTesting
  void markDoneForTest() {
    _done = true;
    notifyListeners();
  }
}
