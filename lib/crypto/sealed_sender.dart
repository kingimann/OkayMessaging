import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'e2e.dart';
import 'key_exchange.dart';

/// Sealed sender: the envelope stops saying who it is from.
///
/// Delivery needs the server to know who a message is FOR — it does not
/// need to know who it is FROM, and until now every envelope said so in
/// the clear because that is how the recipient picked its decryption keys.
/// This wraps the ENTIRE legacy payload (sender name and all) in one more
/// layer, sealed so that only the recipient's identity key can open it:
///
///   eph        = fresh P-256 key pair, used once and forgotten
///   secret     = SHA256("okaymsg-sealed-v1" || ECDH(eph.priv, recipientPub))
///   envelope   = { v: 1, epk: base64(eph.pub), sc: AES-GCM(secret, payload) }
///
/// The recipient computes ECDH(identityPriv, epk) — needing to know nothing
/// about the sender to do it — opens the layer, and finds the ordinary
/// legacy payload inside, which then walks the exact code path it always
/// walked. The server's view of such a message drops from "A wrote to B at
/// 2:14" to "someone wrote to B at 2:14".
///
/// Honest limits, stated where the code lives:
///  * Only possible once we HOLD the recipient's identity key, and only
///    sent once the peer has advertised (via the `sv` flag on a legacy
///    message) that their build can open it — an old build receiving a
///    sealed envelope would lose the message, which is worse than metadata.
///  * An envelope that fails to open is anonymous BY DESIGN — there is
///    nobody to ask for a resend. The legacy sealed-to-old-key repair path
///    only exists for unsealed traffic.
///  * The host still sees IPs and timing, and the recipient is still
///    addressed. This narrows the mailbox row, not the network layer.
class SealedSender {
  SealedSender._();

  static final ECDomainParameters _domain = ECDomainParameters('secp256r1');
  static const String _context = 'okaymsg-sealed-v1';

  /// The wire marker: an envelope with this version key is sealed.
  static const String versionKey = 'v';
  static const String ephemeralKey = 'epk';
  static const String cipherKey = 'sc';

  static Uint8List _contextualSecret(List<int> rawSecret) =>
      Uint8List.fromList(
          sha256.convert([...utf8.encode(_context), ...rawSecret]).bytes);

  /// Seals [inner] (any JSON-encodable map — ours is `{e: event, p:
  /// payload}`) to [recipientPubB64]. Null when the key is malformed, which
  /// callers treat as "send legacy".
  static Map<String, dynamic>? seal(
      String recipientPubB64, Map<String, dynamic> inner) {
    try {
      final point =
          _domain.curve.decodePoint(base64.decode(recipientPubB64));
      if (point == null) return null;
      final gen = ECKeyGenerator()
        ..init(ParametersWithRandom(
            ECKeyGeneratorParameters(_domain), _secureRandom()));
      final eph = gen.generateKeyPair();
      final agreement = ECDHBasicAgreement()..init(eph.privateKey);
      final raw = SecureKeyExchange.fixed32(
          agreement.calculateAgreement(ECPublicKey(point, _domain)));
      final secret = _contextualSecret(raw);
      final ephPub = eph.publicKey;
      return {
        versionKey: 1,
        ephemeralKey: base64.encode(ephPub.Q!.getEncoded(false)),
        cipherKey: E2eCrypto.encrypt(secret, jsonEncode(inner)),
      };
    } catch (_) {
      return null;
    }
  }

  /// Opens a sealed [envelope] with this device's identity key. Null when
  /// it is not ours, tampered, or malformed — an unopenable envelope is
  /// anonymous by design and there is nothing further to do with it.
  static Map<String, dynamic>? unseal(Map<String, dynamic> envelope,
      {SecureKeyExchange? kx}) {
    final exchange = kx ?? SecureKeyExchange.instance;
    final epk = envelope[ephemeralKey];
    final sc = envelope[cipherKey];
    if (epk is! String || sc is! String) return null;
    final raw = exchange.sharedSecretWith(epk);
    if (raw == null) return null;
    final json = E2eCrypto.decrypt(_contextualSecret(raw), sc);
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Whether [payload] is a sealed envelope rather than a legacy one.
  static bool isSealed(Map<String, dynamic> payload) =>
      payload[versionKey] == 1 &&
      payload[ephemeralKey] is String &&
      payload[cipherKey] is String;

  static SecureRandom _secureRandom() {
    final rnd = Random.secure();
    final seed =
        Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    return FortunaRandom()..seed(KeyParameter(seed));
  }
}
