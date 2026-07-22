import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// End-to-end encryption for relayed messages.
///
/// Message bodies are encrypted on the sending device and only decrypted on
/// the recipient's device, so the relay (Supabase Realtime) forwards
/// ciphertext it cannot read. The scheme is authenticated encrypt-then-MAC
/// built on HMAC-SHA256:
///
///   K       = SHA256("okaymsg-e2e-v1|" + sorted(digitsA, digitsB))
///   Kenc    = HMAC(K, "enc")          Kmac = HMAC(K, "mac")
///   nonce   = 16 random bytes
///   stream  = HMAC(Kenc, nonce || counter) blocks, XORed into the plaintext
///   tag     = HMAC(Kmac, nonce || ciphertext)
///   blob    = base64(nonce || ciphertext || tag)
///
/// **Threat model (be honest):** this hides message contents from the relay
/// operator and any passive network observer. It is *not* a full PKI like
/// Signal — the conversation key is derived from the two participants' phone
/// numbers, so it protects against the relay, not against an adversary who
/// already knows both numbers. It is a real, meaningful confidentiality layer,
/// not a replacement for a verified key exchange.
class E2eCrypto {
  E2eCrypto._();

  static const _context = 'okaymsg-e2e-v1';
  static final Random _rng = Random.secure();

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Derives the shared 32-byte conversation key for two phone numbers. The
  /// numbers are sorted so both sides compute an identical key.
  static List<int> keyFor(String phoneA, String phoneB) {
    final a = _digits(phoneA);
    final b = _digits(phoneB);
    final ordered = (a.compareTo(b) <= 0) ? '$a|$b' : '$b|$a';
    return sha256.convert(utf8.encode('$_context|$ordered')).bytes;
  }

  static List<int> _subKey(List<int> key, String label) =>
      Hmac(sha256, key).convert(utf8.encode(label)).bytes;

  /// Produces `counter`-indexed keystream bytes from a nonce.
  static Uint8List _keystream(List<int> kEnc, List<int> nonce, int length) {
    final out = Uint8List(length);
    final mac = Hmac(sha256, kEnc);
    var offset = 0;
    var counter = 0;
    while (offset < length) {
      final block =
          mac.convert([...nonce, ...(_u32(counter))]).bytes; // 32 bytes
      final take = min(block.length, length - offset);
      for (var i = 0; i < take; i++) {
        out[offset + i] = block[i];
      }
      offset += take;
      counter++;
    }
    return out;
  }

  static List<int> _u32(int v) =>
      [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  /// Encrypts [plaintext] under the conversation [key], returning a base64 blob.
  static String encrypt(List<int> key, String plaintext) {
    final kEnc = _subKey(key, 'enc');
    final kMac = _subKey(key, 'mac');
    final nonce =
        Uint8List.fromList(List.generate(16, (_) => _rng.nextInt(256)));
    final data = utf8.encode(plaintext);
    final stream = _keystream(kEnc, nonce, data.length);
    final cipher = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      cipher[i] = data[i] ^ stream[i];
    }
    final tag = Hmac(sha256, kMac).convert([...nonce, ...cipher]).bytes;
    return base64.encode([...nonce, ...cipher, ...tag]);
  }

  /// Decrypts a base64 [blob] produced by [encrypt]. Returns null if the blob
  /// is malformed or its authentication tag does not verify.
  static String? decrypt(List<int> key, String blob) {
    List<int> raw;
    try {
      raw = base64.decode(blob);
    } catch (_) {
      return null;
    }
    if (raw.length < 16 + 32) return null;
    final nonce = raw.sublist(0, 16);
    final cipher = raw.sublist(16, raw.length - 32);
    final tag = raw.sublist(raw.length - 32);

    final kMac = _subKey(key, 'mac');
    final expected = Hmac(sha256, kMac).convert([...nonce, ...cipher]).bytes;
    if (!_constantTimeEquals(tag, expected)) return null;

    final kEnc = _subKey(key, 'enc');
    final stream = _keystream(kEnc, nonce, cipher.length);
    final plain = Uint8List(cipher.length);
    for (var i = 0; i < cipher.length; i++) {
      plain[i] = cipher[i] ^ stream[i];
    }
    try {
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
