import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/app_pages.dart';
import '../relay/relay_config.dart';
import '../state/account_email.dart';
import 'connect_fields.dart';
import 'storage_economics.dart';
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

  /// What can go to a debit card in minutes. Stripe keeps this as its own
  /// bucket, not a slice of [availableCents] — offering the ordinary balance
  /// beside an instant button would promise money Stripe refuses to move.
  final int instantAvailableCents;

  /// The connected account's country, which sets Stripe's instant fee.
  final String? country;

  final bool hasDebitCard;
  final String? cardLast4;
  final String? cardBrand;

  /// Business days before a freshly added card may receive instant payouts
  /// (0 = usable now). The takeover safeguard: an attacker who attaches
  /// their own card waits a week in front of a balance they cannot touch.
  final int cardHoldDaysLeft;

  /// Instant payouts locked because the card changed too often. Releases on
  /// its own as the changes age past thirty days.
  final bool cardLocked;

  /// The direct-deposit account payouts land on, by its last digits ('' =
  /// none visible), and the business days before a CHANGED one may receive
  /// payouts again — the same takeover shield the card wears, on the other
  /// place money leaves through.
  final String bankLast4;
  final int bankHoldDaysLeft;

  const WalletStatus({
    required this.onboarded,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    this.availableCents = 0,
    this.pendingCents = 0,
    this.instantAvailableCents = 0,
    this.currency = 'cad',
    this.country,
    this.hasDebitCard = false,
    this.cardLast4,
    this.cardBrand,
    this.cardHoldDaysLeft = 0,
    this.cardLocked = false,
    this.bankLast4 = '',
    this.bankHoldDaysLeft = 0,
    this.payoutStatus,
    this.payoutAmountCents,
  });

  bool get canReceive => chargesEnabled && payoutsEnabled;
  String money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  /// Whether the instant button should be offered at all. Every condition
  /// here is one Stripe would otherwise refuse on, and a button that can only
  /// fail is worse than one that isn't there.
  bool get canCashOutInstantly =>
      payoutsEnabled &&
      hasDebitCard &&
      cardHoldDaysLeft == 0 &&
      !cardLocked &&
      InstantPayoutEconomics.isSupportedIn(country) &&
      InstantPayoutEconomics.isWorthCashingOut(instantAvailableCents);

  factory WalletStatus.fromJson(Map<String, dynamic> j) => WalletStatus(
        onboarded: j['onboarded'] as bool? ?? false,
        chargesEnabled: j['chargesEnabled'] as bool? ?? false,
        payoutsEnabled: j['payoutsEnabled'] as bool? ?? false,
        availableCents: (j['available'] as num?)?.toInt() ?? 0,
        pendingCents: (j['pending'] as num?)?.toInt() ?? 0,
        instantAvailableCents:
            (j['instantAvailable'] as num?)?.toInt() ?? 0,
        currency: j['currency'] as String? ?? 'cad',
        country: j['country'] as String?,
        hasDebitCard: j['hasDebitCard'] as bool? ?? false,
        cardLast4: j['cardLast4'] as String?,
        cardBrand: j['cardBrand'] as String?,
        cardHoldDaysLeft:
            (j['cardHoldBusinessDaysLeft'] as num?)?.toInt() ?? 0,
        cardLocked: j['cardLocked'] as bool? ?? false,
        bankLast4: j['bankLast4'] as String? ?? '',
        bankHoldDaysLeft:
            (j['bankHoldBusinessDaysLeft'] as num?)?.toInt() ?? 0,
        payoutStatus: (j['payout'] as Map?)?['status'] as String?,
        payoutAmountCents: ((j['payout'] as Map?)?['amount'] as num?)?.toInt(),
      );
}

/// What came back from asking to cash out.
class PayoutOutcome {
  final bool ok;
  final String? error;
  final int amountCents;
  final int feeCents;
  final String? arrivalDate;

  const PayoutOutcome({
    required this.ok,
    this.error,
    this.amountCents = 0,
    this.feeCents = 0,
    this.arrivalDate,
  });

