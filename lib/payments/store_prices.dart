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
  final Map<String, String> _currencies = {};

  /// Names the currency when the store's own string does not.
  ///
  /// Apple hands back a price already formatted for the buyer's storefront,
  /// but the US and Canadian stores BOTH render a bare '$' — so a Canadian
  /// buyer shown "$1.99" cannot tell whether they are being quoted CAD or
  /// USD, and reads it as the US price. When the string carries no letters
  /// of its own the ISO code is appended: "$1.99 CAD". A string that already
  /// disambiguates ('CA$1.99', '€1,99') is left exactly as Apple wrote it.
  static String labelled(String raw, String? code) {
    if (code == null || code.isEmpty) return raw;
    if (raw.contains(RegExp('[A-Za-z]'))) return raw;
    return '$raw $code';
  }

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
  String? priceFor(String productId) {
    if (productId.isEmpty) return null;
    final raw = _prices[productId];
    if (raw == null) return null;
    return labelled(raw, _currencies[productId]);
  }

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

  /// True while a real store exists and has not answered YET — the app has
  /// asked (or is about to) and simply does not know the price at this
  /// instant.
  ///
  /// This is what separates a spinner from a dash, and the two must never be
  /// confused. A dash says "we asked and the store did not answer"; a spinner
  /// says "wait a moment". Both used to render as the same '—', so a price
  /// that was one second away looked identical to one that was never coming,
  /// and the first thing anybody does with the second is assume the app is
  /// broken.
  ///
  /// Off-device — web, payments-test mode, the whole suite — there is no store
  /// to wait for, so this is false and the plain figure stands.
  bool get awaitingStore =>
      debugAwaitingStore ??
      (AppleIap.hasRealStore && !_answered && !_unreachable);

  /// The suite runs on linux, where [AppleIap.hasRealStore] is false and the
  /// waiting state can therefore never occur — so the one state that only
  /// exists on a phone would be the one state nothing covers.
  @visibleForTesting
  static bool? debugAwaitingStore;

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
    // On a phone, App Store Connect is the ONLY authority on what a product
    // costs, and StoreKit is the only way to read it. Anything computed here
    // — the built-in cents, an owner-published figure — is the app's own
    // guess, and a guess printed beside a Buy button is a promise the charge
    // may not keep. So a device with a store shows Apple's price or nothing.
    //
    // This is the rule the AI pass already followed by carrying `cents: 0`
    // ("the store's price, or nothing"); tips and storage carried real
    // fallback cents and so could show a figure Apple had never agreed to.
    // Now every product behaves the same way.
    if (AppleIap.hasRealStore) return unknownLabel;
    // Off-device there is no store to contradict and nothing purchasable:
    // web, payments-test mode and the whole test suite keep a plain figure.
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
  void absorb(Map<String, String> onSale,
      {bool reachable = false, Map<String, String> currencies = const {}}) {
    if (onSale.isEmpty && !reachable) return;
    // A fresh full answer REPLACES what was cached: a product dropped from
    // sale must stop showing its old price.
    if (reachable) {
      _prices.clear();
      _currencies.clear();
    }
    _prices.addAll(onSale);
    _currencies.addAll(currencies);
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
        absorb(r.onSale, reachable: true, currencies: r.currencies);
      } else {
        // A store exists on this device and could not be reached. Whatever
        // is charged will be Apple's number, so the app stops printing its
        // own rather than risk naming a different one. Off-device (web, the
        // test suite) "unreachable" is just the normal state of having no
        // store at all, and the plain figure stands — the same distinction
        // the catch below draws.
        if (AppleIap.hasRealStore) _unreachable = true;
        if (r.onSale.isNotEmpty) absorb(r.onSale);
        notifyListeners();
      }
    } catch (_) {
      // A thrown query on a REAL phone is the case that produced "it shows
      // USD even when I change my App Store region": the app learned
      // nothing, kept printing the cents hardcoded in the source, and those
      // are dollars. On a device with a store, not knowing has to look like
      // not knowing. Off-device (web, the test suite) there is no charge to
      // be contradicted by, so the plain figure stands.
      if (AppleIap.hasRealStore) {
        _unreachable = true;
        notifyListeners();
      }
    } finally {
      _loading = false;
    }
  }

  @visibleForTesting
  void debugSet(Map<String, String> prices,
      {bool answered = false,
      bool unreachable = false,
      Map<String, String> currencies = const {}}) {
    _prices
      ..clear()
      ..addAll(prices);
    _currencies
      ..clear()
      ..addAll(currencies);
    _answered = answered;
    _unreachable = unreachable;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _prices.clear();
    _currencies.clear();
    _loading = false;
    _answered = false;
    _unreachable = false;
    debugAwaitingStore = null;
  }
}
