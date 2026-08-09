import 'dart:async';

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

  static Future<void> init() async {
    _sub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (_) =>
          _resolvePending(const PurchaseResult(PurchaseOutcome.failed)),
    );
  }

  static Future<bool> storeAvailable() => _iap.isAvailable();

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
    await init();
    if (!await _iap.isAvailable()) {
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

  static Future<void> restore() => _iap.restorePurchases();

  /// Asks the store which of [ids] it will actually sell here, without
  /// opening any sheet. This is the diagnostic behind "it's set up in App
  /// Store Connect but says it isn't on sale": the store's answer separates
  /// an ID mismatch (some found, some not) from an account-level problem
  /// like an inactive Paid Apps agreement (none found).
  static Future<StoreQueryResult> query(Set<String> ids) async {
    await init();
    if (!await _iap.isAvailable()) {
      return StoreQueryResult(storeReachable: false, notOffered: ids.toList());
    }
    final resp = await _iap.queryProductDetails(ids);
    return StoreQueryResult(
      storeReachable: true,
      onSale: {for (final p in resp.productDetails) p.id: p.price},
      currencies: {
        for (final p in resp.productDetails) p.id: p.currencyCode,
      },
      notOffered: resp.notFoundIDs,
    );
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
