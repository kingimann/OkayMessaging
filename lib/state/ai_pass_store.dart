import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payments/purchase_outcome.dart';
import '../payments/store_purchases.dart';

/// The Okay AI upgrade pass: unlimited messages for a month, past the free
/// daily allowance.
///
/// A 30-day pass you renew, modelled on the storage and creator passes. The
/// purchase is a consumable In-App Purchase (a digital good); test mode
/// simulates it. The exact price/product is the owner's to finalise later —
/// this is the mechanism, and it runs in test/simulation until the SKU exists.
class AiPassStore extends ChangeNotifier {
  AiPassStore._();
  static final AiPassStore instance = AiPassStore._();

  static const _kUntil = 'ai_pass_until_v1';
  static const Duration period = Duration(days: 30);

  DateTime? _until;
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kUntil);
    _until = raw == null ? null : DateTime.tryParse(raw);
    notifyListeners();
  }

  /// Whether an unlimited pass is currently active.
  bool get active => _until != null && _until!.isAfter(DateTime.now());

  DateTime? get activeUntil => _until;

  /// Buys (or renews) a month of unlimited Okay AI. Returns the store result;
  /// on success the pass is extended locally at once. Test mode simulates it.
  Future<PurchaseResult> subscribe() async {
    final result = await StorePurchases.instance.buyAiPass();
    if (!result.ok) return result;
    final now = DateTime.now();
    final base = (_until != null && _until!.isAfter(now)) ? _until! : now;
    _until = base.add(period);
    await _save();
    notifyListeners();
    return result;
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_until == null) {
      await _prefs!.remove(_kUntil);
    } else {
      await _prefs!.setString(_kUntil, _until!.toIso8601String());
    }
  }

  @visibleForTesting
  void resetForTest() {
    _until = null;
    _prefs = null;
  }

  @visibleForTesting
  Future<void> debugGrant({Duration? length}) async {
    _until = DateTime.now().add(length ?? period);
    await _save();
    notifyListeners();
  }
}
