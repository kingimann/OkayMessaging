import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user.dart';
import '../payments/storage_economics.dart';
import '../relay/relay_config.dart';

/// The prices the APP assumes, editable by the owner and published to every
/// device — so keeping them in step with App Store Connect no longer needs a
/// build.
///
/// **These are not what anybody is charged.** Apple charges whatever the SKU
/// says in App Store Connect, and every purchase surface shows StoreKit's own
/// localized price whenever it has one ([StorePrices]). What lives here fills
/// the gaps that price cannot:
///
/// * the figure shown where there is no store to ask — web, payments-test
///   mode, the frame before StoreKit answers;
/// * the ladder of price levels a creator picks their tier from, which is a
///   choice the app has to offer before any purchase exists.
///
/// That ordering is the safety property, and it is deliberate: nothing set
/// here can make the app advertise a price different from the real charge,
/// because the real charge always wins when it is known. An editor that could
/// override a live store price would be a way to promise one number and bill
/// another — which is the mismatch this whole area exists to stop.
///
/// Writes go through the owner-gated `pricing-set` Edge Function; reads are
/// the public `app_pricing` row, fetched on launch and cached so the
/// last-known prices survive an offline start. With no server, or before the
/// fetch lands, the built-in defaults stand.
class PricingStore extends ChangeNotifier {
  PricingStore._();
  static final PricingStore instance = PricingStore._();

  static const _kCache = 'app_pricing_cache_v1';

  int? _storagePerGbCents;
  List<int>? _tierCents;
  Map<String, int> _tipCents = const {};

  /// Storage price per GB per month, in cents. Defaults to the rate the
  /// economics module is built on.
  int get storagePerGbCents =>
      _storagePerGbCents ?? (StorageEconomics.pricePerGb * 100).round();

  /// The four subscription price levels a creator or paid server picks from.
  /// Always four, always increasing — the publisher enforces both.
  List<int> get tierCents => _tierCents ?? AppUser.subscriptionTiersCents;

  /// The assumed amount for a tip product, or [fallback] when unset.
  int tipCents(String productId, int fallback) =>
      _tipCents[productId] ?? fallback;

  /// Whether anything has been published — what the editor shows as "using
  /// the built-in defaults" versus the owner's own numbers.
  bool get isCustomized =>
      _storagePerGbCents != null || _tierCents != null || _tipCents.isNotEmpty;

  SupabaseClient? get _client =>
      RelayConfig.isEnabled ? Supabase.instance.client : null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw != null && raw.isNotEmpty) {
        _apply(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      }
    } catch (_) {}
  }

  /// Reads a published price map. Anything malformed is ignored rather than
  /// thrown, so one bad field can't take the prices down with it.
  void _apply(Map<String, dynamic> j) {
    final gb = (j['storagePerGbCents'] as num?)?.toInt();
    if (gb != null && gb > 0) _storagePerGbCents = gb;

    final tiers = j['tierCents'];
    if (tiers is List && tiers.length == 4) {
      final parsed = [for (final v in tiers) (v as num?)?.toInt() ?? 0];
      // Four, all positive, strictly increasing — the same rule the
      // publisher enforces, applied again here because an older build must
      // never render a ladder that goes backwards.
      var ok = parsed.every((v) => v > 0);
      for (var i = 1; i < parsed.length; i++) {
        if (parsed[i] <= parsed[i - 1]) ok = false;
      }
      if (ok) _tierCents = parsed;
    }

    final tips = j['tipCents'];
    if (tips is Map) {
      final out = <String, int>{};
      tips.forEach((k, v) {
        final c = (v as num?)?.toInt() ?? 0;
        if (c > 0) out['$k'] = c;
      });
      if (out.isNotEmpty) _tipCents = out;
    }
    notifyListeners();
  }

  /// Fetches the published prices and caches them. Best-effort — a failure
  /// leaves the last-known copy (or the defaults) in place.
  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    try {
      final row = await client
          .from('app_pricing')
          .select('prices')
          .eq('id', 1)
          .maybeSingle();
      final prices = row?['prices'];
      if (prices is! Map) return;
      final map = Map<String, dynamic>.from(prices);
      _apply(map);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode(map));
    } catch (_) {}
  }

  /// The wire shape, so the editor and the cache agree on one encoding.
  Map<String, dynamic> toJson() => {
        'storagePerGbCents': storagePerGbCents,
        'tierCents': tierCents,
        if (_tipCents.isNotEmpty) 'tipCents': _tipCents,
      };

  /// Publishes new prices (owner only, enforced server-side). Returns true on
  /// success and reflects the change locally at once.
  Future<bool> publish(Map<String, dynamic> prices) async {
    final override = debugPublishOverride;
    bool ok;
    if (override != null) {
      ok = await override(prices);
    } else {
      final client = _client;
      if (client == null) return false;
      try {
        final res = await client.functions
            .invoke('pricing-set', body: {'what': 'publish', 'prices': prices});
        final data = res.data;
        ok = data is Map && data['ok'] == true;
      } catch (_) {
        return false;
      }
    }
    if (!ok) return false;
    _apply(Map<String, dynamic>.from(prices));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode(prices));
    } catch (_) {}
    return true;
  }

  /// Stands in for the Edge Function in tests.
  @visibleForTesting
  static Future<bool> Function(Map<String, dynamic> prices)?
      debugPublishOverride;

  /// Feeds a published map straight in, as a fetch would — so a test can
  /// prove a malformed one is ignored rather than rendered.
  @visibleForTesting
  void debugApply(Map<String, dynamic> prices) => _apply(prices);

  @visibleForTesting
  void resetForTest() {
    _storagePerGbCents = null;
    _tierCents = null;
    _tipCents = const {};
    debugPublishOverride = null;
  }
}
