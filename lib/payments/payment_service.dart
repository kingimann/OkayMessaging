import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';
import 'stripe_sheet.dart';

/// Raised when a payment Edge Function returns an error.
class PaymentException implements Exception {
  final String code;
  PaymentException(this.code);
  @override
  String toString() => code;
}

/// The caller's wallet / KYC status, read live from Stripe via the backend.
@immutable
class WalletStatus {
  final bool onboarded;
  final bool chargesEnabled;
  final bool payoutsEnabled;
  final int availableCents;
  final int pendingCents;
  final String currency;
  final String? payoutStatus;
  final int? payoutAmountCents;

  const WalletStatus({
    required this.onboarded,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    this.availableCents = 0,
    this.pendingCents = 0,
    this.currency = 'cad',
    this.payoutStatus,
    this.payoutAmountCents,
  });

  bool get canReceive => chargesEnabled && payoutsEnabled;
  String money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  factory WalletStatus.fromJson(Map<String, dynamic> j) => WalletStatus(
        onboarded: j['onboarded'] as bool? ?? false,
        chargesEnabled: j['chargesEnabled'] as bool? ?? false,
        payoutsEnabled: j['payoutsEnabled'] as bool? ?? false,
        availableCents: (j['available'] as num?)?.toInt() ?? 0,
        pendingCents: (j['pending'] as num?)?.toInt() ?? 0,
        currency: j['currency'] as String? ?? 'cad',
        payoutStatus: (j['payout'] as Map?)?['status'] as String?,
        payoutAmountCents: ((j['payout'] as Map?)?['amount'] as num?)?.toInt(),
      );
}

/// Client for the Stripe Connect payment flow. All secret-key work happens in
/// Supabase Edge Functions; this only calls them (with the user's session) and
/// drives the native payment sheet. The platform never holds funds or card data.
class PaymentService {
  PaymentService._();
  static final PaymentService instance = PaymentService._();

  static const String _publishableKey =
      String.fromEnvironment('STRIPE_PUBLISHABLE_KEY', defaultValue: '');
  static const _kTestMode = 'payments_test_mode';

  /// Sandbox mode: simulates the whole send/receive flow with no real Stripe
  /// call and no money movement, so payments can be tried anywhere. Persisted.
  final ValueNotifier<bool> testMode = ValueNotifier<bool>(false);

  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    testMode.value = _prefs!.getBool(_kTestMode) ?? false;
  }

  void setTestMode(bool value) {
    testMode.value = value;
    _prefs?.setBool(_kTestMode, value);
  }

  bool get _realConfigured =>
      _publishableKey.isNotEmpty && RelayConfig.isEnabled;

  /// Payments are usable when really configured, or in test mode.
  bool get isConfigured => testMode.value || _realConfigured;

  /// Whether money can be sent here. Test mode works everywhere (it just
  /// simulates); the real flow needs the native sheet (mobile only).
  bool get canSendOnThisDevice =>
      testMode.value || (_realConfigured && StripeSheet.isSupported);

  SupabaseClient get _client => Supabase.instance.client;

  Future<Map<String, dynamic>> _invoke(String name,
      [Map<String, dynamic>? body]) async {
    final res = await _client.functions.invoke(name, body: body ?? {});
    final data = res.data;
    if (res.status >= 400) {
      final code = data is Map ? (data['error']?.toString() ?? 'error') : 'error';
      throw PaymentException(code);
    }
    return Map<String, dynamic>.from(data as Map);
  }

  /// Starts (or resumes) Express onboarding; returns the Stripe-hosted KYC URL.
  Future<String> onboardingUrl() async {
    final r = await _invoke('payments-onboard');
    return r['url'] as String;
  }

  /// The caller's current wallet + payout status.
  Future<WalletStatus> status() async {
    if (testMode.value) {
      // A believable sandbox wallet so the screens have something to show.
      return const WalletStatus(
        onboarded: true,
        chargesEnabled: true,
        payoutsEnabled: true,
        availableCents: 4215,
        pendingCents: 800,
      );
    }
    return WalletStatus.fromJson(await _invoke('payments-status'));
  }

  /// Full send flow: create a destination PaymentIntent for [toPhone], then
  /// present the native sheet. Returns true when the payment completes. In
  /// test mode the charge is simulated (brief delay, always succeeds).
  Future<bool> sendMoney({
    required String toPhone,
    required int amountCents,
    String? note,
  }) async {
    if (testMode.value) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return true;
    }
    final intent = await _invoke('payments-create-intent', {
      'toPhone': toPhone,
      'amountCents': amountCents,
      'currency': 'cad',
      if (note != null && note.isNotEmpty) 'note': note,
    });
    await StripeSheet.init(_publishableKey);
    return StripeSheet.presentPayment(
      clientSecret: intent['clientSecret'] as String,
      merchantName: 'Okay Messaging',
    );
  }
}
