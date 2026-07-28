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
  static Completer<String?>? _pending;
  static String? _pendingId;

  /// Called with Apple's signed transaction for every delivered purchase —
  /// including restores and the renewals StoreKit replays on launch, which
  /// never pass through [buy]. Wired to the entitlement service so a
  /// subscription that renewed while the app was closed still lands.
  static void Function(String jws)? onTransaction;

  static Future<void> init() async {
    _sub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (_) => _resolvePending(null),
    );
  }

  static Future<bool> storeAvailable() => _iap.isAvailable();

  /// Presents the store sheet for [productId] and completes when the purchase
  /// resolves. Returns Apple's signed transaction (JWS) on success, or null on
  /// cancel, error, or an unknown product. The caller hands that token to
  /// `iap-validate`; the app itself never decides what a purchase granted.
  static Future<String?> buy(String productId, {bool consumable = false}) async {
    await init();
    if (!await _iap.isAvailable()) return null;
    final resp = await _iap.queryProductDetails({productId});
    if (resp.productDetails.isEmpty) return null;
    final param = PurchaseParam(productDetails: resp.productDetails.first);

    _pending = Completer<String?>();
    _pendingId = productId;
    final started = consumable
        ? await _iap.buyConsumable(purchaseParam: param)
        : await _iap.buyNonConsumable(purchaseParam: param);
    if (!started) {
      _pending = null;
      _pendingId = null;
      return null;
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
          final jws = p.verificationData.serverVerificationData;
          if (jws.isNotEmpty) onTransaction?.call(jws);
          if (p.productID == _pendingId) _resolvePending(jws);
        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          if (p.productID == _pendingId) _resolvePending(null);
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  static void _resolvePending(String? jws) {
    final c = _pending;
    _pending = null;
    _pendingId = null;
    if (c != null && !c.isCompleted) c.complete(jws);
  }
}
