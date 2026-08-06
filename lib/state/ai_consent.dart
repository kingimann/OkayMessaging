import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the user has opted IN to helping improve Okay AI — i.e. letting
/// their Okay AI conversations and 👍/👎 feedback be collected as training
/// data.
///
/// OFF BY DEFAULT, always a deliberate opt-in. What it does and does not cover
/// is the whole point, and the consent copy says it plainly:
///  * ONLY Okay AI conversations — what you type to the assistant. Never your
///    private human chats, which are end-to-end encrypted and never leave the
///    device readable.
///  * Turning it on stores those exchanges server-side (a training corpus).
///    Turning it off stops new collection at once.
///
/// The corpus is later CURATED (thumbs-up / filtered) before any fine-tune —
/// the "don't learn nonsense" guardrail — so consent enables collection, not
/// automatic learning.
class AiConsent extends ChangeNotifier {
  AiConsent._();
  static final AiConsent instance = AiConsent._();

  static const _kKey = 'ai_training_consent_v1';

  bool _on = false;
  bool get on => _on;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _on = prefs.getBool(_kKey) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    if (_on == value) return;
    _on = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kKey, value);
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _on = false;
  }
}
