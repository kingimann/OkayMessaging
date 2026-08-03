import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'e2e.dart';
import '../state/secure_store.dart';

/// Signal's **Sender Keys** — the group half of the protocol, for the one
/// surface the pairwise Double Ratchet cannot cover: the server/community
/// broadcast bus, where one message goes to many members at once.
///
/// A pairwise ratchet needs two endpoints stepping a shared root back and
/// forth; a broadcast has no pair. So each *sender* instead owns a symmetric
/// **sender chain**: a random 32-byte chain key that mints one message key
/// per message (HMAC with 0x01) and then advances itself (HMAC with 0x02),
/// deleting the used key. That one-way chain is what gives **forward
/// secrecy** — a chain key captured today cannot regenerate yesterday's
/// message keys, because deriving backwards through HMAC-SHA256 is infeasible
/// and the old keys are gone.
///
/// The chain's *root* is random, not derived from the server's long-lived
/// shared secret, which is the whole point: compromising that shared secret
/// later reveals nothing about past sender chains. The root reaches other
/// members as a **distribution message** (SKDM: chain key + iteration),
/// carried over the PAIRWISE ratchet (`sealContent`), never under the shared
/// secret — so the SKDM inherits the ratchet's own forward secrecy and the
/// shared secret is never the thing protecting message content.
///
/// **What this core does and does not claim.** It is the forward-secret
/// chain, the skipped-key shelf for out-of-order/lost broadcasts, and epoch
/// rotation (a fresh random chain, so a removed member's copy of the old
/// chain reads nothing sent after they left). It does **not** add
/// per-message signatures, so member-to-member unforgeability stays exactly
/// where the shared-secret scheme left it — any member who holds a sender's
/// chain (as all receivers must, to decrypt) could forge as that sender.
/// Closing that needs a per-sender signing key and is a documented follow-up;
/// it is not a regression, and confidentiality against non-members holds
/// regardless (they never receive the SKDM).
///
/// **Per-message signatures close the one gap.** Every receiver must hold a
/// sender's chain key to decrypt, which would let one member forge messages
/// as another — so each sender also owns a P-256 signing keypair whose
/// PRIVATE half is never distributed. The SKDM carries the public half; every
/// broadcast is signed over its ciphertext, and [open] refuses a message
/// whose signature does not verify. That is Signal's group unforgeability,
/// and it means a member who can read another's messages still cannot write
/// as them. (P-256 rather than Ed25519 for the same reason the ratchet uses
/// it — the app has one curve.)
///
/// The wiring that carries SKDMs between devices and rotates on membership
/// change lives in the relay; like the mesh and the ratchet's transport, the
/// multi-device path is first proven on real devices. This core is proven
/// in-process by its tests.
class SenderKeyStore {
  SenderKeyStore._();
  static final SenderKeyStore instance = SenderKeyStore._();

  @visibleForTesting
  factory SenderKeyStore.freshForTest() => SenderKeyStore._();

  static const _kStore = 'sender_keys_v1';

  /// Matches the ratchet's bound: how far a receiver will wind a chain to
  /// cover lost or out-of-order broadcasts before refusing.
  static const maxSkip = 512;
  static const maxStoredSkipped = 2048;

  static final Random _rng = Random.secure();

  /// My own sending chain per server id.
  final Map<String, _Chain> _own = {};

  /// A chain I'm receiving on, per 'serverId|senderDigits'.
  final Map<String, _Chain> _recv = {};

  static String _rk(String serverId, String sender) => '$serverId|$sender';

