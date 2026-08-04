import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'e2e.dart';
import 'key_exchange.dart';
import '../state/secure_store.dart';

/// The Signal Double Ratchet, as published — with two parameter substitutions
/// this file must be honest about.
///
/// This is the construction from Signal's Double Ratchet specification
/// (Perrin & Marlinspike): a DH ratchet advancing a root key on every reply,
/// feeding symmetric KDF chains that mint ONE key per message and delete it
/// on use. What that buys over the static ECDH secret used before:
///
///  * **Forward secrecy** — a key stolen today opens none of yesterday's
///    messages; those keys no longer exist anywhere.
///  * **Post-compromise security** — a copied session heals: one round trip
///    of real messages and the thief's copy derives garbage.
///  * **Replay refusal** — a message key is deleted on use, so the same
///    ciphertext delivered twice decrypts once.
///
/// The substitutions, and why:
///
///  * **DH is P-256 ECDH, not X25519.** The spec parameterizes DH and the
///    app's identity keys are already P-256 (see [SecureKeyExchange]) — one
///    curve everywhere beats two curves and a second code path.
///  * **The X3DH prekey server is stood in for by the app's existing in-band
///    key exchange.** Bootstrap trust is exactly what it was before this
///    file: the static ECDH secret, confirmable out-of-band via the safety
///    number. What X3DH would add — one-time prekeys, deniability, offline
///    first-contact — is a server change and is deliberately not faked here.
///
/// **Roles are fixed, not raced.** The side with the lexicographically
/// smaller digits is permanently the initiator ("Alice"): only she ever
/// CREATES a session, on her first send; the other side ("Bob") builds his
/// half from her first header, using his identity pair as the initial ratchet
/// key — the same doubling-up the spec allows for the signed prekey. Two
/// sides that both speak first would otherwise mint two incompatible
/// sessions and each lose the other's opener. Until Alice has spoken, Bob's
/// messages ride the static-ECDH path unchanged — the ratchet is an upgrade
/// on top of that floor, never a regression below it.
class DoubleRatchet {
  DoubleRatchet._(this._kx);
  static final DoubleRatchet instance = DoubleRatchet._(null);

  /// Tests build two of these — one per fake device — around
  /// [SecureKeyExchange.freshForTest] identities.
  @visibleForTesting
  factory DoubleRatchet.freshForTest(SecureKeyExchange kx) =>
      DoubleRatchet._(kx);

  final SecureKeyExchange? _kx;
  SecureKeyExchange get _keys => _kx ?? SecureKeyExchange.instance;

  static const _kStore = 'double_ratchet_v1';

  /// The spec's MAX_SKIP: how far ahead a chain may be wound to cover lost
  /// or out-of-order messages. Bounded so a forged header cannot make a
  /// device grind through millions of derivations.
  static const maxSkip = 256;

  /// Total skipped keys kept per peer, oldest dropped first. A dropped key
  /// is a message that can never be read — the price of bounding memory.
  static const maxStoredSkipped = 1024;

  static final ECDomainParameters _domain = ECDomainParameters('secp256r1');

  final Map<String, _Session> _sessions = {};

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Loads persisted sessions — from the keychain, where chain keys belong;
  /// a copy that predates it migrates in and leaves the backed-up plist.
  /// Safe to call once at startup.
  Future<void> load() async {
    final raw =
        await SecureStore.instance.readMigrating('double_ratchet', _kStore);
    if (raw == null) return;
    try {
      (jsonDecode(raw) as Map<String, dynamic>).forEach((peer, s) {
        _sessions[peer] = _Session.fromJson(Map<String, dynamic>.from(s));
      });
    } catch (_) {}
  }

  void _persist() {
    SecureStore.instance.writeLater(
        'double_ratchet',
        jsonEncode(
            {for (final e in _sessions.entries) e.key: e.value.toJson()}));
  }

  /// Whether this side is the fixed initiator for the pair. Only the smaller
  /// number ever creates a session; the comparison is the same both ends
  /// make, so the roles can never collide.
  bool amInitiator(String myPhone, String peerPhone) =>
      _digits(myPhone).compareTo(_digits(peerPhone)) < 0;

