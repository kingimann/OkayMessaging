import 'apple_iap.dart';
import 'purchase_outcome.dart';
import 'iap_entitlement.dart';
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

  /// Auto-renewable storage subscription, one product per purchasable size.
  /// Apple only sells fixed price points, so the size ladder *is* the product
  /// list — `…storage.gb30.monthly` for 30 GB, and so on.
  static String storageProductId(int gb) =>
      gb <= 0 ? '' : '$_prefix.storage.gb$gb.monthly';

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

  /// Buys (or renews) the storage subscription for [gb]. Returns true when the
  /// purchase completes.
  ///
  /// What the purchase *granted* is not decided here: StoreKit's signed
  /// transaction goes to `iap-validate`, and the entitlement that comes back
  /// is what the app honours. Apple renews monthly on its own, so the device
  /// can't be the source of truth.
  Future<PurchaseResult> buyStorage(int gb) async {
    final id = storageProductId(gb);
    if (id.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    if (_testMode) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    final result = await AppleIap.buy(id, consumable: false);
    if (!result.ok) return result;
    // AppleIap.onTransaction has already forwarded this for validation; the
    // await is so the caller sees the entitlement before the screen redraws.
    await IapEntitlement.instance.validate(result.jws!);
    return result;
  }

  /// Sends a tip to the developer via a consumable in-app purchase.
  Future<PurchaseResult> tip(String productId) async {
    if (_testMode) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(productId, consumable: true);
  }

  /// Asks the store which tip products it will sell here.
  Future<StoreQueryResult> checkTips() =>
      AppleIap.query({for (final t in tipProducts) t.id});

  /// Turns the store's answer into the sentence that names the broken link.
  /// Pure, because "products exist in App Store Connect but the store says
  /// not on sale" has four different causes and a failed purchase alone
  /// cannot tell them apart.
  static String tipsCheckVerdict(StoreQueryResult r) {
    if (!r.storeReachable) {
      return 'The App Store isn\'t reachable from here. On an iPhone, check '
          'that this device is signed in to the App Store; anywhere else '
          'there is no store to ask.';
    }
    if (r.notOffered.isEmpty) {
      return 'Every tip product is on sale, at the store\'s own prices above. '
          'If sending a tip still fails, the store sheet itself is refusing — '
          'that is a different error and it will say so.';
    }
    if (r.onSale.isEmpty) {
      return 'The App Store has never heard of ANY tip product, which points '
          'at the account rather than the products. In App Store Connect '
          'check, in order:\n'
          '1. Agreements → the Paid Applications agreement must be Active '
          '(banking and tax complete) — every in-app product is invisible '
          'until it is.\n'
          '2. Each product\'s status must be "Ready to Submit" — "Missing '
          'Metadata" means a name, price or description is still blank.\n'
          '3. Newly created products can take a few hours to reach the '
          'store.\n'
          '4. The products must be under this app (com.okaymessaging), not '
          'another app record.';
    }
    return 'The store offers some tips but has never heard of: '
        '${r.notOffered.join(', ')}. Those exact product IDs must exist in '
        'App Store Connect — a product created under a different ID is a '
        'different product.';
  }
}
