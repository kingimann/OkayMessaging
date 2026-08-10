import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

/// BIP-340 Schnorr signatures over secp256k1 — the signature scheme Nostr
/// events use, and therefore what Nostr Wallet Connect needs before this app
/// can ask a wallet to pay anything.
///
/// **Why this is hand-written.** `pointycastle` ships the secp256k1 curve and
/// the field arithmetic but no Schnorr, and BIP-340 is not ECDSA with a
/// different hash — it has its own nonce derivation, its own tagged hashes,
/// and an even-Y convention that silently negates keys. Getting any of that
/// subtly wrong produces signatures that look fine and are rejected by every
/// relay.
///
/// **So it is held to the published test vectors**, which is the reason this
/// file is worth trusting when the Swift in this project is not: BIP-340
/// ships known-answer vectors, signing with a given `auxRand` is fully
/// deterministic, and a correct implementation must reproduce each signature
/// byte for byte. Those vectors run in the suite on every push.
///
/// Everything else about the curve — point multiplication, decompression,
/// modular inverse — is pointycastle's, not ours.
abstract class Bip340 {
  static final ECDomainParameters _dp = ECCurve_secp256k1();

  /// The curve order.
  static BigInt get _n => _dp.n;

  /// The field prime. Read off the curve rather than written down, so there
  /// is one fewer 64-digit constant to typo.
  static BigInt get _p => (_dp.curve as fp.ECCurve).q!;

  /// `sha256(sha256(tag) ‖ sha256(tag) ‖ msg)` — BIP-340's domain separation.
  /// The tag hash is repeated on purpose; it is not a typo in the spec.
  static Uint8List taggedHash(String tag, List<int> msg) {
    final d = SHA256Digest();
    final t = d.process(Uint8List.fromList(tag.codeUnits));
    return d.process(Uint8List.fromList([...t, ...t, ...msg]));
  }

  static BigInt _int(List<int> b) =>
      BigInt.parse(
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
          radix: 16);

  /// A BigInt as exactly 32 big-endian bytes.
  static Uint8List bytes32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  /// The x-only public key for [privateKey] — 32 bytes, no prefix. BIP-340
  /// keys carry no sign byte at all: the Y coordinate is defined to be the
  /// even one, which is why signing negates the secret when it is not.
  static Uint8List publicKey(Uint8List privateKey) {
    final d = _int(privateKey);
    if (d <= BigInt.zero || d >= _n) {
      throw ArgumentError('private key out of range');
    }
    final point = (_dp.G * d)!;
    return bytes32(point.x!.toBigInteger()!);
  }

  /// Signs the 32-byte [message] under [privateKey], returning 64 bytes.
  ///
  /// [auxRand] is BIP-340's optional 32 bytes of randomness. It is a
  /// parameter rather than generated inside because that is what makes the
  /// published vectors reproducible — a test supplies the spec's value and
  /// compares the whole signature. Callers pass real randomness.
  static Uint8List sign(
      Uint8List privateKey, Uint8List message, Uint8List auxRand) {
    if (message.length != 32) throw ArgumentError('message must be 32 bytes');
    if (auxRand.length != 32) throw ArgumentError('auxRand must be 32 bytes');
    var d = _int(privateKey);
    if (d <= BigInt.zero || d >= _n) {
      throw ArgumentError('private key out of range');
    }
    final pPoint = (_dp.G * d)!;
    final px = pPoint.x!.toBigInteger()!;
    // The even-Y convention: a key whose point has odd Y signs with its
    // negation, so verification can assume even Y and skip the sign bit.
    if (pPoint.y!.toBigInteger()!.isOdd) d = _n - d;

    final t = bytes32(d);
    final aux = taggedHash('BIP0340/aux', auxRand);
    for (var i = 0; i < 32; i++) {
      t[i] = t[i] ^ aux[i];
    }

    final rand =
        taggedHash('BIP0340/nonce', [...t, ...bytes32(px), ...message]);
    var k = _int(rand) % _n;
    if (k == BigInt.zero) throw StateError('nonce is zero');
    final rPoint = (_dp.G * k)!;
    if (rPoint.y!.toBigInteger()!.isOdd) k = _n - k;
    final rx = bytes32(rPoint.x!.toBigInteger()!);

    final e = _int(taggedHash(
            'BIP0340/challenge', [...rx, ...bytes32(px), ...message])) %
        _n;
    final s = (k + e * d) % _n;
    return Uint8List.fromList([...rx, ...bytes32(s)]);
  }

  /// Verifies a 64-byte BIP-340 [signature]. Present because a signer with no
  /// verifier can only be checked against fixed vectors — with one, every
  /// signature the app produces can be round-tripped in a test.
  static bool verify(
      Uint8List publicKeyX, Uint8List message, Uint8List signature) {
    if (publicKeyX.length != 32 ||
        message.length != 32 ||
        signature.length != 64) {
      return false;
    }
    try {
      final p = _liftX(_int(publicKeyX));
      if (p == null) return false;
      final r = _int(signature.sublist(0, 32));
      final s = _int(signature.sublist(32));
      if (r >= _p || s >= _n) return false;
      final e = _int(taggedHash('BIP0340/challenge',
              [...signature.sublist(0, 32), ...publicKeyX, ...message])) %
          _n;
      // R = s·G − e·P
      final sg = (_dp.G * s)!;
      final ep = (p * e)!;
      final rPoint = sg - ep;
      if (rPoint == null || rPoint.isInfinity) return false;
      if (rPoint.y!.toBigInteger()!.isOdd) return false;
      return rPoint.x!.toBigInteger()! == r;
    } catch (_) {
      return false;
    }
  }

  /// The even-Y point with x = [x], or null when x is off the curve. Done
  /// through the curve's own decoder with a 0x02 (even) prefix rather than a
  /// hand-rolled square root.
  static ECPoint? _liftX(BigInt x) {
    if (x >= _p) return null;
    try {
      return _dp.curve.decodePoint(Uint8List.fromList([0x02, ...bytes32(x)]));
    } catch (_) {
      return null;
    }
  }
}
