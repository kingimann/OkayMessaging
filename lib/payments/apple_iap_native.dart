import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'purchase_outcome.dart';

/// Native in-app purchases (Apple App Store / Google Play).
///
/// Apple requires that digital goods consumed in the app — the cloud-storage
/// subscription and tipping the developer — be sold through StoreKit, not a
/// third-party processor. This wraps [InAppPurchase] behind a small, awaitable
/// [buy] so callers don't have to manage the purchase stream.
///
/// The product IDs referenced here must exist in App Store Connect (and Play
/// Console); until they do, [buy] returns false rather than charging anything.
class AppleIap {
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// Whether this process is REALLY running on a phone with a store.
  ///
  /// Deliberately dart:io's [Platform] and not [defaultTargetPlatform]:
  /// flutter_test overrides the latter to android, so [isSupported] is true
  /// in the suite and cannot tell a test from an iPhone. Platform reflects
  /// the host — linux under `flutter test`, iOS on a device — which is the
  /// distinction needed before deciding that a failed price query means
  /// "this buyer has a store and we could not read it" rather than "there is
  /// no store here, show the plain figure".
  static bool get hasRealStore =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static final InAppPurchase _iap = InAppPurchase.instance;
  static StreamSubscription<List<PurchaseDetails>>? _sub;

  // Only one purchase is ever in flight from the UI at a time.
  static Completer<PurchaseResult>? _pending;
  static String? _pendingId;

  /// Called with Apple's signed transaction for every delivered purchase —
  /// including restores and the renewals StoreKit replays on launch, which
  /// never pass through [buy]. Wired to the entitlement service so a
  /// subscription that renewed while the app was closed still lands.
  static void Function(String jws)? onTransaction;

  /// Every entry point below short-circuits on this rather than talking to
  /// the billing plugin, and a try/catch is NOT an adequate substitute.
  ///
  /// Off a real device the channel has no host side, and the Play plugin
  /// signals that failure from a DETACHED microtask
  /// (`BillingClientManager.runWithClientNonRetryable` → `scheduleMicrotask`)
  /// rather than through the future it returned. Nothing wrapping the await
  /// can catch it; it lands as an unhandled async error blamed on whatever
  /// is running by the time it fires. Not asking is the only way not to be
  /// told — and it is also the honest answer, since a host with no store has
  /// no prices, no purchases and no storefront.
  static bool get _noStore => !hasRealStore;

  static Future<void> init() async {
    if (_noStore) return;
    _sub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (_) =>
          _resolvePending(const PurchaseResult(PurchaseOutcome.failed)),
    );
  }

  static Future<bool> storeAvailable() async {
    if (_noStore) return false;
    try {
      return await _iap.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Presents the store sheet for [productId] and completes when the purchase
  /// resolves. The caller hands the returned token to `iap-validate`; the app
  /// itself never decides what a purchase granted.
  ///
  /// Every way this can end is named. It used to return a bare nullable
  /// string, and null meant any of "no store", "no such product", "wouldn't
  /// start", "errored" and "they cancelled" — which is how a product that was
  /// never created in App Store Connect came out as "Purchase cancelled."
  static Future<PurchaseResult> buy(String productId,
      {bool consumable = false}) async {
    if (_noStore) return const PurchaseResult(PurchaseOutcome.unavailable);
    await init();
    if (!await storeAvailable()) {
      return const PurchaseResult(PurchaseOutcome.unavailable);
    }
    final resp = await _iap.queryProductDetails({productId});
    // notFoundIDs is Apple saying it has never heard of it. An empty details
    // list with no error is the same thing said more quietly.
    if (resp.productDetails.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    final param = PurchaseParam(productDetails: resp.productDetails.first);

    _pending = Completer<PurchaseResult>();
    _pendingId = productId;
    final started = consumable
        ? await _iap.buyConsumable(purchaseParam: param)
        : await _iap.buyNonConsumable(purchaseParam: param);
    if (!started) {
      _pending = null;
      _pendingId = null;
      return const PurchaseResult(PurchaseOutcome.failed);
    }
    return _pending!.future;
  }

  static Future<void> restore() async {
    if (_noStore) return;
    try {
      await _iap.restorePurchases();
    } catch (_) {
      // Nothing to restore from an unreachable store. Swallowed rather than
      // thrown for the same reason as [query]: this is fired without an
      // await at several call sites, so an escaping PlatformException
      // becomes an unhandled async error somewhere unrelated.
    }
  }

  /// The App Store / Play country whose prices this device is being quoted,
  /// as an ISO country code ('USA', 'CAN'), or '' when it cannot be read.
  ///
  /// This is the answer to "why am I being charged USD when I live in
  /// Canada": the currency comes from the STOREFRONT — the country on the
  /// account signed into the store — not from the device's region, its IP,
  /// or what was configured in App Store Connect. Nothing the app does can
  /// change it, so the useful thing is to be able to name it.
  static Future<String> storefront() async {
    if (_noStore) return '';
    try {
      return await _iap.countryCode();
    } catch (_) {
      // An unreadable storefront is reported as unknown, never guessed.
      return '';
    }
  }

  /// Asks the store which of [ids] it will actually sell here, without
  /// opening any sheet. This is the diagnostic behind "it's set up in App
  /// Store Connect but says it isn't on sale": the store's answer separates
  /// an ID mismatch (some found, some not) from an account-level problem
  /// like an inactive Paid Apps agreement (none found).
  static Future<StoreQueryResult> query(Set<String> ids) async {
    // A store that cannot be talked to IS an unreachable store, so it is
    // reported rather than thrown. The billing channel raises a
    // PlatformException wherever the plugin has no host side — and because
    // isAvailable() is awaited, that throw used to escape the caller and
    // surface later as an unhandled async error attributed to whatever was
    // running by then.
    if (_noStore) {
      return StoreQueryResult(storeReachable: false, notOffered: ids.toList());
    }
    try {
      await init();
      if (!await _iap.isAvailable()) {
        return StoreQueryResult(
            storeReachable: false, notOffered: ids.toList());
      }
      final resp = await _iap.queryProductDetails(ids);
      return StoreQueryResult(
        storeReachable: true,
        onSale: {for (final p in resp.productDetails) p.id: p.price},
        currencies: {
          for (final p in resp.productDetails) p.id: p.currencyCode,
        },
        titles: {
          for (final p in resp.productDetails) p.id: p.title,
        },
        notOffered: resp.notFoundIDs,
      );
    } catch (_) {
      return StoreQueryResult(storeReachable: false, notOffered: ids.toList());
    }
  }

  static void _onPurchases(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Storefront requires acknowledging every delivered purchase.
          if (p.pendingCompletePurchase) _iap.completePurchase(p);
          final jws = p.verificationData.serverVerificationData;
          if (jws.isNotEmpty) onTransaction?.call(jws);
          if (p.productID == _pendingId) {
            _resolvePending(jws.isEmpty
                ? const PurchaseResult(PurchaseOutcome.failed)
                : PurchaseResult.bought(jws));
          }
        // Kept apart, because they are different things to be told.
        case PurchaseStatus.error:
          if (p.productID == _pendingId) {
            _resolvePending(const PurchaseResult(PurchaseOutcome.failed));
          }
        case PurchaseStatus.canceled:
          if (p.productID == _pendingId) {
            _resolvePending(const PurchaseResult(PurchaseOutcome.cancelled));
          }
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  static void _resolvePending(PurchaseResult result) {
    final c = _pending;
    _pending = null;
    _pendingId = null;
    if (c != null && !c.isCompleted) c.complete(result);
  }
}