  /// Whether a live ratchet session with [peer] exists on this device — the
  /// question the security screen answers, so it can say which rung of the
  /// encryption ladder this conversation is actually on.
  bool hasSession(String peer) => _sessions.containsKey(_digits(peer));

  /// Drops the session with [peer] — called when their identity key changes,
  /// because every secret under the old key is now a secret with the wrong
  /// person. The next send (or their next header) starts a fresh session.
  void resetPeer(String peer) {
    if (_sessions.remove(_digits(peer)) != null) _persist();
  }

  /// Drops every session — for when this device's OWN identity is replaced
  /// (a recovery-code restore): each session was keyed under the identity
  /// being discarded, and speaking on one would seal to a self that no
  /// longer exists. Fresh sessions form on the next exchange.
  void resetAllSessions() {
    if (_sessions.isEmpty) return;
    _sessions.clear();
    _persist();
  }

  /// Encrypts [plaintext] for [peer], creating the session on first use when
  /// this side is the initiator. Returns null when no session exists and one
  /// may not be created here (the responder before the first ratchet message,
  /// or no peer identity key yet) — the caller falls back to static ECDH.
  ({Map<String, dynamic> header, String blob})? encrypt(
      String myPhone, String peer, String plaintext) {
    final id = _digits(peer);
    var s = _sessions[id];
    if (s == null) {
      if (!amInitiator(myPhone, peer)) return null;
      final peerIdentity = _keys.peerKey(peer);
      if (peerIdentity == null || !_keys.isReady) return null;
      final sk = _keys.sharedSecretWith(peerIdentity);
      if (sk == null) return null;
      // RatchetInitAlice: fresh ratchet pair, root stepped with a DH against
      // Bob's identity key, which doubles as his initial ratchet key.
      final pair = _generatePair();
      final dhOut = _dh(pair.privHex, peerIdentity);
      if (dhOut == null) return null;
      final stepped = _kdfRk(sk, dhOut);
      s = _Session(
        sid: _newSid(),
        rk: stepped.rk,
        dhsPriv: pair.privHex,
        dhsPub: pair.pubB64,
        dhrPub: peerIdentity,
        cks: stepped.ck,
      );
      _sessions[id] = s;
    }
    final cks = s.cks;
    if (cks == null) return null;
    final mk = _kdfCkMessage(cks);
    s.cks = _kdfCkNext(cks);
    final header = {'sid': s.sid, 'dh': s.dhsPub, 'pn': s.pn, 'n': s.ns};
    final blob = E2eCrypto.encrypt(mk, plaintext, aad: _aad(header));
    s.ns++;
    _persist();
    return (header: header, blob: blob);
  }

  /// Decrypts [blob] from [peer]. Returns null when the key cannot be found —
  /// wrong session, replayed message (its key was used and deleted), or a
  /// header wound further ahead than [maxSkip] allows.
  ///
  /// **Transactional, and that is load-bearing.** A failed decrypt restores
  /// the session to exactly what it was, because the mutating body below
  /// advances the chain BEFORE the ciphertext gets its say. Delivery here is
  /// broadcast + mailbox, so the same envelope routinely arrives twice — and
  /// a replay that burned a chain key on its way to failing left the chain
  /// one key ahead of the sender, which made every GENUINE message after it
  /// unreadable ("Couldn't unlock this message", again and again) until a
  /// heal buried the session. A stale header could even overwrite the live
  /// session with a freshly-minted wrong one. Failure must leave no
  /// fingerprints; this wrapper is where the spec's rule is enforced.
  String? decrypt(String myPhone, String peer,
      Map<String, dynamic> header, String blob) {
    final id = _digits(peer);
    final prior = _sessions[id]?.toJson();
    final out = _decryptMutating(myPhone, peer, header, blob);
    if (out == null) {
      if (prior != null) {
        _sessions[id] = _Session.fromJson(prior);
      } else {
        _sessions.remove(id);
      }
      _persist();
    }
    return out;
  }

