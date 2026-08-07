import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

/// Native (mobile) implementation of the Stripe Payment Sheet — the fully
/// in-app card / Apple Pay / Google Pay flow, no redirect to Stripe Checkout.
class StripeSheet {
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The reason the last [presentPayment] failed, or null when it succeeded or
  /// the user simply cancelled. Read right after a false return to tell the
  /// person WHY a charge failed instead of a blank "it didn't go through".
  static String? lastError;

  /// Apple Pay merchant id, e.g. `merchant.com.okaymessaging`. Created in the
  /// Apple developer portal (Identifiers → Merchant IDs) and enabled on the
  /// App ID's Apple Pay capability.
  ///
  /// Apple Pay is offered ONLY when this is set. Handing the sheet an
  /// `applePay` config with no merchant id doesn't degrade gracefully — the
  /// button either fails to appear or errors on tap — so until the id exists
  /// the sheet is better off showing cards alone.
  static const String appleMerchantId =
      String.fromEnvironment('APPLE_PAY_MERCHANT_ID', defaultValue: '');

  /// Two-letter country of the *platform's* Stripe account. Both wallets
  /// require it, and it has to match the account the charge settles into.
  static const String merchantCountry =
      String.fromEnvironment('PAYMENTS_COUNTRY', defaultValue: 'CA');

  static bool _initialized = false;

  static Future<void> init(String publishableKey) async {
    if (_initialized || publishableKey.isEmpty) return;
    stripe.Stripe.publishableKey = publishableKey;
    if (appleMerchantId.isNotEmpty) {
      stripe.Stripe.merchantIdentifier = appleMerchantId;
    }
    await stripe.Stripe.instance.applySettings();
    _initialized = true;
  }

  /// Presents the payment sheet for [clientSecret]. Returns true on a completed
  /// payment, false if the user cancels or it fails.
  /// [stripeAccountId] is the connected account a direct charge was created
  /// on. The client secret is meaningless to the SDK without it, so it is set
  /// before the sheet opens and cleared afterwards — leaving it set would
  /// silently scope the next unrelated call to someone else's account.
  static Future<bool> presentPayment({
    required String clientSecret,
    required String merchantName,
    String? stripeAccountId,
  }) async {
    if (stripeAccountId != null && stripeAccountId.isNotEmpty) {
      stripe.Stripe.stripeAccountId = stripeAccountId;
      await stripe.Stripe.instance.applySettings();
    }
    try {
      return await _present(
          clientSecret: clientSecret, merchantName: merchantName);
    } finally {
      if (stripeAccountId != null && stripeAccountId.isNotEmpty) {
        stripe.Stripe.stripeAccountId = null;
        await stripe.Stripe.instance.applySettings();
      }
    }
  }

  static Future<bool> _present({
    required String clientSecret,
    required String merchantName,
  }) async {
    await stripe.Stripe.instance.initPaymentSheet(
      paymentSheetParameters: stripe.SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: merchantName,
        applePay: appleMerchantId.isEmpty
            ? null
            : const stripe.PaymentSheetApplePay(
                merchantCountryCode: merchantCountry),
        googlePay: const stripe.PaymentSheetGooglePay(
          merchantCountryCode: merchantCountry,
          // Release builds must reach Google Pay's real environment. Pinned
          // to true, this would have shipped a live key aimed at the test
          // wallet, where no real card can pay.
          testEnv: kDebugMode,
        ),
      ),
    );
    try {
      await stripe.Stripe.instance.presentPaymentSheet();
      lastError = null;
      return true;
    } on stripe.StripeException catch (e) {
      // A user cancel is a quiet "nothing happened"; anything else is a real
      // failure whose reason the caller can show instead of a blank "failed".
      lastError = e.error.code == stripe.FailureCode.Canceled
          ? null
          : (e.error.localizedMessage ?? e.error.message);
      return false;
    }
  }
}
