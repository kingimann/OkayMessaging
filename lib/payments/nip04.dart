import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// NIP-04 encryption — the envelope Nostr Wallet Connect puts its requests in,
/// so the relay carrying them cannot read what wallet command was sent or what
/// the wallet answered.
///
/// **This is NOT the app's own message crypto and must never be used for it.**
/// NIP-04 is AES-256-CBC under the raw ECDH shared X coordinate: no KDF, no
/// authentication tag, and the same key for every message between a pair. It
/// is here only because it is what the NWC protocol specifies, and what the
/// wallet on the other end will be speaking. Chat bodies ride the Double
/// Ratchet, which is a different thing entirely.
///
/// What it protects is real but narrow: the relay is an untrusted third party
/// that would otherwise see "pay this invoice for 500 sats" in the clear.
class Nip04 {
  Nip04._();

  static final Random _rng = Random.secure();

  /// The ECDH shared secret between [privateKey] and [peerPublicKeyX], as the
  /// 32-byte X coordinate.
  ///
  /// The peer key is x-only (Nostr's format) so it is lifted to the even-Y
  /// point first — the same convention BIP-340 uses. Both sides land on the
  /// same X whichever Y is chosen, since negating a point leaves X alone; the
  /// even-Y choice is just what makes the two implementations agree.
  static Uint8List sharedSecret(Uint8List privateKey, String peerPublicKeyX) {
    final dp = ECCurve_secp256k1();
    final peer = dp.curve.decodePoint(
        Uint8List.fromList([0x02, ..._hexToBytes(peerPublicKeyX)]));
    if (peer == null) throw ArgumentError('bad peer public key');
    final d = BigInt.parse(_bytesToHex(privateKey), radix: 16);
    final shared = (peer * d)!;
    return _bytes32(shared.x!.toBigInteger()!);
  }

  /// Encrypts [plaintext], returning NIP-04's `<base64 ct>?iv=<base64 iv>`.
  static String encrypt(Uint8List key, String plaintext, {Uint8List? iv}) {
    final nonce =
        iv ?? Uint8List.fromList(List.generate(16, (_) => _rng.nextInt(256)));
    final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(true,
          PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), nonce), null));
    final out = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    return '${base64.encode(out)}?iv=${base64.encode(nonce)}';
  }

  /// Decrypts what [encrypt] produced. Returns null on anything malformed.
  ///
  /// CBC has no authentication tag, so a wrong key does not fail cleanly the
  /// way AES-GCM does — it usually yields padding garbage. Every failure path
  /// lands on null so a caller cannot mistake noise for a wallet's answer.
  static String? decrypt(Uint8List key, String payload) {
    final at = payload.indexOf('?iv=');
    if (at <= 0) return null;
    try {
      final ct = base64.decode(payload.substring(0, at));
      final iv = base64.decode(payload.substring(at + 4));
      if (iv.length != 16 || ct.isEmpty || ct.length % 16 != 0) return null;
      final cipher = PaddedBlockCipherImpl(
          PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(
            false,
            PaddedBlockCipherParameters(
                ParametersWithIV(KeyParameter(key), iv), null));
      return utf8.decode(cipher.process(ct));
    } catch (_) {
      return null;
    }
  }

  static Uint8List _hexToBytes(String s) => Uint8List.fromList([
        for (var i = 0; i + 1 < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);

  static String _bytesToHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _bytes32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}
