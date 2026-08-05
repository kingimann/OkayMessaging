import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payments/purchase_outcome.dart';
import '../payments/store_purchases.dart';
import 'public_feed_store.dart';

/// The reader's side of creator subscriptions: which creators this device
/// currently holds an active monthly pass to, and buying/renewing one.
///
/// Modelled on [StorageStore] — a 30-day pass you renew, tracked per creator
/// instead of once for the whole account. The purchase itself is a platform
/// In-App Purchase (Apple/Google) because it's a digital good; Stripe stays
/// reserved for real-world peer-to-peer transfers. The server records the
/// entitlement too (so it can gate the paid post bodies), and [applyServer]
/// lets that verdict overwrite the local one — the server, not a local +30
/// days, is what actually decides whether a body is served.
class CreatorSubStore extends ChangeNotifier {
  CreatorSubStore._();
  static final CreatorSubStore instance = CreatorSubStore._();

  static const _kActive = 'creator_subs_active_v1';

  /// One purchase buys this much time; renewals stack on whatever is left.
  static const Duration period = Duration(days: 30);

  /// creatorKey (a normalised handle) -> when the pass runs out.
  final Map<String, DateTime> _activeUntil = {};
  SharedPreferences? _prefs;

  /// A creator is addressed by their public handle; normalise it the same way
  /// everywhere so '@Rae', 'rae' and 'RAE' are one subscription.
  static String keyFor(String creator) => creator
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase();

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

  /// Whether the pass to [creator] is currently active.
  bool active(String creator) {
    final until = _activeUntil[keyFor(creator)];
    return until != null && until.isAfter(DateTime.now());
  }

  DateTime? activeUntil(String creator) => _activeUntil[keyFor(creator)];

  /// Whole days left on the pass, or 0 when lapsed.
  int daysLeft(String creator) {
    final until = _activeUntil[keyFor(creator)];
    if (until == null) return 0;
    final d = until.difference(DateTime.now());
    return d.isNegative ? 0 : d.inDays;
  }

  /// The creators this device is subscribed to right now, handles only.
  List<String> get activeCreators {
    final now = DateTime.now();
    final live = _activeUntil.entries
        .where((e) => e.value.isAfter(now))
        .map((e) => e.key)
        .toList()
      ..sort();
    return live;
  }

  /// Buys (or renews) a month of [creator]'s subscription at [tier]. Returns
  /// the store outcome. On success the pass is extended locally at once and
  /// recorded server-side so the paid bodies start unlocking; a store failure
  /// grants nothing.
  Future<PurchaseResult> subscribe(String creator, int tier) async {
    final result = await StorePurchases.instance.buyCreatorSub(tier);
    if (!result.ok) return result;
    await _extend(creator);
    // Record the pass server-side by handing over the store receipt, which the
    // `creator-subscribe` function verifies before granting — the client is
    // never trusted to grant itself a paid body. Test mode carries no receipt,
    // so this is a no-op there (the local pass alone drives the demo); in real
    // use the receipt is what makes the server start serving the bodies.
    try {
      await PublicFeedStore.instance
          .serverSubscribe(keyFor(creator), result.jws ?? '');
    } catch (_) {}
    return result;
  }

  Future<void> _extend(String creator) async {
    final k = keyFor(creator);
    final now = DateTime.now();
    final cur = _activeUntil[k];
    final base = (cur != null && cur.isAfter(now)) ? cur : now;
    _activeUntil[k] = base.add(period);
    await _save();
    notifyListeners();
  }

  /// Adopt the server's view for one creator: it holds the authoritative
  /// expiry, and only clears a pass the server actively denies (a null while
  /// offline must not wipe a still-valid local pass).
  Future<void> applyServer(String creator,
      {required bool active, DateTime? expiresAt}) async {
    final k = keyFor(creator);
    if (!active) {
      _activeUntil.remove(k);
    } else {
      _activeUntil[k] = expiresAt ?? DateTime.now().add(period);
    }
    await _save();
    notifyListeners();
  }

  /// Adopt a whole set of server-known passes at once (e.g. on relay start).
  Future<void> applyServerAll(Map<String, DateTime> passes) async {
    _activeUntil
      ..clear()
      ..addAll(passes);
    await _save();
    notifyListeners();
  }

  /// Stops renewing locally. There's nothing to cancel server-side: a creator
  /// pass is a consumable month, not an auto-renew, so it simply expires — the
  /// server keeps serving bodies only until the recorded expiry passes.
  Future<void> cancel(String creator) async {
    _activeUntil.remove(keyFor(creator));
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

  /// Grant a pass without a purchase — tests, and the debug/test-mode paths.
  @visibleForTesting
  Future<void> debugSubscribe(String creator, {Duration? length}) async {
    _activeUntil[keyFor(creator)] = DateTime.now().add(length ?? period);
    await _save();
    notifyListeners();
  }
}
