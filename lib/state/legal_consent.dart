import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../legal/legal_content.dart';
import 'legal_store.dart';

/// Tracks which version of the Terms of Service and Privacy Policy this
/// user has agreed to. The app gates the home screen until the current
/// version is accepted — once on first sign-in, and again whenever the
/// documents are updated (a bump to the build's [legalVersion], OR an owner
/// publishing new documents, which [LegalStore.version] surfaces).
class LegalConsent extends ChangeNotifier {
  LegalConsent._();
  static final LegalConsent instance = LegalConsent._();

  static const _kVersion = 'legal_accepted_version_v1';

  int _accepted = 0;
  bool _loaded = false;

  /// True when the user still has to agree to the current documents. False
  /// until [load] has run, so the gate never flashes while starting up.
  bool get needsConsent => _loaded && _accepted < LegalStore.instance.version;

  /// Whether some earlier version was accepted — i.e. this is an *update*
  /// to agree to, not a first sign-up.
  bool get hasAcceptedBefore => _accepted > 0;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _accepted = prefs.getInt(_kVersion) ?? 0;
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  /// Records agreement to the current effective version.
  Future<void> accept() async {
    _accepted = LegalStore.instance.version;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kVersion, _accepted);
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest({int accepted = legalVersion}) {
    _accepted = accepted;
    _loaded = true;
    notifyListeners();
  }
}