  /// Stripe's refusals are specific and worth passing through, but a few have
  /// a fix the app knows how to say better than Stripe does.
  String get message => switch (error) {
        null => 'On its way',
        'no_debit_card' =>
          'Add a debit card first — cash out to a card is the only instant one.',
        'over_instant_balance' =>
          'That is more than is available instantly right now.',
        'not_onboarded' => 'Finish setting up payments first.',
        'sender_banned' =>
          'Cashing out is paused on this account while a dispute is open.',
        'card_hold' =>
          'Your card was added recently. As a security measure, instant '
              'payouts wait 7 business days after a card is added — bank '
              'payouts are unaffected.',
        'card_changes_locked' =>
          'Instant payouts are locked: the card on this account changed too '
              'often. The lock lifts once the recent changes are more than '
              '30 days old.',
        'bank_hold' =>
          'Your payout account was changed recently. As a security measure, '
              'payouts wait 7 business days after a change.',
        _ => error!,
      };
}

/// Client for the Stripe Connect payment flow. All secret-key work happens in
/// Supabase Edge Functions; this only calls them (with the user's session) and
/// drives the native payment sheet. The platform never holds funds or card data.
/// One line of the money history: a transfer or a cash-out, from this
/// account's point of view.
class PaymentRecord {
  final String id;
  final bool sent;
  final String otherPhone;
  final int amountCents;
  final int feeCents;
  final String currency;
  final String status;
  final DateTime? at;

  /// What the transfer said it was for. Sparks are recognised by it.
  final String note;

  /// 'transfer' (money between two people) or 'payout' (money leaving for
  /// this account's own bank or card).
  final String kind;

  /// For a payout: 'instant' or 'standard'. Empty on transfers.
  final String method;

  const PaymentRecord({
    required this.id,
    required this.sent,
    required this.otherPhone,
    required this.amountCents,
    required this.feeCents,
    required this.currency,
    required this.status,
    this.at,
    this.note = '',
    this.kind = 'transfer',
    this.method = '',
  });

  /// Whether the money actually moved.
  bool get isComplete => status == 'succeeded' || status == 'paid';

  /// Refused by a card rule rather than failing on its own.
  bool get isBlocked => status.startsWith('blocked_');

  bool get isPending =>
      status == 'pending' || status == 'requires_capture' ||
      status == 'in_transit';

  /// Went nowhere and never will: cancelled outright, failed, or refused by
  /// a card rule. One bucket on purpose — the question a history answers is
  /// "did this money move", and for all three the answer is no, for good.
  bool get isCanceled =>
      status == 'canceled' || status == 'failed' || isBlocked;

  bool get isPayout => kind == 'payout';

  /// A spark rides the same rails as any transfer; the note is what marks it.
  bool get isSpark => kind == 'transfer' && note.startsWith('Spark');

  /// Why it was refused, in words.
  String get blockedReason => switch (status) {
        'blocked_prepaid' => 'Prepaid card',
        'blocked_name_mismatch' => 'Card name did not match',
        'blocked_unknown_card' => 'Card could not be checked',
        _ => 'Blocked',
      };

  factory PaymentRecord.fromJson(Map<String, dynamic> j,
          {String kind = 'transfer'}) =>
      PaymentRecord(
        id: j['id'] as String? ?? '',
        // A payout is always money leaving; a transfer says which way.
        sent: kind == 'payout' || j['direction'] == 'sent',
        otherPhone: j['otherPhone'] as String? ?? '',
        amountCents: (j['amountCents'] as num?)?.toInt() ?? 0,
        feeCents: (j['feeCents'] as num?)?.toInt() ?? 0,
        currency: (j['currency'] as String? ?? 'cad').toUpperCase(),
        status: j['status'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '')?.toLocal(),
        note: j['note'] as String? ?? '',
        kind: kind,
        method: j['method'] as String? ?? '',
      );
}

/// A limit raise that has been asked for and has not started yet.
class PendingLimit {
  final int cents;
  final DateTime at;
  const PendingLimit(this.cents, this.at);

