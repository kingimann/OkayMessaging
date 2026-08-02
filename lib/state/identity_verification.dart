import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/app_pages.dart';
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

/// Whether the ID check runs on Stripe's own page rather than on one of ours.
///
/// It does, and the reason is that ours was never worth what it cost. The only
/// thing `web/identity.html` adds is the app's colours around a modal Stripe
/// opens itself — and to get that, the check had to fetch a static file from
/// GitHub Pages, which republishes the repository's README over the app for
/// minutes after every push (docs/server_deploy_checklist.md §3b). Somebody
/// tapping "Get verified" in that window got GitHub's "File not found" page
/// under the words "Verify your identity" and no way forward.
///
/// Stripe's hosted flow has no such window. It is the same check, run by the
/// same company on their own servers, and it loads in this app's own WebView
/// on this app's own screen — no browser, no handoff, no page of ours in the
/// path at all. Losing the theming is the whole price.
///
/// Same decision, and the same reasoning, as [preferHostedOnboarding] in
/// connect_onboarding_screen.dart.
///
/// Flip it with --dart-define=PREFER_EMBEDDED_IDENTITY=true; that path still
/// works and still checks whether the page is really being served first.
const bool preferHostedIdentity = !bool.fromEnvironment(
  'PREFER_EMBEDDED_IDENTITY',
  defaultValue: false,
);

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

  static const _key = 'identity_status_v1';

  bool get isVerified => _status == IdentityStatus.verified;

  /// Whether the parts of the app that involve money or strangers are open to
  /// this account: the marketplace, the wallet, and handing things to people
  /// nearby.
  ///
  /// A BUILD WITH NO SERVER CANNOT VERIFY ANYBODY — identity-start is an Edge
  /// Function — so gating there would lock a door with no key: the web
  /// preview and the test builds would simply lose three features with no way
  /// to earn them back. The gate applies where verification is possible.
  bool get allowsTrusted =>
      !(debugGateOverride ?? RelayConfig.isEnabled) || isVerified;

  /// Test hook: stands in for [RelayConfig.isEnabled], which is a
  /// compile-time define and therefore cannot be varied inside a test — so
  /// without this the gated branch is the one branch no test can reach, on a
  /// suite that runs entirely with the relay off.
  @visibleForTesting
  static bool? debugGateOverride;

  /// Reads the last known verdict off this device.
  ///
  /// KEPT LOCALLY ON PURPOSE. The verdict lives on the server, and asking for
  /// it needs a network — but "send this to the person next to you" is the
  /// one feature whose whole point is working without one. Launched on a
  /// plane, an account that verified last week would otherwise read as
  /// unverified and lose the feature exactly when it is wanted.
  ///
  /// The server is still the authority: [refresh] overwrites this the moment
  /// it can reach one, including downgrading a verdict that was withdrawn.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apply(_statusFrom(prefs.getString(_key)));
    } catch (_) {
      // No prefs (tests) — the server answer stands on its own.
    }
  }

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
      clientSecret: secretFor(
        secret: secret,
        hostedUrl: url,
        preferHosted: preferHostedIdentity,
        // Not asked on the default path, so our own page is never even
        // fetched. Only an opt-in build with something to fall back to pays
        // for the round trip.
        pageServed: preferHostedIdentity || url.isEmpty
            ? false
            : await pageIsServed(),
      ),
      hostedUrl: url,
      publishableKey: result['publishableKey'] as String? ?? '',
    );
  }

  /// The client secret to keep, which is what decides where the check runs.
  ///
  /// A secret means the screen loads [pageUrl] and runs Stripe.js on it; no
  /// secret means it loads Stripe's own hosted flow, in the same WebView, on
  /// the same screen. So dropping it is how the app steps away from a page of
  /// its own — and it is only ever dropped when there is a hosted flow to
  /// drop to, because no check at all is worse than an unthemed one.
  @visibleForTesting
  static String secretFor({
    required String secret,
    required String hostedUrl,
    required bool pageServed,
    required bool preferHosted,
  }) {
    if (hostedUrl.isEmpty) return secret;
    if (preferHosted) return '';
    return pageServed ? secret : '';
  }

  @visibleForTesting
  static Future<bool> Function(String url)? debugPageProbe;

  /// Whether [pageUrl] is actually being served right now.
  ///
  /// It ships with the web build, and that build is published by a GitHub
  /// Actions run taking minutes — while GitHub's own branch build republishes
  /// the repository's README over the top of it in seconds. Every push leaves
  /// a window where the site is the README and every file the app expects on
  /// it is a 404, and a check started inside that window showed GitHub's
  /// "File not found" page under the words "Verify your identity", with
  /// nowhere to go from there.
  ///
  /// Stripe's hosted flow is on Stripe's servers and has no such window, so
  /// the honest thing to do is ask before choosing. Failing closed — treating
  /// an unanswered probe as "not served" — costs only the app's theming, and
  /// the hosted page runs in the same WebView.
  static Future<bool> pageIsServed() async {
    final probe = debugPageProbe;
    if (probe != null) return probe(pageUrl);
    try {
      final res = await http
          .head(Uri.parse(pageUrl))
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Where the embedded verification page lives. It ships with the *web*
  /// build, so it can only exist wherever that is deployed — which is why
  /// there is no default: a build that wants the embedded flow has to say
  /// where its own copy is served from. Empty means the page is unavailable,
  /// which [pageIsServed] reports and [secretFor] turns into the hosted flow.
  static const String pageUrl = String.fromEnvironment(
    'IDENTITY_PAGE_URL',
    defaultValue: '',
  );

  /// Where Stripe's own hosted flow navigates when it is done — the
  /// `return_url` the identity-start function sets. Hosting that flow in the
  /// app's WebView means watching for this navigation, because a hosted flow
  /// reports completion by going somewhere rather than by posting a message.
  ///
  /// The navigation is cancelled before it renders, so what this serves barely
  /// matters — but it has to be the same URL the server sets, or the match
  /// fails and the WebView leaves the app. Both sides default to the `pages`
  /// function on the same Supabase project, so they agree without being told.
  static String get returnUrl => _returnOverride.isNotEmpty
      ? _returnOverride
      : AppPages.done;

  static const String _returnOverride =
      String.fromEnvironment('APP_RETURN_URL', defaultValue: '');

  void _apply(IdentityStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((p) => p.setString(_key, next.name))
        .catchError((_) => false);
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
    debugGateOverride = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetStatus(IdentityStatus status) => _apply(status);
}
