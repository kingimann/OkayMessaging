/// Default / web implementation: the native Stripe Payment Sheet is only
/// available on mobile, so this is a no-op that reports unsupported.
class StripeSheet {
  static bool get isSupported => false;

  static Future<void> init(String publishableKey) async {}

  static Future<bool> presentPayment({
    required String clientSecret,
    required String merchantName,
  }) async {
    throw UnsupportedError('Payments are available in the mobile app.');
  }
}
