import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Elliptic-curve (P-256) key agreement for stronger end-to-end encryption.
///
/// Each device holds a long-lived identity key pair. When two devices have
/// exchanged public keys (over the relay), each derives an identical shared
/// secret via ECDH — the relay only ever sees public keys, never the shared
/// secret or the private keys. That secret keys the AES-256-GCM message
/// cipher, so message keys come from a real Diffie–Hellman handshake rather
/// than from the (guessable) phone numbers.
///
/// The pure crypto here is unit-tested with two key pairs in-process; the
/// public-key exchange is wired through the relay.
class SecureKeyExchange {
  SecureKeyExchange._();
  static final SecureKeyExchange instance = SecureKeyExchange._();

  static final ECDomainParameters _domain = ECDomainParameters('secp256r1');

  static const _kPriv = 'device_ec_priv_v1';
  static const _kPeers = 'peer_pub_keys_v1';

  ECPrivateKey? _priv;
  ECPublicKey? _pub;
  String? _publicKeyB64;

  SharedPreferences? _prefs;
  final Map<String, String> _peerKeys = {}; // phone digits -> base64 pubkey

  bool get isReady => _priv != null;

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Loads (or creates and persists) this device's identity key pair plus any
  /// cached peer public keys. Safe to call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    ensureKeys(restorePrivateHex: prefs.getString(_kPriv));
    if (prefs.getString(_kPriv) == null) {
      await prefs.setString(_kPriv, exportPrivate());
    }
    final raw = prefs.getString(_kPeers);
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          _peerKeys[k] = v as String;
        });
      } catch (_) {}
    }
  }

  /// The cached public key for [phone], or null if we haven't received it yet.
  String? peerKey(String phone) => _peerKeys[_digits(phone)];

  /// Remembers a peer's public key (from a relay handshake). Returns true when
  /// it was new or changed.
  bool rememberPeer(String phone, String publicKeyB64) {
    final key = _digits(phone);
    if (_peerKeys[key] == publicKeyB64) return false;
    _peerKeys[key] = publicKeyB64;
    _prefs?.setString(_kPeers, jsonEncode(_peerKeys));
    return true;
  }

  /// This device's public key, base64 of the uncompressed EC point. Null until
  /// [ensureKeys] has run.
  String? get myPublicKey => _publicKeyB64;

  /// Generates a fresh key pair if one hasn't been loaded/restored yet. Pass a
  /// previously [exportPrivate]-ed seed to restore a persisted identity.
  void ensureKeys({String? restorePrivateHex}) {
    if (_priv != null) return;
    if (restorePrivateHex != null && restorePrivateHex.isNotEmpty) {
      final d = BigInt.parse(restorePrivateHex, radix: 16);
      _priv = ECPrivateKey(d, _domain);
      _pub = ECPublicKey(_domain.G * d, _domain);
    } else {
      final gen = ECKeyGenerator()
        ..init(ParametersWithRandom(
            ECKeyGeneratorParameters(_domain), _secureRandom()));
      final pair = gen.generateKeyPair();
      _priv = pair.privateKey;
      _pub = pair.publicKey;
    }
    _publicKeyB64 = base64.encode(_pub!.Q!.getEncoded(false));
  }

  /// The private scalar as hex, for persisting the identity on the device.
  String exportPrivate() => _priv!.d!.toRadixString(16);

  /// Derives the 32-byte shared secret with a peer's base64 public key, or
  /// null if the key is malformed or our keys aren't ready.
  List<int>? sharedSecretWith(String peerPublicKeyB64) {
    if (_priv == null) return null;
    try {
      final point = _domain.curve.decodePoint(base64.decode(peerPublicKeyB64));
      if (point == null) return null;
      final agreement = ECDHBasicAgreement()..init(_priv!);
      final shared = agreement.calculateAgreement(ECPublicKey(point, _domain));
      return _fixed32(shared);
    } catch (_) {
      return null;
    }
  }

  /// Left-pads / trims a BigInt to exactly 32 bytes (the P-256 field size).
  static List<int> _fixed32(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    var bytes = <int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    if (bytes.length > 32) bytes = bytes.sublist(bytes.length - 32);
    if (bytes.length < 32) {
      bytes = [...List.filled(32 - bytes.length, 0), ...bytes];
    }
    return bytes;
  }

  static SecureRandom _secureRandom() {
    final rnd = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    return FortunaRandom()..seed(KeyParameter(seed));
  }

  /// Forgets the in-memory keys (tests).
  void resetForTest() {
    _priv = null;
    _pub = null;
    _publicKeyB64 = null;
    _peerKeys.clear();
  }
}
