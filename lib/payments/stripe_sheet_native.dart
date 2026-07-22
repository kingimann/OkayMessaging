import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

/// Native (mobile) implementation of the Stripe Payment Sheet — the fully
/// in-app card / Apple Pay / Google Pay flow, no redirect to Stripe Checkout.
class StripeSheet {
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool _initialized = false;

  static Future<void> init(String publishableKey) async {
    if (_initialized || publishableKey.isEmpty) return;
    stripe.Stripe.publishableKey = publishableKey;
    // Set your Apple Pay merchant id here once you have one.
    await stripe.Stripe.instance.applySettings();
    _initialized = true;
  }

  /// Presents the payment sheet for [clientSecret]. Returns true on a completed
  /// payment, false if the user cancels or it fails.
  static Future<bool> presentPayment({
    required String clientSecret,
    required String merchantName,
  }) async {
    await stripe.Stripe.instance.initPaymentSheet(
      paymentSheetParameters: stripe.SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: merchantName,
        applePay: const stripe.PaymentSheetApplePay(merchantCountryCode: 'CA'),
        googlePay: const stripe.PaymentSheetGooglePay(
          merchantCountryCode: 'CA',
          testEnv: true, // flip to false for production
        ),
      ),
    );
    try {
      await stripe.Stripe.instance.presentPaymentSheet();
      return true;
    } on stripe.StripeException {
      return false;
    }
  }
}
