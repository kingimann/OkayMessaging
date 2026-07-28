/// Web / default implementation. In-app purchases only exist in the native
/// app, so this reports unsupported and never references the plugin.
class AppleIap {
  static bool get isSupported => false;

  /// Never fires here; declared so the entitlement service can wire itself up
  /// without a platform check.
  static void Function(String jws)? onTransaction;

  static Future<void> init() async {}

  static Future<bool> storeAvailable() async => false;

  static Future<String?> buy(String productId, {bool consumable = false}) async {
    throw UnsupportedError('In-app purchases are available in the mobile app.');
  }

  static Future<void> restore() async {}
}
