import 'package:flutter/foundation.dart';

import 'relay_config.dart';

/// The few web pages the app has to name a URL for, served by the `pages`
/// Edge Function on the project the app already talks to.
///
/// WHY NOT A STATIC SITE. These were files on GitHub Pages, and that site
/// republishes the repository's README over the app for minutes after every
/// push — so a link opened in the wrong minute landed on "File not found".
/// One of them is a confirmation link read in Safari on somebody else's
/// device, where the app cannot intervene at all. Deriving them from
/// [RelayConfig.supabaseUrl] means there is no second system to be down: if
/// the app can reach its backend, these are up, and a build pointed at a
/// different project gets that project's pages without a second flag.
///
/// Set `--dart-define=SITE_URL=https://example.com` to serve them from
/// somewhere else — a real domain, once there is one. The paths are appended
/// to it unchanged, so whatever answers has to answer `/done` and
/// `/email-confirmed` too.
class AppPages {
  AppPages._();

  static const String _override =
      String.fromEnvironment('SITE_URL', defaultValue: '');

  /// The root the rest hang off, or '' in a build with no backend and no
  /// override — which is every test binary. Empty is a valid answer here and
  /// callers must treat it as "there is no such page" rather than as a URL:
  /// an empty completion prefix already means "never matches", and the share
  /// text drops the link rather than trailing off after a colon.
  /// Stands in for the build-time configuration. A test binary carries no
  /// --dart-define, so without this every getter here is the empty case and
  /// the interesting half of each caller is unreachable.
  @visibleForTesting
  static String? debugBaseOverride;

  static String get base =>
      debugBaseOverride ?? baseFor(RelayConfig.supabaseUrl, _override);

  /// Pure, so the interesting cases are reachable from a test — a test binary
  /// carries no --dart-define, which makes every one of them the empty case.
  static String baseFor(String supabaseUrl, String override) {
    if (override.isNotEmpty) return _stripSlash(override);
    return supabaseUrl.isEmpty
        ? ''
        : '${_stripSlash(supabaseUrl)}/functions/v1/pages';
  }

  /// [leaf] appended to [base], or '' when there is no base to append to.
  static String subFor(String base, String leaf) =>
      base.isEmpty ? '' : '$base/$leaf';

  /// What this app is — the target of an invite or a shared profile.
  static String get home => base;

  /// Where Stripe's hosted flows navigate when they finish. Inside the app
  /// that navigation is caught and cancelled before it renders; this exists so
  /// that catching it has something unambiguous to match on, and so that
  /// anyone who does get there in a browser is told something true.
  static String get done => _sub('done');

  /// Where a confirmation link from a sign-up email lands.
  static String get emailConfirmed => _sub('email-confirmed');

  static String _sub(String leaf) => subFor(base, leaf);

  static String _stripSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
