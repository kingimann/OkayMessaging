/// Lightning sparks: paying a creator in bitcoin over the Lightning Network,
/// the way a Nostr "zap" works.
///
/// **What this deliberately is NOT.** The app never holds bitcoin, never
/// custodies a balance, never routes a payment and never takes a cut. It
/// resolves the creator's own Lightning Address into an invoice their wallet
/// issued, and hands that invoice to whatever Lightning wallet the sender has
/// installed. Two independent reasons, and both matter:
///
/// - **App Review.** Apple made Damus strip zaps off posts and allow them only
///   on profiles, because tipping content inside an app reads as a digital
///   purchase that owes Apple its cut. A profile-level tip that leaves the app
///   to an external wallet is the shape Apple actually permitted. That is why
///   there is no post-level spark here and no in-app payment step.
/// - **Custody.** Holding somebody else's bitcoin is a regulated business and
///   a liability. Address in, invoice out, wallet takes it from there.
///
/// The protocol is LNURL-pay (LUD-06) reached through a Lightning Address
/// (LUD-16) — `name@domain` resolves to
/// `https://domain/.well-known/lnurlp/name`, which answers a callback URL and
/// the amount bounds; asking that callback for an amount answers a BOLT11
/// invoice. Exactly what a Nostr client does.
///
/// **The honest limit, stated here and in the UI.** Handing an invoice to
/// another app is the end of what this can observe. No wallet reports back, so
/// the app CANNOT know whether a spark was actually paid — there is no
/// counter, no receipt and no "sparked" state for Lightning. Nostr gets that
/// from zap receipts published to a relay by the recipient's server; there is
/// no equivalent here, and inventing a count the app cannot verify would be a
/// number made up on screen.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A creator's Lightning Address, e.g. `alice@getalby.com`.
///
/// Deliberately parsed rather than trusted: this string arrives over the
/// profile share from another device, and it is about to become a URL.
class LightningAddress {
  final String name;
  final String domain;

  const LightningAddress(this.name, this.domain);

  @override
  String toString() => '$name@$domain';

  /// Parses `name@domain`, or returns null when it is not one.
  ///
  /// Kept strict on purpose. A permissive parse here builds a request URL out
  /// of somebody else's text, so anything with a path, a scheme, whitespace,
  /// or a domain without a dot is refused rather than cleaned up.
  static LightningAddress? parse(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty || s.length > 128) return null;
    if (s.contains(RegExp(r'[\s/\\?#%]'))) return null;
    final at = s.indexOf('@');
    if (at <= 0 || at != s.lastIndexOf('@')) return null;
    final name = s.substring(0, at);
    final domain = s.substring(at + 1);
    if (name.isEmpty || domain.isEmpty) return null;
    // The local part is what goes into the path; keep it to characters that
    // need no escaping.
    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(name)) return null;
    // A real host, with a dot and no leading/trailing separator.
    if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
        .hasMatch(domain)) {
      return null;
    }
    return LightningAddress(name, domain);
  }

  /// Whether [raw] is a usable address — what the profile editor validates on.
  static bool isValid(String raw) => parse(raw) != null;

  /// The LUD-16 well-known endpoint. Always https: an invoice fetched over
  /// plaintext could be swapped for the attacker's own.
  Uri get lnurlpUri =>
      Uri.parse('https://$domain/.well-known/lnurlp/$name');
}

/// What the creator's LNURL server said it will accept.
class LnurlPayParams {
  /// Where to ask for an invoice.
  final Uri callback;

  /// The bounds the server set, in SATS (the protocol speaks millisats; this
  /// is already divided, because nothing above this layer thinks in millisats).
  final int minSats;
  final int maxSats;

  /// Whether the server accepts a note to the payee (LUD-12).
  final int commentAllowed;

  const LnurlPayParams({
    required this.callback,
    required this.minSats,
    required this.maxSats,
    this.commentAllowed = 0,
  });

  bool allows(int sats) => sats >= minSats && sats <= maxSats;

  /// Reads the LUD-06 response body. Pure, so the shape can be tested without
  /// a network.
  ///
  /// Returns null for anything that is not a usable payRequest — including a
  /// server that answered `{"status":"ERROR"}`, which is a normal reply rather
  /// than an exception and must not be read as success.
  static LnurlPayParams? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      if ((j['status'] as String?)?.toUpperCase() == 'ERROR') return null;
      if ((j['tag'] as String?) != 'payRequest') return null;
      final callback = (j['callback'] as String?) ?? '';
      final uri = Uri.tryParse(callback);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
      final minMsat = (j['minSendable'] as num?)?.toInt() ?? 0;
      final maxMsat = (j['maxSendable'] as num?)?.toInt() ?? 0;
      if (minMsat <= 0 || maxMsat < minMsat) return null;
      return LnurlPayParams(
        callback: uri,
        // Round the floor UP and the ceiling DOWN, so every value this
        // reports is one the server would really accept.
        minSats: (minMsat + 999) ~/ 1000,
        maxSats: maxMsat ~/ 1000,
        commentAllowed: (j['commentAllowed'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Resolves addresses to invoices. Network only — it names no chat, relay or
/// crypto of the app's own, and a test pins that.
abstract class Lightning {
  /// The amounts the spark sheet offers, in sats. Zap-sized on purpose: a
  /// spark is a tip, not a transfer.
  static const List<int> presetSats = [21, 100, 500, 1000, 5000, 21000];

  static const Duration _timeout = Duration(seconds: 12);

  /// Step one: ask the creator's server what it accepts.
  static Future<LnurlPayParams?> resolve(LightningAddress address,
      {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(address.lnurlpUri).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return LnurlPayParams.parse(res.body);
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Reads the invoice out of a LUD-06 callback response.
  ///
  /// Separated from the request so the parsing is testable. A BOLT11 invoice
  /// on mainnet starts `lnbc`; anything else is refused rather than handed to
  /// a wallet, which is the last point at which a swapped or malformed
  /// invoice can be caught.
  static String? parseInvoice(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      if ((j['status'] as String?)?.toUpperCase() == 'ERROR') return null;
      final pr = (j['pr'] as String?)?.trim().toLowerCase() ?? '';
      if (!pr.startsWith('lnbc') || pr.length < 20) return null;
      return pr;
    } catch (_) {
      return null;
    }
  }

  /// Step two: ask for an invoice for [sats].
  static Future<String?> invoice(LnurlPayParams params, int sats,
      {String comment = '', http.Client? client}) async {
    if (!params.allows(sats)) return null;
    final query = <String, String>{
      ...params.callback.queryParameters,
      'amount': '${sats * 1000}',
      if (comment.isNotEmpty && params.commentAllowed > 0)
        'comment': comment.substring(
            0, comment.length.clamp(0, params.commentAllowed)),
    };
    final uri = params.callback.replace(queryParameters: query);
    final c = client ?? http.Client();
    try {
      final res = await c.get(uri).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return parseInvoice(res.body);
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// The URI handed to the sender's own wallet app. The `lightning:` scheme is
  /// the one every iOS wallet registers.
  static Uri walletUri(String invoice) => Uri.parse('lightning:$invoice');
}
