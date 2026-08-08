import 'package:flutter/foundation.dart';

import '../state/storage_store.dart';
import 'apple_iap.dart';
import 'store_purchases.dart';

/// The real, store-set price for every in-app product, each already formatted
/// in the buyer's own currency and matching EXACTLY what was configured in App
/// Store Connect. OkayMessenger is sold only in the US and Canada, so the only
/// currencies a real buyer ever sees are USD (US store) and CAD (Canadian
/// store) — StoreKit picks the right one from the account's region, no work
/// here.
///
/// Why this exists: the app used to render prices computed from hardcoded cents
/// (`$2.99`), which (a) showed USD to a Canadian buyer and (b) drifted from the
/// price actually charged the moment a store price was adjusted. StoreKit is
/// the source of truth; this caches its answer so a synchronous `build()` can
/// show it.
///
/// Every label falls back to a plain USD figure from the cents until the store
/// answers — web and payments-test mode, where nothing is purchasable, and the
/// first frame before [load] returns.
class StorePrices extends ChangeNotifier {
  StorePrices._();
  static final StorePrices instance = StorePrices._();

  final Map<String, String> _prices = {};

  /// The store's localized price for [productId], or null when unknown (not
  /// loaded yet, web/test, or a product the store doesn't offer here).
  String? priceFor(String productId) =>
      productId.isEmpty ? null : _prices[productId];

  /// [productId]'s store price if known, else [cents] as a plain USD figure —
  /// the one call every price label goes through, so no surface has to know
  /// whether the store has answered.
  String money(int cents, {String productId = ''}) =>
      priceFor(productId) ?? usd(cents);

  /// Cents as a plain USD figure, always two decimals ('$5.00', '$2.99') — the
  /// fallback when there is no store price to show, matching the format the
  /// purchase surfaces used before store prices existed.
  static String usd(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  /// Every product id the app shows a price for anywhere.
  static Set<String> allIds() => <String>{
        for (final t in StorePurchases.tipProducts) t.id,
        for (var i = 0; i < 4; i++) StorePurchases.creatorSubProductId(i),
        for (var i = 0; i < 4; i++) StorePurchases.communitySubProductId(i),
        StorePurchases.aiPassProductId,
        for (final gb in StorageStore.sizes) StorePurchases.storageProductId(gb),
      }..removeWhere((id) => id.isEmpty);

  bool _loading = false;

  /// Asks the store for every product's price and caches the answers. Safe to
  /// call repeatedly; a no-op where there is no store to ask (web / test),
  /// which leaves the USD fallback in place.
  Future<void> load() async {
    if (_loading || !AppleIap.isSupported) return;
    _loading = true;
    try {
      final r = await AppleIap.query(allIds());
      if (r.onSale.isNotEmpty) {
        _prices.addAll(r.onSale);
        notifyListeners();
      }
    } catch (_) {
      // Leave the fallback in place; a purchase still charges the store price.
    } finally {
      _loading = false;
    }
  }

  @visibleForTesting
  void debugSet(Map<String, String> prices) {
    _prices
      ..clear()
      ..addAll(prices);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _prices.clear();
    _loading = false;
  }
}
