import 'package:flutter/foundation.dart';

import '../state/storage_store.dart';
import 'apple_iap.dart';
import 'purchase_outcome.dart';
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

  /// Names the currency when the store's own string does not — for
  /// DIAGNOSTICS only.
  ///
  /// The US and Canadian stores both render a bare '\$', so the storefront
  /// check needs a way to say which one it is. A purchase surface must NOT
  /// use this: Apple's sheet prints no code, so a price carrying one can
  /// never look like the same number the sheet shows, and it reads as the app
  /// having picked a currency it has no say over. See [priceFor].
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

  /// The store's localized price for [productId], EXACTLY as StoreKit
  /// formatted it, or null when unknown (not loaded yet, web/test, or a
  /// product the store doesn't offer here).
  ///
  /// **Nothing is appended to it — not the ISO code, not anything.** This used
  /// to add the currency code so a Canadian buyer could tell CA$ from US$,
  /// which was well meant and wrong: Apple's own purchase sheet prints
  /// `$7.99` with no code, so a card reading `$5.99 USD` beside it cannot
  /// look like the same system even when both numbers are right, and it
  /// reads as the app having chosen a currency. The app never chooses;
  /// StoreKit hands over a string already localized for the buyer's
  /// storefront and that string is shown verbatim.
  ///
  /// The currency code is still captured — [_currencies] feeds the storefront
  /// diagnostics, where naming it is the whole point — it just never joins a
  /// price on a purchase surface.
  String? priceFor(String productId) {
    if (productId.isEmpty) return null;
    return _prices[productId];
  }

  /// The ISO code every answered price is quoted in ('USD', 'CAD'), or '' when
  /// the store has not answered or answered in more than one currency.
  ///
  /// For a LINE ABOUT the prices, never appended to one. The distinction is
  /// the whole lesson of this file: Apple's purchase sheet prints a bare '\$'
  /// with no code, so a price carrying one can never look like the same
  /// number — but a sentence naming the storefront's currency once, away from
  /// any figure, is the only thing that tells a buyer whether the '\$' beside
  /// the Buy button is theirs. The US and Canadian stores both print '\$'.
  String get quotedCurrency {
    final codes = <String>{
      for (final c in _currencies.values)
        if (c.isNotEmpty) c.toUpperCase()
    };
    return codes.length == 1 ? codes.first : '';
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
        ...StorePurchases.aiPassProductIds,
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

  /// How many times a phone re-asks before it accepts that there is no
  /// price. StoreKit is routinely not ready in the first second after launch
  /// — the query comes back empty or throws — and a single attempt turned
  /// that into a screen with no price on it until the app was backgrounded
  /// and reopened. Off-device there is nothing to re-ask, so one attempt.
  static const int _attempts = 3;

  /// Asks the store for every product's price and caches the answers. Safe to
  /// call repeatedly; a no-op where there is no store to ask (web / test),
  /// which leaves the USD fallback in place.
  ///
  /// An answer that is empty OR SHORT is treated as a failure worth retrying
  /// rather than the truth. Accepting the first one set `answered`, so every
  /// product absent from it read "Unavailable" for the rest of the session —
  /// the same screen a genuinely missing product gives, which made a
  /// transient blip indistinguishable from a real misconfiguration. Missing
  /// SOME products is the commonest shape of this and the one that produces
  /// "a few of the prices are wrong".
  Future<void> load() async {
    if (_loading || !AppleIap.isSupported) return;
    _loading = true;
    try {
      final ids = allIds();
      final tries = AppleIap.hasRealStore ? _attempts : 1;
      // The richest answer any attempt produced. A query can come back
      // PARTIAL — some products priced, others silently absent — and
      // accepting the first one made every absent product read "Unavailable"
      // for the session even though the next ask would have priced it. That
      // is the "some prices are right and some are wrong" shape exactly, so
      // attempts are kept and the fullest one wins rather than the last one.
      StoreQueryResult? best;
      for (var attempt = 0; attempt < tries; attempt++) {
        final last = attempt == tries - 1;
        StoreQueryResult? r;
        try {
          r = await AppleIap.query(ids);
        } catch (_) {
          r = null; // treated as unreachable below
        }
        if (r != null && r.storeReachable) {
          if (best == null || r.onSale.length > best.onSale.length) best = r;
        }

        // Everything the app asked for, priced. Nothing further to gain.
        if (best != null && best.onSale.length >= ids.length) break;
        if (!last) {
          // Short, growing pause. StoreKit usually answers on the second ask.
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
          continue;
        }
      }

      if (best != null) {
        _unreachable = false;
        absorb(best.onSale, reachable: true, currencies: best.currencies);
      } else if (AppleIap.hasRealStore) {
        // Every attempt failed and a store exists on this device. Whatever is
        // charged will be Apple's number, so the app stops printing its own
        // rather than risk naming a different one. Off-device (web, the test
        // suite) "unreachable" is just the normal state of having no store at
        // all, and the plain figure stands.
        _unreachable = true;
        notifyListeners();
      } else {
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