  String? _decryptMutating(String myPhone, String peer,
      Map<String, dynamic> header, String blob) {
    final id = _digits(peer);
    final sid = header['sid'] as String? ?? '';
    final theirDh = header['dh'] as String? ?? '';
    final pn = (header['pn'] as num?)?.toInt() ?? 0;
    final n = (header['n'] as num?)?.toInt() ?? 0;
    if (sid.isEmpty || theirDh.isEmpty) return null;

    var s = _sessions[id];
    // A header naming a session this side does not hold: as the responder,
    // build Bob's half from it — a fresh conversation, or the initiator
    // reset (new device, new identity) and started over. The initiator
    // ignores foreign sids instead: she mints them, so a foreign one is
    // stale traffic or forgery, and becoming Bob on demand would let anyone
    // who can replay a header roll her session backwards.
    if ((s == null || s.sid != sid) && !amInitiator(myPhone, peer)) {
      if (!_keys.isReady) return null;
      final peerIdentity = _keys.peerKey(peer);
      if (peerIdentity == null) return null;
      final sk = _keys.sharedSecretWith(peerIdentity);
      if (sk == null) return null;
      // RatchetInitBob: root = SK, ratchet pair = identity pair. Alice's
      // first header lands in the ordinary DH-ratchet step below.
      s = _Session(
        sid: sid,
        rk: sk,
        dhsPriv: _keys.exportPrivate(),
        dhsPub: _keys.myPublicKey!,
      );
      _sessions[id] = s;
    }
    if (s == null || s.sid != sid) return null;

    // Try the skipped-key shelf first: an out-of-order arrival whose chain
    // has already moved past it.
    final skippedKey = '$theirDh|$n';
    final skipped = s.skipped.remove(skippedKey);
    if (skipped != null) {
      _persist();
      return E2eCrypto.decrypt(base64.decode(skipped), blob,
          aad: _aad(header));
    }

    if (theirDh != s.dhrPub) {
      // A new ratchet key from the far side: shelve what remains of the old
      // receiving chain (pn says how long it was), then step the root twice
      // — once to receive under their new key, once to send under ours.
      if (!_skipTo(s, pn)) return null;
      s.pn = s.ns;
      s.ns = 0;
      s.nr = 0;
      s.dhrPub = theirDh;
      final recvDh = _dh(s.dhsPriv, theirDh);
      if (recvDh == null) return null;
      final recvStep = _kdfRk(s.rk, recvDh);
      s.rk = recvStep.rk;
      s.ckr = recvStep.ck;
      final pair = _generatePair();
      s.dhsPriv = pair.privHex;
      s.dhsPub = pair.pubB64;
      final sendDh = _dh(s.dhsPriv, theirDh);
      if (sendDh == null) return null;
      final sendStep = _kdfRk(s.rk, sendDh);
      s.rk = sendStep.rk;
      s.cks = sendStep.ck;
    }
    if (!_skipTo(s, n)) return null;
    final ckr = s.ckr;
    if (ckr == null) return null;
    final mk = _kdfCkMessage(ckr);
    s.ckr = _kdfCkNext(ckr);
    s.nr++;
    _persist();
    return E2eCrypto.decrypt(mk, blob, aad: _aad(header));
  }

  /// Winds the receiving chain forward to message [until], shelving each
  /// passed-over key for its out-of-order message. False when the header
  /// asks for more than [maxSkip] — a lost decade of messages, or a forgery
  /// trying to make this device grind.
  bool _skipTo(_Session s, int until) {
    if (s.ckr == null) return until == 0 || s.nr >= until;
    if (until - s.nr > maxSkip) return false;
    while (s.nr < until) {
      final mk = _kdfCkMessage(s.ckr!);
      s.skipped['${s.dhrPub}|${s.nr}'] = base64.encode(mk);
      s.ckr = _kdfCkNext(s.ckr!);
      s.nr++;
    }
    while (s.skipped.length > maxStoredSkipped) {
      s.skipped.remove(s.skipped.keys.first);
    }
    return true;
  }

  // --- KDFs, straight from the spec ---------------------------------------

