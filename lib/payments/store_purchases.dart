import '../state/storage_store.dart';
import 'apple_iap.dart';
import 'payment_service.dart';

/// Digital purchases that MUST go through the platform store (Apple / Google),
/// not Stripe: the cloud-storage subscription and tipping the developer. Stripe
/// stays reserved for real-world peer-to-peer transfers ([PaymentService]).
///
/// Every purchase resolves to a simple bool. In payments test mode it's
/// simulated (so the flows can be exercised anywhere); otherwise it drives the
/// real store sheet via [AppleIap]. The product IDs below must be created in
/// App Store Connect / Play Console before real charges can happen.
class StorePurchases {
  StorePurchases._();
  static final StorePurchases instance = StorePurchases._();

  static const _prefix = 'com.okaymessaging';

  /// Auto-renewable storage subscription, one per paid tier.
  static String storageProductId(StorageTier tier) => switch (tier) {
        StorageTier.free => '', // free needs no purchase
        StorageTier.personal => '$_prefix.storage.personal.monthly',
        StorageTier.plus => '$_prefix.storage.plus.monthly',
      };

  /// Fixed consumable tip products. Apple doesn't allow arbitrary amounts, so
  /// support is a small set of set prices.
  static const List<({int cents, String emoji, String label, String id})>
      tipProducts = [
    (cents: 299, emoji: '☕', label: 'Coffee', id: '$_prefix.tip.coffee'),
    (cents: 599, emoji: '🍩', label: 'Snack', id: '$_prefix.tip.snack'),
    (cents: 1099, emoji: '🍕', label: 'Lunch', id: '$_prefix.tip.lunch'),
    (cents: 2499, emoji: '🎉', label: 'Generous', id: '$_prefix.tip.generous'),
  ];

  bool get _testMode => PaymentService.instance.testMode.value;

  /// Whether store purchases can be made here: test mode works everywhere;
  /// the real store is mobile-only.
  bool get isSupported => _testMode || AppleIap.isSupported;

  /// Buys (or renews) the storage subscription for [tier]. Returns true when
  /// the purchase completes.
  Future<bool> buyStorage(StorageTier tier) async {
    final id = storageProductId(tier);
    if (id.isEmpty) return false;
    if (_testMode) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return true;
    }
    return AppleIap.buy(id, consumable: false);
  }

  /// Sends a tip to the developer via a consumable in-app purchase.
  Future<bool> tip(String productId) async {
    if (_testMode) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return true;
    }
    return AppleIap.buy(productId, consumable: true);
  }
}
