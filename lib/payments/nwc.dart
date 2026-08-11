import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'bip340.dart';
import 'nip04.dart';
import 'nostr_event.dart';

/// Nostr Wallet Connect (NIP-47) — how this app pays a Lightning invoice
/// through a wallet the USER already owns, without ever holding their money.
///
/// The user pastes a connection string their wallet issued (Alby, Coinos,
/// Zeus, Phoenix, Mutiny). It carries three things: the wallet service's
/// public key, a relay to reach it through, and a secret key minted FOR THIS
/// APP. The app signs a request with that key, encrypts it to the wallet, and
/// the wallet pays. No custody, no cut, no balance held here.
///
/// **What this buys beyond convenience.** The existing Lightning path hands an
/// invoice to whatever wallet the phone has and hears nothing back — which is
/// why sparks have no confirmed state and no tally, stated plainly in
/// `lightning.dart`. NWC returns a RESULT: a preimage on success, a named
/// error otherwise. That is the difference between hoping and knowing.
///
/// **The secret is a spending key, and it is treated as one.** Anyone holding
/// it can spend up to whatever budget the user's wallet attached to it. It
/// belongs in the keychain, never in a log, and never on any wire but the
/// relay it came with.
class NwcConnection {
  /// The wallet service's public key (x-only hex, 64 chars).
  final String walletPubkey;

  /// The relay to reach the wallet through.
  final Uri relay;

  /// The client secret key this app signs and encrypts with.
  final Uint8List secret;

  /// Optional Lightning address the wallet advertised. Cosmetic.
  final String lud16;

  NwcConnection({
    required this.walletPubkey,
    required this.relay,
    required this.secret,
    this.lud16 = '',
  });

  /// This app's own public key on the connection — what the wallet addresses
  /// its replies to.
  String get clientPubkey => _hex(Bip340.publicKey(secret));

  /// Parses `nostr+walletconnect://<pubkey>?relay=<wss url>&secret=<hex>`.
  ///
  /// Strict, because every field becomes either a network destination or a
  /// spending key: the scheme must be exact, the pubkey and secret must be 64
  /// hex characters, and the relay must be a `wss://` host with no
  /// credentials. Returns null rather than throwing — a user pasting the
  /// wrong thing is the expected case, not an exception.
  static NwcConnection? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > 2048) return null;
    Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      return null;
    }
    if (uri.scheme != 'nostr+walletconnect') return null;
    // The wallet pubkey is the authority. Some wallets emit it as the host,
    // others after a '//' with an empty host and a path — accept both rather
    // than refusing a valid string on a formatting detail.
    final pubkey =
        (uri.host.isNotEmpty ? uri.host : uri.path.replaceAll('/', ''))
            .toLowerCase();
    if (!_isHex64(pubkey)) return null;

    final secretHex = (uri.queryParameters['secret'] ?? '').toLowerCase();
    if (!_isHex64(secretHex)) return null;
    // A zero or out-of-range key would throw deep inside the signer later,
    // at a point where the error says nothing useful.
    final secret = _hexToBytes(secretHex);
    try {
      Bip340.publicKey(secret);
    } catch (_) {
      return null;
    }

    final relayRaw = uri.queryParameters['relay'] ?? '';
    if (relayRaw.isEmpty) return null;
    Uri relay;
    try {
      relay = Uri.parse(relayRaw);
    } catch (_) {
      return null;
    }
    // wss only: the connection secret authorises spending, so a ws:// relay
    // would put it on the wire in the clear for anyone on the path.
    if (relay.scheme != 'wss' ||
        relay.host.isEmpty ||
        relay.userInfo.isNotEmpty) {
      return null;
    }

    return NwcConnection(
      walletPubkey: pubkey,
      relay: relay,
      secret: secret,
      lud16: uri.queryParameters['lud16'] ?? '',
    );
  }

  /// The shared key this connection encrypts with, cached because deriving it
  /// is a point multiplication and every request needs it.
  Uint8List? _shared;
  Uint8List get sharedKey =>
      _shared ??= Nip04.sharedSecret(secret, walletPubkey);

  /// Builds the signed, encrypted `pay_invoice` request event (kind 23194).
  ///
  /// [amountMsats] is optional and only meaningful for a zero-amount invoice;
  /// sending it alongside an invoice that already names an amount is how a
  /// wallet ends up refusing the whole request.
  NostrEvent payInvoiceRequest(String invoice,
      {int? amountMsats, required int createdAt, Uint8List? auxRand}) {
    final params = <String, dynamic>{'invoice': invoice};
    if (amountMsats != null && amountMsats > 0) params['amount'] = amountMsats;
    final body = jsonEncode({'method': 'pay_invoice', 'params': params});
    return NostrEvent.sign(
      privateKey: secret,
      kind: kindRequest,
      tags: [
        ['p', walletPubkey]
      ],
      content: Nip04.encrypt(sharedKey, body),
      createdAt: createdAt,
      auxRand: auxRand ?? randomBytes(32),
    );
  }

  /// Reads a wallet's reply event (kind 23195) into a result.
  ///
  /// Returns null when the event is not a reply to [requestId] from this
  /// wallet — the subscription can deliver other traffic, and acting on
  /// somebody else's event is how a payment gets reported against the wrong
  /// request.
  NwcResult? readResponse(NostrEvent event, String requestId) {
    if (event.kind != kindResponse) return null;
    if (event.pubkey.toLowerCase() != walletPubkey) return null;
    if (event.tag('e') != requestId) return null;
    final plain = Nip04.decrypt(sharedKey, event.content);
    if (plain == null) return const NwcResult.failed('unreadable reply');
    return NwcResult.parse(plain);
  }

  /// Request and response kinds, per NIP-47.
  static const int kindRequest = 23194;
  static const int kindResponse = 23195;
  static const int kindInfo = 13194;

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  static Uint8List _hexToBytes(String s) => Uint8List.fromList([
        for (var i = 0; i + 1 < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static final Random _rng = Random.secure();

  @visibleForTesting
  static Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// Redacted on purpose: the secret is a spending key and this object ends up
  /// in error strings and logs.
  @override
  String toString() => 'NwcConnection(${relay.host}, wallet '
      '${walletPubkey.substring(0, 8)}…, secret hidden)';
}

/// What a wallet said about a payment.
class NwcResult {
  /// The payment preimage — proof the invoice was actually paid.
  final String preimage;

  /// A human-readable failure, or '' on success.
  final String error;

  const NwcResult({required this.preimage, required this.error});

  const NwcResult.failed(this.error) : preimage = '';

  bool get ok => error.isEmpty && preimage.isNotEmpty;

  /// Parses NIP-47's response body.
  ///
  /// A wallet that answers with neither an error nor a preimage is treated as
  /// a FAILURE, not a success: this result is what decides whether the app
  /// tells somebody their tip went through, and "the wallet said nothing
  /// useful" is not a payment.
  static NwcResult parse(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const NwcResult.failed('unreadable reply');
    }
    if (decoded is! Map) return const NwcResult.failed('unreadable reply');
    final err = decoded['error'];
    if (err is Map) {
      final message = err['message'];
      final code = err['code'];
      return NwcResult.failed(
          message is String && message.trim().isNotEmpty
              ? message.trim()
              : (code is String && code.isNotEmpty ? code : 'payment refused'));
    }
    final result = decoded['result'];
    if (result is Map && result['preimage'] is String) {
      final p = (result['preimage'] as String).trim();
      if (p.isNotEmpty) return NwcResult(preimage: p, error: '');
    }
    return const NwcResult.failed('the wallet did not confirm the payment');
  }
}
