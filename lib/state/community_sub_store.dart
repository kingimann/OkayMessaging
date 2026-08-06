import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payments/purchase_outcome.dart';
import '../payments/store_purchases.dart';

/// Which PAID SERVERS this device currently holds an active monthly membership
/// pass to, and buying/renewing one.
///
/// The server-membership twin of [CreatorSubStore] — a 30-day pass you renew,
/// tracked per server (by community id) instead of per creator. The purchase
/// is a platform In-App Purchase (a consumable month), because membership is a
/// digital good; Stripe stays reserved for real-world peer-to-peer transfers.
///
/// What the pass gates is JOINING: a paid server's traffic is already E2E
/// sealed under its own secret, so this is not access-control over readable
/// content — it decides whether the join button opens. The honest boundary,
/// stated rather than hidden: this is enforced on the client at the join step,
/// and the sealed invite still carries the secret, so a modified client is not
/// stopped by it. A receipt-verified secret release (the owner's device hands
/// the secret to a verified-paid joiner, sealed to them, the way a
/// Bluetooth-findable server already answers a stranger) is the hardening
/// follow-up; the content sealing is unchanged either way.
class CommunitySubStore extends ChangeNotifier {
  CommunitySubStore._();
  static final CommunitySubStore instance = CommunitySubStore._();

  static const _kActive = 'community_subs_active_v1';

  /// One purchase buys this much time; renewals stack on whatever is left.
  static const Duration period = Duration(days: 30);

  /// server id -> when the membership pass runs out.
  final Map<String, DateTime> _activeUntil = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kActive);
    _activeUntil.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        m.forEach((k, v) {
          final dt = DateTime.tryParse(v as String? ?? '');
          if (dt != null) _activeUntil[k] = dt;
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Whether the membership pass to [serverId] is currently active.
  bool active(String serverId) {
    final until = _activeUntil[serverId];
    return until != null && until.isAfter(DateTime.now());
  }

  DateTime? activeUntil(String serverId) => _activeUntil[serverId];

  /// Whole days left on the pass, or 0 when lapsed.
  int daysLeft(String serverId) {
    final until = _activeUntil[serverId];
    if (until == null) return 0;
    final d = until.difference(DateTime.now());
    return d.isNegative ? 0 : d.inDays;
  }

  /// Buys (or renews) a month of membership to [serverId] at [tier]. Returns
  /// the store outcome; on success the pass is extended locally at once.
  Future<PurchaseResult> subscribe(String serverId, int tier) async {
    final result = await StorePurchases.instance.buyCommunitySub(tier);
    if (!result.ok) return result;
    await _extend(serverId);
    return result;
  }

  Future<void> _extend(String serverId) async {
    final now = DateTime.now();
    final cur = _activeUntil[serverId];
    final base = (cur != null && cur.isAfter(now)) ? cur : now;
    _activeUntil[serverId] = base.add(period);
    await _save();
    notifyListeners();
  }

  /// Adopt the server's view for one membership: the server holds the
  /// authoritative expiry, and only a pass it actively denies is cleared (a
  /// null while offline must not wipe a still-valid local pass).
  Future<void> applyServer(String serverId,
      {required bool active, DateTime? expiresAt}) async {
    if (!active) {
      _activeUntil.remove(serverId);
    } else {
      _activeUntil[serverId] = expiresAt ?? DateTime.now().add(period);
    }
    await _save();
    notifyListeners();
  }

  /// Stops tracking a membership locally (e.g. after leaving the server).
  Future<void> cancel(String serverId) async {
    _activeUntil.remove(serverId);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
      _kActive,
      jsonEncode(
          _activeUntil.map((k, v) => MapEntry(k, v.toIso8601String()))),
    );
  }

  @visibleForTesting
  void resetForTest() {
    _activeUntil.clear();
    _prefs = null;
  }

  /// Grant a pass without a purchase — tests and the test-mode paths.
  @visibleForTesting
  Future<void> debugSubscribe(String serverId, {Duration? length}) async {
    _activeUntil[serverId] = DateTime.now().add(length ?? period);
    await _save();
    notifyListeners();
  }
}
