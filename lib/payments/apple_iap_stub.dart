/// Web / default implementation. In-app purchases only exist in the native
/// app, so this reports unsupported and never references the plugin.
class AppleIap {
  static bool get isSupported => false;

  static Future<void> init() async {}

  static Future<bool> storeAvailable() async => false;

  static Future<bool> buy(String productId, {bool consumable = false}) async {
    throw UnsupportedError('In-app purchases are available in the mobile app.');
  }

  static Future<void> restore() async {}
}
