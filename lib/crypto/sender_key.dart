import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e.dart';

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

  SharedPreferences? _prefs;

  static String _rk(String serverId, String sender) => '$serverId|$sender';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_kStore);
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
    _prefs?.setString(
        _kStore,
        jsonEncode({
          'own': {for (final e in _own.entries) e.key: e.value.toJson()},
          'recv': {for (final e in _recv.entries) e.key: e.value.toJson()},
        }));
  }

  static Uint8List _random32() =>
      Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));

  /// This device's current sender-key distribution message for [serverId] —
  /// the chain key and the iteration it is at, so a member who accepts it
  /// reads everything from here forward. Creates the chain on first call.
  ///
  /// It hands out the CURRENT chain key, not the epoch's original: a member
  /// who joins mid-conversation should be able to read from now on, and must
  /// NOT be handed the key to messages sent before they arrived.
  ({String ck, int n}) mySkdm(String serverId) {
    final chain = _own.putIfAbsent(serverId, () => _Chain(_random32()));
    _persist();
    return (ck: base64.encode(chain.ck), n: chain.n);
  }

  /// Whether this device already has a sending chain for [serverId] — i.e.
  /// whether its SKDM has been minted (and so needs distributing).
  bool hasOwn(String serverId) => _own.containsKey(serverId);

  /// Seals [plaintext] under this device's sender chain for [serverId],
  /// advancing the chain. Returns the iteration and ciphertext; the receiver
  /// pairs the iteration with the sender's digits to find the message key.
  ({int n, String ct}) seal(String serverId, String plaintext) {
    final chain = _own.putIfAbsent(serverId, () => _Chain(_random32()));
    final n = chain.n;
    final mk = chain.messageKey();
    chain.advance();
    _persist();
    return (n: n, ct: E2eCrypto.encrypt(mk, plaintext, aad: _aad(serverId, n)));
  }

  /// Accepts a peer's SKDM: stores [senderDigits]'s chain for [serverId] so
  /// their messages can be read from iteration [n] onward. A later SKDM for
  /// the same sender replaces the earlier one (they rotated, or re-sent a
  /// fresher key) — but never rolls an existing chain BACKWARDS, which would
  /// re-open message keys a compromise-recovery rotation just closed.
  void acceptSkdm(
      String serverId, String senderDigits, String ck, int n) {
    final key = _rk(serverId, senderDigits);
    final existing = _recv[key];
    if (existing != null && n < existing.n) return;
    _recv[key] = _Chain(base64.decode(ck), n: n);
    _persist();
  }

  /// Whether this device holds [senderDigits]'s chain for [serverId] — i.e.
  /// whether it can read their sender-key traffic, or needs their SKDM first.
  bool canRead(String serverId, String senderDigits) =>
      _recv.containsKey(_rk(serverId, senderDigits));

  /// Opens a sender-key message. Null when the sender's chain is unknown
  /// (SKDM not yet received — the caller should request it), the message is a
  /// replay (its key was used and deleted), or it is wound past [maxSkip].
  String? open(
      String serverId, String senderDigits, int n, String ct) {
    final chain = _recv[_rk(serverId, senderDigits)];
    if (chain == null) return null;
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
    _own[serverId] = _Chain(_random32());
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
  _Chain(this.ck, {this.n = 0});

  List<int> ck;
  int n;
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
        'skipped': skipped,
      };

  factory _Chain.fromJson(Map<String, dynamic> j) {
    final c = _Chain(base64.decode(j['ck'] as String),
        n: (j['n'] as num?)?.toInt() ?? 0);
    ((j['skipped'] as Map?) ?? const {})
        .forEach((k, v) => c.skipped[int.parse('$k')] = '$v');
    return c;
  }
}
