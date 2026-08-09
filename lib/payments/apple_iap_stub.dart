import 'purchase_outcome.dart';

/// Web / default implementation. In-app purchases only exist in the native
/// app, so this reports unsupported and never references the plugin.
class AppleIap {
  static bool get isSupported => false;

  /// No store on the web, ever.
  static bool get hasRealStore => false;

  /// Never fires here; declared so the entitlement service can wire itself up
  /// without a platform check.
  static void Function(String jws)? onTransaction;

  static Future<void> init() async {}

  static Future<bool> storeAvailable() async => false;

  /// There is no store here, and saying so is better than throwing: the
  /// caller has a message for it, and a web build reaching this is a person
  /// who tapped Buy, not a bug.
  static Future<PurchaseResult> buy(String productId,
          {bool consumable = false}) async =>
      const PurchaseResult(PurchaseOutcome.unavailable);

  static Future<void> restore() async {}

  /// No storefront on the web — there is no store to have one.
  static Future<String> storefront() async => '';

  /// No store to ask on this platform.
  static Future<StoreQueryResult> query(Set<String> ids) async =>
      StoreQueryResult(storeReachable: false, notOffered: ids.toList());
}