  /// Chain roots and the per-sender SIGNING private key live in the
  /// keychain, not the backed-up SharedPreferences plist — a copy that
  /// predates the keychain is migrated in and removed from the plist.
  Future<void> load() async {
    final raw =
        await SecureStore.instance.readMigrating('sender_keys', _kStore);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      (j['own'] as Map?)?.forEach(
          (k, v) => _own['$k'] = _Chain.fromJson(Map<String, dynamic>.from(v)));
      (j['recv'] as Map?)?.forEach((k, v) =>
          _recv['$k'] = _Chain.fromJson(Map<String, dynamic>.from(v)));
    } catch (_) {}
  }

  void _persist() {
    SecureStore.instance.writeLater(
        'sender_keys',
        jsonEncode({
          'own': {for (final e in _own.entries) e.key: e.value.toJson()},
          'recv': {for (final e in _recv.entries) e.key: e.value.toJson()},
        }));
  }

  static Uint8List _random32() =>
      Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));

  static final ECDomainParameters _curve = ECDomainParameters('secp256r1');

  /// A fresh P-256 signing keypair, as (private hex, public base64). The
  /// private half stays on this device and never rides an SKDM.
  static ({String priv, String pub}) _genSigningKey() {
    final seed = _random32();
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(
          ECKeyGeneratorParameters(_curve), FortunaRandom()
            ..seed(KeyParameter(seed))));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;
    return (
      priv: priv.d!.toRadixString(16),
      pub: base64.encode(pub.Q!.getEncoded(false)),
    );
  }

  /// Deterministic (RFC 6979) ECDSA-SHA256 over [msg] — no RNG at sign time,
  /// so a signature can't leak the key through a weak nonce.
  static String _sign(String privHex, List<int> msg) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true,
          PrivateKeyParameter(ECPrivateKey(BigInt.parse(privHex, radix: 16), _curve)));
    final sig =
        signer.generateSignature(Uint8List.fromList(msg)) as ECSignature;
    return '${sig.r.toRadixString(16)}.${sig.s.toRadixString(16)}';
  }

  static bool _verify(String pubB64, List<int> msg, String sig) {
    try {
      final parts = sig.split('.');
      if (parts.length != 2) return false;
      final point = _curve.curve.decodePoint(base64.decode(pubB64));
      if (point == null) return false;
      final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
        ..init(false, PublicKeyParameter(ECPublicKey(point, _curve)));
      return signer.verifySignature(
          Uint8List.fromList(msg),
          ECSignature(BigInt.parse(parts[0], radix: 16),
              BigInt.parse(parts[1], radix: 16)));
    } catch (_) {
      return false;
    }
  }

  /// What a signature covers: the ciphertext, bound to its server and
  /// iteration, so a valid signature can't be lifted onto a different
  /// message, position, or server.
  static List<int> _signed(String serverId, int n, String ct) =>
      [...utf8.encode(ct), ..._aad(serverId, n)];

  /// This device's current sender-key distribution message for [serverId] —
  /// the chain key and the iteration it is at, so a member who accepts it
  /// reads everything from here forward. Creates the chain on first call.
  ///
  /// It hands out the CURRENT chain key, not the epoch's original: a member
  /// who joins mid-conversation should be able to read from now on, and must
  /// NOT be handed the key to messages sent before they arrived.
  ({String ck, int n, String sig}) mySkdm(String serverId) {
    final chain = _ensureOwn(serverId);
    _persist();
    return (ck: base64.encode(chain.ck), n: chain.n, sig: chain.signPub!);
  }

  _Chain _ensureOwn(String serverId) => _own.putIfAbsent(serverId, () {
        final sign = _genSigningKey();
        return _Chain(_random32(), signPriv: sign.priv, signPub: sign.pub);
      });

  /// Whether this device already has a sending chain for [serverId] — i.e.
  /// whether its SKDM has been minted (and so needs distributing).
  bool hasOwn(String serverId) => _own.containsKey(serverId);

  /// Seals [plaintext] under this device's sender chain for [serverId],
  /// advancing the chain and signing the ciphertext. Returns the iteration,
  /// ciphertext, and signature; the receiver pairs the iteration with the
  /// sender's digits to find the message key and verifies against the signing
  /// key the SKDM handed over.
  ({int n, String ct, String sg}) seal(String serverId, String plaintext) {
    final chain = _ensureOwn(serverId);
    final n = chain.n;
    final mk = chain.messageKey();
    chain.advance();
    _persist();
    final ct = E2eCrypto.encrypt(mk, plaintext, aad: _aad(serverId, n));
    return (n: n, ct: ct, sg: _sign(chain.signPriv!, _signed(serverId, n, ct)));
  }

  /// Accepts a peer's SKDM: stores [senderDigits]'s chain and signing key for
  /// [serverId] so their messages can be read (and verified) from iteration
  /// [n] onward. A later SKDM for the same sender replaces the earlier one
  /// (they rotated, or re-sent a fresher key) — but never rolls an existing
  /// chain BACKWARDS, which would re-open message keys a compromise-recovery
  /// rotation just closed.
  /// Returns true when this stored a chain for a sender we had NONE for —
  /// the signal that everything they sealed before now was dropped
  /// undecryptable (the mailbox deletes what it cannot open), and their
  /// feed is worth asking for again.
  bool acceptSkdm(String serverId, String senderDigits, String ck, int n,
      String signPub) {
    final key = _rk(serverId, senderDigits);
    final existing = _recv[key];
    if (existing != null && n < existing.n) return false;
    _recv[key] = _Chain(base64.decode(ck), n: n, signPub: signPub);
    _persist();
    return existing == null;
  }

  /// Whether this device holds [senderDigits]'s chain for [serverId] — i.e.
  /// whether it can read their sender-key traffic, or needs their SKDM first.
  bool canRead(String serverId, String senderDigits) =>
      _recv.containsKey(_rk(serverId, senderDigits));

  /// Opens a sender-key message, verifying its signature first. Null when the
  /// signature does not verify (a member forging as another, or corruption),
  /// the sender's chain is unknown (SKDM not yet received — the caller should
  /// request it), the message is a replay (its key was used and deleted), or
  /// it is wound past [maxSkip].
  String? open(
      String serverId, String senderDigits, int n, String ct, String sg) {
    final chain = _recv[_rk(serverId, senderDigits)];
    if (chain == null) return null;
    // Authenticate before touching the chain: an unverified message must not
    // advance or shelve anything.
    if (chain.signPub == null ||
        !_verify(chain.signPub!, _signed(serverId, n, ct), sg)) {
      return null;
    }
    final shelved = chain.takeSkipped(n);
    if (shelved != null) {
      _persist();
      return E2eCrypto.decrypt(shelved, ct, aad: _aad(serverId, n));
    }
    if (n < chain.n) return null; // already consumed
    if (n - chain.n > maxSkip) return null;
    while (chain.n < n) {
      chain.shelveCurrent();
      chain.advance();
    }
    final mk = chain.messageKey();
    chain.advance();
    chain.trimSkipped();
    _persist();
    return E2eCrypto.decrypt(mk, ct, aad: _aad(serverId, n));
  }

  /// Starts a fresh epoch for [serverId]: a new random sending chain, so
  /// anyone holding the old one (a member who just left) can read nothing
  /// sent afterward. The caller redistributes the new SKDM to the remaining
  /// members. Drops stored receive chains for the server too, so their next
  /// SKDM is taken cleanly.
  void rotate(String serverId) {
    final sign = _genSigningKey();
    _own[serverId] =
        _Chain(_random32(), signPriv: sign.priv, signPub: sign.pub);
    _recv.removeWhere((k, _) => k.startsWith('$serverId|'));
    _persist();
  }

  /// Forgets a server entirely (left it, or it was deleted).
  void forget(String serverId) {
    _own.remove(serverId);
    _recv.removeWhere((k, _) => k.startsWith('$serverId|'));
    _persist();
  }

  /// The iteration and server bind into the GCM tag, so a broadcast can't be
  /// lifted to a different position or server and still authenticate.
  static Uint8List _aad(String serverId, int n) =>
      Uint8List.fromList(utf8.encode('$serverId|$n'));

  @visibleForTesting
  void resetForTest() {
    _own.clear();
    _recv.clear();
  }
}

