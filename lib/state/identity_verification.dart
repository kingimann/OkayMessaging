import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';

/// Where an account stands with the ID check behind the blue check.
enum IdentityStatus {
  /// Never started one.
  none,

  /// Stripe is still working through the documents.
  processing,

  /// Stripe needs something else — a clearer photo, a different document.
  requiresInput,

  /// Passed. This is the only status that earns the badge.
  verified,

  /// Abandoned or cancelled.
  canceled,
}

IdentityStatus _statusFrom(String? raw) => switch (raw) {
      'verified' => IdentityStatus.verified,
      'processing' => IdentityStatus.processing,
      'requires_input' => IdentityStatus.requiresInput,
      'canceled' => IdentityStatus.canceled,
      _ => IdentityStatus.none,
    };

/// A started ID check: the secret drives the in-app flow, the hosted URL is
/// the fallback for anywhere a WebView can't run.
class IdentitySession {
  final String clientSecret;
  final String hostedUrl;
  final String publishableKey;
  const IdentitySession({
    required this.clientSecret,
    required this.hostedUrl,
    required this.publishableKey,
  });

  /// Nothing to do — the account already passed.
  const IdentitySession.alreadyVerified()
      : clientSecret = '',
        hostedUrl = '',
        publishableKey = '';

  bool get isAlreadyVerified => clientSecret.isEmpty && hostedUrl.isEmpty;
}

/// Drives the government-ID check that earns the blue check.
///
/// The badge used to be a free local toggle, which made it a decoration rather
/// than a claim about who someone is. It now comes from the server and only
/// the server: the device asks what Stripe concluded and displays that. A
/// badge a device could grant itself would be worth nothing, so nothing here
/// ever *sets* verified — it only reads it.
///
/// No document ever reaches this app. The check happens in Stripe's hosted
/// flow; the app opens a URL and later asks how it went.
class IdentityVerification extends ChangeNotifier {
  IdentityVerification._();
  static final IdentityVerification instance = IdentityVerification._();

  IdentityStatus _status = IdentityStatus.none;
  IdentityStatus get status => _status;

  bool get isVerified => _status == IdentityStatus.verified;

  /// True while Stripe is still deciding — worth telling the user rather than
  /// showing "not verified" at someone who just finished the flow.
  bool get isPending => _status == IdentityStatus.processing;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Re-reads the verdict. Called at startup and when returning from Stripe.
  Future<IdentityStatus> refresh() async {
    final result = await _invoke('identity-status', const {});
    if (result == null) return _status;
    _apply(_statusFrom(result['status'] as String?));
    return _status;
  }

  /// Everything needed to run the check inside the app.
  Future<IdentitySession?> start() async {
    final result = await _invoke('identity-start', const {});
    if (result == null) return null;
    if (result['alreadyVerified'] == true) {
      _apply(IdentityStatus.verified);
      return const IdentitySession.alreadyVerified();
    }
    final secret = result['clientSecret'] as String? ?? '';
    final url = result['url'] as String? ?? '';
    if (secret.isEmpty && url.isEmpty) return null;
    // The session exists but nothing is decided yet.
    _apply(IdentityStatus.processing);
    return IdentitySession(
      clientSecret: secret,
      hostedUrl: url,
      publishableKey: result['publishableKey'] as String? ?? '',
    );
  }

  /// Where the in-app verification page lives. It ships with the web build.
  static const String pageUrl = String.fromEnvironment(
    'IDENTITY_PAGE_URL',
    defaultValue: 'https://kingimann.github.io/OkayMessaging/identity.html',
  );

  /// Where Stripe's own hosted flow navigates when it is done — the
  /// `return_url` the identity-start function sets (APP_RETURN_URL, which
  /// defaults to the site root). Hosting that flow in the app's WebView means
  /// watching for this navigation, because a hosted flow reports completion by
  /// going somewhere rather than by posting a message.
  static const String returnUrl = String.fromEnvironment(
    'APP_RETURN_URL',
    defaultValue: 'https://kingimann.github.io/OkayMessaging/',
  );

  void _apply(IdentityStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _invoke(
      String name, Map<String, dynamic> body) async {
    final client = _client;
    if (client == null) return null;
    try {
      final res = await client.functions.invoke(name, body: body);
      if (res.status >= 400) return null;
      final data = res.data;
      if (data is! Map) return null;
      return Map<String, dynamic>.from(data);
    } catch (_) {
      // Offline, or the functions aren't deployed. Never throw into a UI.
      return null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _status = IdentityStatus.none;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetStatus(IdentityStatus status) => _apply(status);
}
