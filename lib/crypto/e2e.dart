import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// End-to-end encryption for relayed messages.
///
/// Message bodies are encrypted on the sending device and only decrypted on
/// the recipient's, so the relay (Supabase Realtime) forwards ciphertext it
/// cannot read. The cipher is **AES-256-GCM** — a standard, audited
/// authenticated-encryption construction — with the key stretched through
/// **HKDF-SHA256**:
///
///   secret  = SHA256("okaymsg-e2e-v1|" + sorted(digitsA, digitsB))
///   key     = HKDF-SHA256(secret, salt="okaymsg-hkdf", info="aes-gcm-key", 32)
///   nonce   = 12 random bytes
///   ct||tag = AES-256-GCM(key, nonce, plaintext)      (16-byte tag)
///   blob    = base64(nonce || ct || tag)
///
/// GCM authenticates the ciphertext, so any tampering (or a wrong key) fails
/// to decrypt and returns null.
///
/// **Threat model (be honest):** this hides message contents from the relay
/// operator and any passive observer. When the two devices have exchanged
/// public keys, [SecureKeyExchange] supplies a much stronger per-pair key via
/// P-256 ECDH; this phone-number-derived key is the fallback used until that
/// handshake completes. It is real confidentiality against the server, not a
/// replacement for verified key exchange.
class E2eCrypto {
  E2eCrypto._();

  static const _context = 'okaymsg-e2e-v1';
  static final Random _rng = Random.secure();

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Derives the shared 32-byte secret for two phone numbers. The numbers are
  /// sorted so both sides compute an identical value.
  static List<int> keyFor(String phoneA, String phoneB) {
    final a = _digits(phoneA);
    final b = _digits(phoneB);
    final ordered = (a.compareTo(b) <= 0) ? '$a|$b' : '$b|$a';
    return sha256.convert(utf8.encode('$_context|$ordered')).bytes;
  }

  /// A stable 60-digit "security code" (safety number) for the conversation
  /// between two numbers, shown as 12 groups of 5 digits. Both devices compute
  /// the same value from the shared secret; if they match, the chat's
  /// encryption is verified (the classic Signal-style comparison).
  static String safetyNumber(String phoneA, String phoneB) {
    final base = keyFor(phoneA, phoneB);
    // Two hash rounds give us plenty of bytes to map to 60 decimal digits.
    final h1 = sha256.convert([...base, ...utf8.encode('safety-1')]).bytes;
    final h2 = sha256.convert([...base, ...utf8.encode('safety-2')]).bytes;
    final bytes = [...h1, ...h2];
    final digits = StringBuffer();
    for (var i = 0; i < 60; i++) {
      digits.write(bytes[i % bytes.length] % 10);
    }
    final s = digits.toString();
    return [
      for (var i = 0; i < 60; i += 5) s.substring(i, i + 5),
    ].join(' ');
  }

  /// Stretches a raw shared secret into a 32-byte AES key via HKDF-SHA256.
  static Uint8List deriveAesKey(List<int> secret) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(secret),
        32,
        utf8.encode('okaymsg-hkdf'), // salt
        utf8.encode('aes-gcm-key'), // info
      ));
    return hkdf.process(Uint8List(32));
  }

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// Encrypts [plaintext] under the shared [secret], returning a base64 blob.
  static String encrypt(List<int> secret, String plaintext) {
    final key = deriveAesKey(secret);
    final nonce = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final data = Uint8List.fromList(utf8.encode(plaintext));
    final out = gcm.process(data); // ciphertext followed by the 16-byte tag
    return base64.encode(Uint8List.fromList([...nonce, ...out]));
  }

  /// Decrypts a base64 [blob]. Returns null if it is malformed, or if GCM
  /// authentication fails (tampered ciphertext or the wrong key).
  static String? decrypt(List<int> secret, String blob) {
    Uint8List raw;
    try {
      raw = base64.decode(blob);
    } catch (_) {
      return null;
    }
    if (raw.length < 12 + 16) return null;
    final nonce = raw.sublist(0, 12);
    final body = raw.sublist(12);
    final key = deriveAesKey(secret);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    try {
      final plain = gcm.process(Uint8List.fromList(body));
      return utf8.decode(plain);
    } catch (_) {
      return null; // InvalidCipherTextException on auth failure, etc.
    }
  }
}