/// One symmetric chain: a key and the iteration it sits at, plus the shelf of
/// message keys skipped for out-of-order arrivals.
class _Chain {
  _Chain(this.ck, {this.n = 0, this.signPriv, this.signPub});

  List<int> ck;
  int n;

  /// Own chains carry both halves of the signing key; receive chains carry
  /// only the sender's public half, to verify with.
  String? signPriv;
  String? signPub;

  final Map<int, String> skipped = {}; // iteration -> base64 message key

  List<int> messageKey() => Hmac(sha256, ck).convert(const [0x01]).bytes;

  void advance() {
    ck = Hmac(sha256, ck).convert(const [0x02]).bytes;
    n++;
  }

  void shelveCurrent() =>
      skipped[n] = base64.encode(messageKey());

  List<int>? takeSkipped(int at) {
    final v = skipped.remove(at);
    return v == null ? null : base64.decode(v);
  }

  void trimSkipped() {
    while (skipped.length > SenderKeyStore.maxStoredSkipped) {
      skipped.remove(skipped.keys.first);
    }
  }

  Map<String, dynamic> toJson() => {
        'ck': base64.encode(ck),
        'n': n,
        if (signPriv != null) 'sp': signPriv,
        if (signPub != null) 'sP': signPub,
        // Stringified keys: jsonEncode refuses int keys, and this map used
        // to reach it raw — so a chain with ANY shelved out-of-order key
        // silently failed to persist at all (the encode threw inside a
        // swallowed callback). fromJson always parsed them back as ints.
        'skipped': {for (final e in skipped.entries) '${e.key}': e.value},
      };

  factory _Chain.fromJson(Map<String, dynamic> j) {
    final c = _Chain(base64.decode(j['ck'] as String),
        n: (j['n'] as num?)?.toInt() ?? 0,
        signPriv: j['sp'] as String?,
        signPub: j['sP'] as String?);
    ((j['skipped'] as Map?) ?? const {})
        .forEach((k, v) => c.skipped[int.parse('$k')] = '$v');
    return c;
  }
}
