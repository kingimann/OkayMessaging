import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';
import '../state/account_email.dart';
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
/// One transfer, from this account's point of view.
class PaymentRecord {
  final String id;
  final bool sent;
  final String otherPhone;
  final int amountCents;
  final int feeCents;
  final String currency;
  final String status;
  final DateTime? at;

  const PaymentRecord({
    required this.id,
    required this.sent,
    required this.otherPhone,
    required this.amountCents,
    required this.feeCents,
    required this.currency,
    required this.status,
    this.at,
  });

  /// Whether the money actually moved.
  bool get isComplete => status == 'succeeded' || status == 'paid';

  /// Refused by a card rule rather than failing on its own.
  bool get isBlocked => status.startsWith('blocked_');

  bool get isPending => status == 'pending' || status == 'requires_capture';

  /// Why it was refused, in words.
  String get blockedReason => switch (status) {
        'blocked_prepaid' => 'Prepaid card',
        'blocked_name_mismatch' => 'Card name did not match',
        'blocked_unknown_card' => 'Card could not be checked',
        _ => 'Blocked',
      };

  factory PaymentRecord.fromJson(Map<String, dynamic> j) => PaymentRecord(
        id: j['id'] as String? ?? '',
        sent: j['direction'] == 'sent',
        otherPhone: j['otherPhone'] as String? ?? '',
        amountCents: (j['amountCents'] as num?)?.toInt() ?? 0,
        feeCents: (j['feeCents'] as num?)?.toInt() ?? 0,
        currency: (j['currency'] as String? ?? 'cad').toUpperCase(),
        status: j['status'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '')?.toLocal(),
      );
}

/// Who may pay this account, and how much it may send in a day.
class PaymentControls {
  final String acceptsFrom; // 'anyone' | 'nobody'
  final int dailySendLimitCents;
  final List<String> blocked;

  const PaymentControls({
    this.acceptsFrom = 'anyone',
    this.dailySendLimitCents = 50000,
    this.blocked = const [],
  });

  bool get acceptsAnyone => acceptsFrom == 'anyone';

  factory PaymentControls.fromJson(Map<String, dynamic> j) => PaymentControls(
        acceptsFrom: j['acceptsFrom'] as String? ?? 'anyone',
        dailySendLimitCents:
            (j['dailySendLimitCents'] as num?)?.toInt() ?? 50000,
        blocked: [
          for (final b in (j['blocked'] as List? ?? const []))
            if (b is String) b
        ],
      );
}

/// Everything the embedded onboarding page needs to start.
class ConnectSession {
  final String clientSecret;
  final String publishableKey;
  final String pageUrl;
  const ConnectSession({
    required this.clientSecret,
    required this.publishableKey,
    required this.pageUrl,
  });
}

class PaymentService {
  PaymentService._();
  static final PaymentService instance = PaymentService._();

  static const String _publishableKey =
      String.fromEnvironment('STRIPE_PUBLISHABLE_KEY', defaultValue: '');

  /// The client-safe key, for anything that has to initialise Stripe.js
  /// itself (the embedded onboarding and ID-check pages).
  static String get publishableKey => _publishableKey;

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

  /// The PaymentIntent from the most recent [sendMoney]. The charge is
  /// authorised before it is captured, so the caller needs this to find out
  /// how it ended.
  String lastPaymentIntentId = '';

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
  ///
  /// Kept as the fallback for anywhere the embedded flow can't run (the web
  /// build has no WebView). Prefer [connectSession].
  Future<String> onboardingUrl() async {
    final r = await _invoke('payments-onboard');
    return r['url'] as String;
  }

  /// Where the embedded onboarding page lives. It ships with the web build,
  /// so it sits next to the app's own deployment.
  static const String connectPageUrl = String.fromEnvironment(
    'CONNECT_PAGE_URL',
    defaultValue: 'https://kingimann.github.io/OkayMessaging/connect.html',
  );

  /// The caller's transfers, newest first, both directions.
  Future<List<PaymentRecord>> history({int limit = 100}) async {
    final r = await _invoke('payments-history', {'limit': limit});
    final raw = r['transactions'];
    if (raw is! List) return const [];
    return [
      for (final t in raw.whereType<Map>())
        PaymentRecord.fromJson(Map<String, dynamic>.from(t))
    ];
  }

  /// Reads the account's payment controls. Passing values updates them.
  Future<PaymentControls> controls({
    String? acceptsFrom,
    int? dailySendLimitCents,
    String? block,
    String? unblock,
  }) async {
    final r = await _invoke('payments-settings', {
      if (acceptsFrom != null) 'acceptsFrom': acceptsFrom,
      if (dailySendLimitCents != null)
        'dailySendLimitCents': dailySendLimitCents,
      if (block != null) 'block': block,
      if (unblock != null) 'unblock': unblock,
    });
    return PaymentControls.fromJson(r);
  }

  /// Waits for a transfer to settle.
  ///
  /// The card is authorised, then judged, then captured — so the answer isn't
  /// known the moment the payment sheet closes. Polls briefly and returns the
  /// final status, or 'pending' if it is still undecided (the webhook will
  /// have finished long before this gives up in practice).
  Future<String> awaitSettlement(String paymentIntentId,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await _invoke(
            'payments-intent-status', {'paymentIntentId': paymentIntentId});
        final status = r['status'] as String? ?? '';
        if (status.isNotEmpty &&
            status != 'pending' &&
            status != 'requires_capture' &&
            status != 'unknown') {
          return status;
        }
      } catch (_) {
        // Offline mid-poll: keep the receipt pending rather than claim it
        // failed. The server has already decided either way.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return 'pending';
  }

  /// An Account Session for Stripe's Connect embedded components — the
  /// in-app onboarding path, with no browser and no handoff.
  Future<ConnectSession> connectSession() async {
    final r = await _invoke('payments-account-session');
    final secret = r['clientSecret'] as String? ?? '';
    if (secret.isEmpty) throw PaymentException('no_client_secret');
    return ConnectSession(
      clientSecret: secret,
      // The function knows its own publishable key; fall back to the one
      // compiled in, so a missing secret there isn't fatal.
      publishableKey: (r['publishableKey'] as String?)?.isNotEmpty == true
          ? r['publishableKey'] as String
          : _publishableKey,
      pageUrl: connectPageUrl,
    );
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
    bool acknowledged = false,
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
      // Stripe emails the receipt. A charge the sender has no record of is a
      // charge worth disputing, so give them one.
      if (AccountEmail.instance.isSet)
        'receiptEmail': AccountEmail.instance.email,
      // Recorded as dispute evidence: they were told it was final and said
      // they understood.
      'acknowledged': acknowledged,
    });
    lastPaymentIntentId = intent['paymentIntentId'] as String? ?? '';
    await StripeSheet.init(_publishableKey);
    return StripeSheet.presentPayment(
      clientSecret: intent['clientSecret'] as String,
      merchantName: 'OkayMessenger',
      // Direct charge: the intent lives on the recipient's connected account.
      stripeAccountId: intent['stripeAccountId'] as String?,
    );
  }

  // Cloud storage and developer tips are digital goods and bill through the
  // platform store (Apple / Google), not Stripe — see StorePurchases. Stripe
  // here is strictly for real-world peer-to-peer transfers (sendMoney).
}
