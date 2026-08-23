import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:math';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../state/secure_store.dart';

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

  /// Why the last [load] could not reach the identity key, or null. Kept
  /// rather than swallowed: an app that is running with no identity looks
  /// exactly like one that is fine until somebody tries to send.
  String? lastLoadError;

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Loads (or creates and persists) this device's identity key pair plus any
  /// cached peer public keys. Safe to call once at startup.
  ///
  /// The PRIVATE key reads from the keychain — a copy that predates it is
  /// migrated in and deleted from SharedPreferences, so the next device
  /// backup no longer carries the one secret everything else hangs off.
  /// Peer PUBLIC keys stay in prefs; they are public.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    String? priv;
    try {
      priv = await SecureStore.instance
          .readMigrating('device_ec_priv', _kPriv);
    } on SecureUnavailable catch (e) {
      // THE KEYCHAIN REFUSED, WHICH IS NOT THE SAME AS THERE BEING NO KEY.
      //
      // Minting one here is what produced "Misty Breeze's security code
      // changed" over and over on a real phone, and "sealed to a key this
      // device no longer has" beside it: the store answered null for a
      // refusal, this read that as a first run, and a brand-new identity
      // replaced one that was sitting in the keychain the whole time.
      //
      // It is an ordinary event, not an exotic one — the item is stored
      // `first_unlock`, so it is genuinely unreadable until the phone has
      // been unlocked once since boot, and a push can wake this app before
      // that.
      //
      // So: leave [isReady] false and change NOTHING. Every caller already
      // does `if (!kx.isReady) await kx.load()`, so this retries by itself
      // once the phone is unlocked, and the identity survives.
      lastLoadError = '$e';
      return;
    }
    lastLoadError = null;
    ensureKeys(restorePrivateHex: priv);
    if (priv == null) {
      // A genuine first run. If the keychain refuses this WRITE the key is
      // not persisted, so nothing is claimed that cannot be kept: the next
      // launch tries again rather than inheriting a key it cannot store.
      try {
        await SecureStore.instance.write('device_ec_priv', exportPrivate());
      } on SecureUnavailable catch (e) {
        lastLoadError = '$e';
        _priv = null;
        _pub = null;
        _publicKeyB64 = null;
        return;
      }
    }
    final raw = prefs.getString(_kPeers);
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          _peerKeys[k] = v as String;
        });
      } catch (_) {}
    }
    _sealedPeers
      ..clear()
      ..addAll(prefs.getStringList(_kSealedPeers) ?? const []);
  }

  /// The cached public key for [phone], or null if we haven't received it yet.
  String? peerKey(String phone) => _peerKeys[_digits(phone)];

  /// Fired when a peer's key CHANGES — not on first learn, which is every
  /// new contact introducing themselves. Wired to the chat store so the
  /// conversation says so out loud: a changed key is usually a reinstall or
  /// a new phone, and once in a while it is the one event a safety-number
  /// comparison exists to catch. Signal posts this notice; so do we.
  void Function(String digits)? onPeerKeyChanged;

  /// Remembers a peer's public key (from a relay handshake). Returns true when
  /// it was new or changed.
  bool rememberPeer(String phone, String publicKeyB64) {
    final key = _digits(phone);
    final previous = _peerKeys[key];
    if (previous == publicKeyB64) return false;
    _peerKeys[key] = publicKeyB64;
    _prefs?.setString(_kPeers, jsonEncode(_peerKeys));
    if (previous != null) onPeerKeyChanged?.call(key);
    return true;
  }

  static const _kSealedPeers = 'sealed_capable_v1';
  final Set<String> _sealedPeers = {};

  /// Whether [phone]'s build has said it can open sealed-sender envelopes.
  /// A sealed envelope sent to a build that cannot open it is a LOST
  /// message, which is worse than metadata — so this is advertised (the
  /// `sv` flag on a legacy message) before it is ever relied on.
  bool sealedCapable(String phone) => _sealedPeers.contains(_digits(phone));

  /// Records that [phone]'s build advertised sealed-sender support.
  void rememberSealedCapable(String phone) {
    if (_sealedPeers.add(_digits(phone))) {
      _prefs?.setStringList(_kSealedPeers, _sealedPeers.toList()..sort());
    }
  }

  /// A second, independent identity — for tests that need two devices.
  ///
  /// The real thing is a singleton because a phone has one identity. Proving
  /// that an invite sealed to one key cannot be opened by another needs three
  /// of them in one process.
  @visibleForTesting
  factory SecureKeyExchange.freshForTest() =>
      SecureKeyExchange._()..ensureKeys();

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

  /// Replaces this device's identity with a restored one and persists it —
  /// the recovery-code path. The peer cache survives: their keys did not
  /// change, and ours just changed BACK to the one they already hold.
  Future<void> adoptIdentity(String privateHex) async {
    final d = BigInt.parse(privateHex, radix: 16);
    _priv = ECPrivateKey(d, _domain);
    _pub = ECPublicKey(_domain.G * d, _domain);
    _publicKeyB64 = base64.encode(_pub!.Q!.getEncoded(false));
    await SecureStore.instance.write('device_ec_priv', privateHex);
    // Never leave a stale copy where backups can reach it.
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kPriv);
  }

  /// Derives the 32-byte shared secret with a peer's base64 public key, or
  /// null if the key is malformed or our keys aren't ready.
  List<int>? sharedSecretWith(String peerPublicKeyB64) {
    if (_priv == null) return null;
    try {
      final point = _domain.curve.decodePoint(base64.decode(peerPublicKeyB64));
      if (point == null) return null;
      final agreement = ECDHBasicAgreement()..init(_priv!);
      final shared = agreement.calculateAgreement(ECPublicKey(point, _domain));
      return fixed32(shared);
    } catch (_) {
      return null;
    }
  }

  /// Left-pads / trims a BigInt to exactly 32 bytes (the P-256 field size).
  /// Public because the Double Ratchet's own DH steps need the same fixing.
  static List<int> fixed32(BigInt v) {
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

  /// Forgets the in-memory keys (tests, and the account wipe).
  void resetForTest() {
    _priv = null;
    _pub = null;
    _publicKeyB64 = null;
    _peerKeys.clear();
    _sealedPeers.clear();
    lastLoadError = null;
  }
}