  static PendingLimit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final cents = (raw['cents'] as num?)?.toInt();
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    if (cents == null || at == null) return null;
    return PendingLimit(cents, at.toLocal());
  }
}

/// Who may pay this account, and what it may send.
///
/// Every field here is stored and enforced on the server. Lowering a limit is
/// immediate; raising one waits, and shows up as [pendingDaily] / [pendingMax]
/// beside the number that is still live until it arrives.
class PaymentControls {
  final String acceptsFrom; // 'anyone' | 'nobody'
  final bool paused;
  final int dailySendLimitCents;

  /// The most one transfer may be. 0 means no per-transfer cap.
  final int maxSendCents;
  final PendingLimit? pendingDaily;
  final PendingLimit? pendingMax;
  final List<String> blocked;

  const PaymentControls({
    this.acceptsFrom = 'anyone',
    this.paused = false,
    this.dailySendLimitCents = 50000,
    this.maxSendCents = 0,
    this.pendingDaily,
    this.pendingMax,
    this.blocked = const [],
  });

  bool get acceptsAnyone => acceptsFrom == 'anyone';

  factory PaymentControls.fromJson(Map<String, dynamic> j) => PaymentControls(
        acceptsFrom: j['acceptsFrom'] as String? ?? 'anyone',
        paused: j['paused'] == true,
        dailySendLimitCents:
            (j['dailySendLimitCents'] as num?)?.toInt() ?? 50000,
        maxSendCents: (j['maxSendCents'] as num?)?.toInt() ?? 0,
        pendingDaily: PendingLimit.fromJson(j['pendingDaily']),
        pendingMax: PendingLimit.fromJson(j['pendingMax']),
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

  /// The Stripe account the server's secret key belongs to, or '' when the
  /// deployed function is old enough not to say. The publishable key has to
  /// belong to the same account or nothing authenticates.
  final String platformAccount;
  const ConnectSession({
    required this.clientSecret,
    required this.publishableKey,
    required this.pageUrl,
    this.platformAccount = '',
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

  /// The currency transfers are charged in. The recipient's Stripe account
  /// settles in its own currency either way (Stripe converts), so this is
  /// about the SENDER seeing the number they mean. Persisted.
  final ValueNotifier<String> sendCurrency = ValueNotifier<String>('cad');
  static const _kSendCurrency = 'payments_send_currency_v1';

  /// The currencies the sheet offers, matching the server's whitelist.
  static const List<String> sendCurrencies = [
    'cad',
    'usd',
    'gbp',
    'eur',
    'aud',
  ];

  /// The symbol the amount reads in, per currency.
  static String symbolFor(String code) => switch (code.toLowerCase()) {
        'usd' => 'US\$',
        'gbp' => '£',
        'eur' => '€',
        'aud' => 'A\$',
        _ => '\$',
      };

  Future<void> setSendCurrency(String code) async {
    final c = code.toLowerCase();
    if (!sendCurrencies.contains(c) || sendCurrency.value == c) return;
    sendCurrency.value = c;
    await _prefs?.setString(_kSendCurrency, c);
  }

  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    testMode.value = _prefs!.getBool(_kTestMode) ?? false;
    final c = _prefs!.getString(_kSendCurrency) ?? 'cad';
    sendCurrency.value = sendCurrencies.contains(c) ? c : 'cad';
  }

  /// Whether [phone] can receive money right now — the courtesy question a
  /// sender's app asks BEFORE opening the amount sheet, so "they haven't
  /// set up payments" is said up front. Fail-open: the server re-checks
  /// authoritatively inside payments-create-intent, so an unreachable
  /// probe must never block a payment that would have worked.
  Future<bool> canReceive(String phone) async {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return false;
    try {
      final res = await Supabase.instance.client
          .rpc('can_receive_payments', params: {'p': digits});
      return res != false;
    } catch (_) {
      return true;
    }
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
    // Bounded like connectSession: this is the fallback people reach *because*
    // something already went wrong, so it must not be the thing that hangs.
    final r = await _invoke('payments-onboard')
        .timeout(const Duration(seconds: 25));
    final url = r['url'] as String?;
    // A cast on a null here threw a TypeError, which reached the screen as
    // "Could not start setup: type 'Null' is not a subtype of 'String'" —
    // true, and useless. The function answering without a url means it
    // couldn't make one.
    if (url == null || url.isEmpty) throw PaymentException('no_onboarding_url');
    return url;
  }

  /// Where the embedded onboarding page lives. It ships with the *web* build,
  /// so it only exists wherever that is deployed — hence no default. Nothing
  /// reaches it anyway: [preferHostedOnboarding] sends setup to Stripe's own
  /// hosted flow, and a build that wants the embedded component back has to
  /// say where its copy of the page is served from.
  static const String connectPageUrl = String.fromEnvironment(
    'CONNECT_PAGE_URL',
    defaultValue: '',
  );

  /// Where Stripe's hosted onboarding navigates when it finishes — the
  /// `return_url` payments-onboard sets. Worth knowing client-side because a
  /// WebView hosting the flow has to catch that navigation and come back to
  /// the app rather than render whatever the URL serves. Defaults to the same
  /// `pages` function the server defaults to, so the two agree by themselves.
  static String get returnUrl =>
      _returnOverride.isNotEmpty ? _returnOverride : AppPages.done;

  static const String _returnOverride =
      String.fromEnvironment('APP_RETURN_URL', defaultValue: '');

  /// The caller's money history, newest first: transfers both ways, and the
  /// cash-outs that took the balance to their own bank or card.
  Future<List<PaymentRecord>> history({int limit = 100}) async {
    final r = await _invoke('payments-history', {'limit': limit});
    final records = <PaymentRecord>[
      if (r['transactions'] is List)
        for (final t in (r['transactions'] as List).whereType<Map>())
          PaymentRecord.fromJson(Map<String, dynamic>.from(t)),
      if (r['payouts'] is List)
        for (final p in (r['payouts'] as List).whereType<Map>())
          PaymentRecord.fromJson(Map<String, dynamic>.from(p),
              kind: 'payout'),
    ];
    // One timeline, not two lists: a cash-out happened between transfers and
    // should read in place. Undated rows sink to the bottom.
    records.sort((a, b) {
      if (a.at == null) return 1;
      if (b.at == null) return -1;
      return b.at!.compareTo(a.at!);
    });
    return records;
  }

  /// Reads the account's payment controls. Passing values updates them.
  ///
  /// The server has the last word on all of it — a raised limit may come back
  /// unchanged with a `pending` alongside it, so use what this returns rather
  /// than assuming the request took.
  Future<PaymentControls> controls({
    String? acceptsFrom,
    bool? paused,
    int? dailySendLimitCents,
    int? maxSendCents,
    String? block,
    String? unblock,
  }) async {
    final r = await _invoke('payments-settings', {
      if (acceptsFrom != null) 'acceptsFrom': acceptsFrom,
      if (paused != null) 'paused': paused,
      if (dailySendLimitCents != null)
        'dailySendLimitCents': dailySendLimitCents,
      if (maxSendCents != null) 'maxSendCents': maxSendCents,
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
    // Bounded: the onboarding screen shows a spinner until this settles, and
    // a hung call left it spinning with nothing but the close button.
    final r = await _invoke('payments-account-session')
        .timeout(const Duration(seconds: 25));
    final secret = r['clientSecret'] as String? ?? '';
    if (secret.isEmpty) throw PaymentException('no_client_secret');
    // The function knows its own publishable key; fall back to the one
    // compiled in, so a missing secret there isn't fatal.
    final key = (r['publishableKey'] as String?)?.isNotEmpty == true
        ? r['publishableKey'] as String
        : _publishableKey;
    checkKeyMode(key: key, livemode: r['livemode']);
    return ConnectSession(
      clientSecret: secret,
      publishableKey: key,
      pageUrl: connectPageUrl,
      platformAccount: r['platformAccount'] as String? ?? '',
    );
  }

  /// What Stripe still needs from this account, and whether the app may ask
  /// for it in its own forms.
  Future<ConnectRequirements> connectRequirements({
    Map<String, dynamic>? submit,
    bool replaceAccount = false,
  }) async {
    final r = await _invoke('payments-connect-fields', {
      if (submit != null) 'submit': submit,
      if (replaceAccount) 'replaceAccount': true,
    }).timeout(const Duration(seconds: 40));
    return ConnectRequirements.fromJson(r);
  }

  /// The raw answer from payments-account-session, for the self-test.
  ///
  /// Separate from [connectSession] on purpose: that one throws on a key-mode
  /// mismatch, which is exactly what the self-test is trying to *report*.
  Future<Map<String, dynamic>> connectSessionRaw() =>
      _invoke('payments-account-session')
          .timeout(const Duration(seconds: 25));

  /// Throws when the publishable key the page will use can't authenticate a
  /// session minted by the server's secret key.
  ///
  /// Stripe reports that as "an error occurred while authenticating your
  /// account", which points at the user's account and not at the two keys
  /// being in different modes. Named codes here mean the screen can say which.
  @visibleForTesting
  static void checkKeyMode({required String key, required Object? livemode}) {
    if (key.isEmpty) throw PaymentException('no_publishable_key');
    if (livemode is! bool) return; // older deployment; nothing to compare
    if (key.startsWith('pk_live_') && !livemode) {
      throw PaymentException('key_mode_live_app_test_server');
    }
    if (key.startsWith('pk_test_') && livemode) {
      throw PaymentException('key_mode_test_app_live_server');
    }
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
        // Deliberately smaller than the available balance: instant is its own
        // bucket at Stripe, and a sandbox where the two match would hide the
        // one thing about this screen most likely to confuse somebody.
        instantAvailableCents: 3200,
        country: 'CA',
        hasDebitCard: true,
        cardLast4: '4242',
        cardBrand: 'visa',
      );
    }
    return WalletStatus.fromJson(await _invoke('payments-status'));
  }

  /// Moves [amountCents] to the attached debit card, arriving in minutes.
  ///
  /// Stripe charges the fee to the account cashing out and takes it from the
  /// amount; the platform adds nothing. Never throws — the wallet shows what
  /// came back, and a thrown exception at the end of a money action is the
  /// worst possible way to say "no".
  Future<PayoutOutcome> cashOutInstantly(int amountCents,
      {String? country}) async {
    if (amountCents <= 0) {
      return const PayoutOutcome(ok: false, error: 'invalid amount');
    }
    if (testMode.value) {
      return PayoutOutcome(
        ok: true,
        amountCents: amountCents,
        feeCents: InstantPayoutEconomics.feeCents(amountCents, country),
      );
    }
    try {
      final res = await _invoke('payments-payout', {
        'amountCents': amountCents,
        'method': 'instant',
      });
      return PayoutOutcome(
        ok: res['ok'] == true,
        amountCents: (res['amountCents'] as num?)?.toInt() ?? amountCents,
        feeCents: (res['feeCents'] as num?)?.toInt() ??
            InstantPayoutEconomics.feeCents(amountCents, country),
        arrivalDate: res['arrivalDate'] as String?,
      );
    } on PaymentException catch (e) {
      return PayoutOutcome(ok: false, error: e.code);
    } catch (e) {
      return PayoutOutcome(ok: false, error: e.toString());
    }
  }

  /// Full send flow: create a destination PaymentIntent for [toPhone], then
  /// present the native sheet. Returns true when the payment completes. In
  /// test mode the charge is simulated (brief delay, always succeeds).
  Future<bool> sendMoney({
    String toPhone = '',
    // A public-feed post to spark instead of a phone: the recipient is the
    // post's author, resolved by the server — the author's number is a
    // column no client may read, and a spark must not become the way to
    // learn one.
    String? sparkPostId,
    required int amountCents,
    String? note,
    bool acknowledged = false,
  }) async {
    if (testMode.value) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return true;
    }
    final intent = await _invoke('payments-create-intent', {
      if (toPhone.isNotEmpty) 'toPhone': toPhone,
      if (sparkPostId != null) 'sparkPostId': sparkPostId,
      'amountCents': amountCents,
      'currency': sendCurrency.value,
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
