import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

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
  static Completer<bool>? _pending;
  static String? _pendingId;

  static Future<void> init() async {
    _sub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (_) => _resolvePending(false),
    );
  }

  static Future<bool> storeAvailable() => _iap.isAvailable();

  /// Presents the store sheet for [productId] and completes when the purchase
  /// resolves. Returns true on success, false on cancel/error/unknown product.
  static Future<bool> buy(String productId, {bool consumable = false}) async {
    await init();
    if (!await _iap.isAvailable()) return false;
    final resp = await _iap.queryProductDetails({productId});
    if (resp.productDetails.isEmpty) return false;
    final param = PurchaseParam(productDetails: resp.productDetails.first);

    _pending = Completer<bool>();
    _pendingId = productId;
    final started = consumable
        ? await _iap.buyConsumable(purchaseParam: param)
        : await _iap.buyNonConsumable(purchaseParam: param);
    if (!started) {
      _pending = null;
      _pendingId = null;
      return false;
    }
    return _pending!.future;
  }

  static Future<void> restore() => _iap.restorePurchases();

  static void _onPurchases(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Storefront requires acknowledging every delivered purchase.
          if (p.pendingCompletePurchase) _iap.completePurchase(p);
          if (p.productID == _pendingId) _resolvePending(true);
        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          if (p.productID == _pendingId) _resolvePending(false);
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  static void _resolvePending(bool ok) {
    final c = _pending;
    _pending = null;
    _pendingId = null;
    if (c != null && !c.isCompleted) c.complete(ok);
  }
}
