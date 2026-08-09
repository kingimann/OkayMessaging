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

  /// Whether a real store has answered on this device. False on web, in
  /// payments-test mode, and before the first query returns.
  ///
  /// This is what separates "we haven't asked yet" from "we asked and the
  /// store doesn't sell this" — two situations that look identical from a
  /// missing price and need opposite answers on screen.
  bool _answered = false;
  bool get answered => _answered;

  /// The store's localized price for [productId], or null when unknown (not
  /// loaded yet, web/test, or a product the store doesn't offer here).
  String? priceFor(String productId) =>
      productId.isEmpty ? null : _prices[productId];

  /// True when the store has answered and does NOT sell [productId] — so
  /// there is no price to show and nothing to buy.
  bool isUnavailable(String productId) =>
      _answered && productId.isNotEmpty && !_prices.containsKey(productId);

  /// Shown in place of an amount for a product the store won't sell.
  static const String unavailableLabel = 'Unavailable';

  /// Shown where a real store exists but has not told us the price — offline,
  /// signed out of the App Store, or a query that failed. Better than a
  /// number: this device WILL be charged the store's price, so any figure the
  /// app invents here is one it may be contradicted on.
  static const String unknownLabel = '—';

  /// True when a store query completed and reported no reachable store. Not
  /// the same as "we haven't asked": a thrown query teaches nothing and
  /// leaves this false, so tests and the web build keep their fallback.
  bool _unreachable = false;

  /// Whether some price on screen is the placeholder — what a surface shows a
  /// one-line explanation for, rather than leaving a bare dash.
  bool get pricesUnknown => _unreachable && !_answered;

  /// The price label for [productId] — the one call every price surface goes
  /// through, so no screen has to know whether the store has answered.
  ///
  /// Three cases, and the middle one is the reason this is not just a
  /// fallback: the store's own localized price when it has one (already in
  /// the buyer's currency, and exactly what will be charged);
  /// [unavailableLabel] when the store answered and has never heard of the
  /// product; and only where there is NO store to ask — web, payments-test
  /// mode, the frame before the first answer — the [cents] the code assumes,
  /// as a plain USD figure.
  ///
  /// The middle case used to print the USD figure too, which is how a card
  /// came to read "$1.99" beside a purchase sheet charging CA$2.99: an
  /// invented amount, in the wrong currency, for something not on sale. A
  /// price the app cannot know is not a price it should print.
  String money(int cents, {String productId = ''}) {
    final known = priceFor(productId);
    if (known != null) return known;
    if (isUnavailable(productId)) return unavailableLabel;
    if (pricesUnknown) return unknownLabel;
    return usd(cents);
  }

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

  /// Folds a store answer heard by some OTHER query (the store-products
  /// check, say) into the cache. The store's product metadata can lag a price
  /// change in App Store Connect, so any fresher answer that passes through
  /// the app should correct what's on screen.
  ///
  /// [reachable] records that a real store replied, which is what lets an
  /// absent product read as "not on sale" rather than "not asked yet".
  void absorb(Map<String, String> onSale, {bool reachable = false}) {
    if (onSale.isEmpty && !reachable) return;
    // A fresh full answer REPLACES what was cached: a product dropped from
    // sale must stop showing its old price.
    if (reachable) _prices.clear();
    _prices.addAll(onSale);
    if (reachable) _answered = true;
    notifyListeners();
  }

  bool _loading = false;

  /// Asks the store for every product's price and caches the answers. Safe to
  /// call repeatedly; a no-op where there is no store to ask (web / test),
  /// which leaves the USD fallback in place.
  Future<void> load() async {
    if (_loading || !AppleIap.isSupported) return;
    _loading = true;
    try {
      final r = await AppleIap.query(allIds());
      // A reachable store's answer is the whole truth about what is on sale
      // here, so it replaces the cache rather than merging into it.
      if (r.storeReachable) {
        _unreachable = false;
        absorb(r.onSale, reachable: true);
      } else {
        // A store exists on this device and could not be reached. Whatever
        // is charged will be Apple's number, so the app stops printing its
        // own rather than risk naming a different one.
        _unreachable = true;
        if (r.onSale.isNotEmpty) absorb(r.onSale);
        notifyListeners();
      }
    } catch (_) {
      // Leave the fallback in place; a purchase still charges the store price.
    } finally {
      _loading = false;
    }
  }

  @visibleForTesting
  void debugSet(Map<String, String> prices,
      {bool answered = false, bool unreachable = false}) {
    _prices
      ..clear()
      ..addAll(prices);
    _answered = answered;
    _unreachable = unreachable;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _prices.clear();
    _loading = false;
    _answered = false;
    _unreachable = false;
  }
}