  /// KDF_RK: HKDF-SHA256 over the DH output, salted with the old root key,
  /// yielding the next root key and a fresh chain key.
  static ({List<int> rk, List<int> ck}) _kdfRk(
      List<int> rk, List<int> dhOut) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(dhOut),
        64,
        Uint8List.fromList(rk),
        utf8.encode('okaymsg-ratchet-rk'),
      ));
    final out = hkdf.process(Uint8List(64));
    return (rk: out.sublist(0, 32), ck: out.sublist(32));
  }

  /// KDF_CK: two HMACs with distinct one-byte inputs — 0x01 mints the
  /// message key, 0x02 advances the chain.
  static List<int> _kdfCkMessage(List<int> ck) =>
      Hmac(sha256, ck).convert(const [0x01]).bytes;

  static List<int> _kdfCkNext(List<int> ck) =>
      Hmac(sha256, ck).convert(const [0x02]).bytes;

  /// The header, authenticated: it rides in the clear (routing needs it) but
  /// GCM refuses the message if a single field of it was touched.
  static Uint8List _aad(Map<String, dynamic> h) => Uint8List.fromList(
      utf8.encode('${h['sid']}|${h['dh']}|${h['pn']}|${h['n']}'));

  // --- P-256 helpers -------------------------------------------------------

  static final Random _rng = Random.secure();

  static String _newSid() => base64
      .encode(List.generate(9, (_) => _rng.nextInt(256)))
      .replaceAll('/', '_');

  static ({String privHex, String pubB64}) _generatePair() {
    final seed =
        Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain),
          FortunaRandom()..seed(KeyParameter(seed))));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;
    return (
      privHex: priv.d!.toRadixString(16),
      pubB64: base64.encode(pub.Q!.getEncoded(false)),
    );
  }

  static List<int>? _dh(String privHex, String pubB64) {
    try {
      final d = BigInt.parse(privHex, radix: 16);
      final point = _domain.curve.decodePoint(base64.decode(pubB64));
      if (point == null) return null;
      final agreement = ECDHBasicAgreement()
        ..init(ECPrivateKey(d, _domain));
      final shared =
          agreement.calculateAgreement(ECPublicKey(point, _domain));
      return SecureKeyExchange.fixed32(shared);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void resetForTest() => _sessions.clear();

  @visibleForTesting
  Map<String, dynamic> debugSessionJson(String peer) =>
      _sessions[_digits(peer)]?.toJson() ?? {};

  @visibleForTesting
  void debugRestoreSession(String peer, Map<String, dynamic> json) {
    _sessions[_digits(peer)] = _Session.fromJson(json);
  }
}

/// One conversation's ratchet state. Everything in here is what the spec
/// names: root key, both DH ratchet halves, both chain keys, counters, and
/// the shelf of skipped message keys.
class _Session {
  _Session({
    required this.sid,
    required this.rk,
    required this.dhsPriv,
    required this.dhsPub,
    this.dhrPub = '',
    this.cks,
    this.ckr,
  });

  final String sid;
  List<int> rk;
  String dhsPriv;
  String dhsPub;
  String dhrPub;
  List<int>? cks;
  List<int>? ckr;
  int ns = 0;
  int nr = 0;
  int pn = 0;

  /// '<their dh>|<n>' → base64 message key.
  final Map<String, String> skipped = {};

  Map<String, dynamic> toJson() => {
        'sid': sid,
        'rk': base64.encode(rk),
        'dhsPriv': dhsPriv,
        'dhsPub': dhsPub,
        'dhrPub': dhrPub,
        if (cks != null) 'cks': base64.encode(cks!),
        if (ckr != null) 'ckr': base64.encode(ckr!),
        'ns': ns,
        'nr': nr,
        'pn': pn,
        'skipped': skipped,
      };

  factory _Session.fromJson(Map<String, dynamic> j) {
    final s = _Session(
      sid: j['sid'] as String? ?? '',
      rk: base64.decode(j['rk'] as String? ?? ''),
      dhsPriv: j['dhsPriv'] as String? ?? '',
      dhsPub: j['dhsPub'] as String? ?? '',
      dhrPub: j['dhrPub'] as String? ?? '',
      cks: j['cks'] == null ? null : base64.decode(j['cks'] as String),
      ckr: j['ckr'] == null ? null : base64.decode(j['ckr'] as String),
    );
    s.ns = (j['ns'] as num?)?.toInt() ?? 0;
    s.nr = (j['nr'] as num?)?.toInt() ?? 0;
    s.pn = (j['pn'] as num?)?.toInt() ?? 0;
    ((j['skipped'] as Map?) ?? const {})
        .forEach((k, v) => s.skipped['$k'] = '$v');
    return s;
  }
}
