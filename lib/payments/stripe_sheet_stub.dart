/// Default / web implementation: the native Stripe Payment Sheet is only
/// available on mobile, so this is a no-op that reports unsupported.
class StripeSheet {
  static bool get isSupported => false;

  /// Mirrors the native field so callers compile against either backend.
  static String? lastError;

  static const String appleMerchantId = '';
  static const String merchantCountry = 'CA';

  static Future<void> init(String publishableKey) async {}

  static Future<bool> presentPayment({
    required String clientSecret,
    required String merchantName,
    String? stripeAccountId,
  }) async {
    throw UnsupportedError('Payments are available in the mobile app.');
  }
}
