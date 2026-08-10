import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The encrypted one-line preview that rides a push notification, so a locked
/// phone can show WHAT somebody said instead of "New message" — without the
/// words ever being readable off the device.
///
/// **The problem this solves.** A push is composed on the sender's device and
/// travels through the `push-send` Edge Function to Apple before it reaches
/// the recipient. Putting the message text in it hands the plaintext to both,
/// which is the one promise this app cannot break. So the push has always
/// carried a content-free label — a type at best ("📷 Photo"), and for a plain
/// text message the literal string "New message".
///
/// **The shape of the fix**, and it is the one WhatsApp and Signal use: the
/// push carries CIPHERTEXT, and an iOS Notification Service Extension opens it
/// on the recipient's device and rewrites the banner before it is drawn. The
/// server relays bytes it cannot read, exactly as it does for the message
/// itself.
///
/// **Why this is a separate key and not the ratchet.** The extension is a
/// separate process with a hard ~24 MB memory ceiling; it cannot host a
/// Flutter engine, so it cannot run [DoubleRatchet], which lives in Dart. The
/// alternative — reimplementing the ratchet in Swift — means a SECOND
/// implementation of the crypto, with its own state to keep in step with the
/// app's. That is how "Couldn't unlock this message" happens, and it already
/// happened here once.
///
/// So the preview rides a key both sides can compute alone, from identity keys
/// they already hold: HKDF over the static ECDH secret. No new wire event, no
/// distribution, nothing to go stale, and it survives a reinstall the moment
/// the identity key is restored.
///
/// **The honest cost, stated rather than buried.** This key is LONG-LIVED, not
/// forward-secret. Someone who obtains it can read the previews of past pushes
/// they captured. It is strictly weaker than the ratchet — and it is used for
/// nothing else: message bodies on the wire and in the mailbox stay under the
/// ratchet, untouched. What is at risk is a truncated first line, not a
/// conversation. [info] is deliberately NOT the label [E2eCrypto.deriveAesKey]
/// uses, so this key and the message key are unrelated outputs of the same
/// secret — a leaked preview key opens no message, which is the whole point of
/// domain separation.
class NotificationPreview {
  NotificationPreview._();

  /// Domain separation from the message key. Changing this string is a
  /// protocol break: both ends derive independently and never compare notes,
  /// so a sender on a new label produces previews the recipient silently
  /// fails to open. Bump the version suffix only alongside a fallback.
  static const String info = 'okay-notify-preview-v1';

  /// Matches the salt the rest of the app's HKDF uses; the [info] label above
  /// is what makes this a different key.
  static const String salt = 'okaymsg-hkdf';

  /// How much of a message the banner may carry. A lock screen truncates
  /// anyway, and a shorter payload keeps the push inside APNs' 4 KB limit
  /// with room for the rest of the envelope.
  static const int maxChars = 140;

  static final Random _rng = Random.secure();

  /// The AES key both devices derive from the static ECDH [secret] they share.
  ///
  /// Returns the FINAL 32-byte key, not a secret to be stretched again: the
  /// extension is handed exactly these bytes and does one AES-GCM open, so
  /// anything else would mean a KDF in Swift too.
  static Uint8List keyFor(List<int> secret) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(secret),
        32,
        utf8.encode(salt),
        utf8.encode(info),
      ));
    return hkdf.process(Uint8List(32));
  }

  /// Seals [text] under [key] as base64 `nonce(12) ‖ ciphertext ‖ tag(16)`.
  ///
  /// That layout is not arbitrary: it is byte-for-byte what CryptoKit's
  /// `AES.GCM.SealedBox(combined:)` expects, so the extension opens it in two
  /// lines with no framing code to get wrong. It is also the format
  /// [E2eCrypto.encrypt] already produces, so the two stay legible as one
  /// scheme.
  ///
  /// Returns '' for an empty preview — nothing to say, so nothing to attach,
  /// and the push falls back to the label it carries today.
  static String seal(Uint8List key, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final clipped = trimmed.length <= maxChars
        ? trimmed
        : '${trimmed.substring(0, maxChars - 1)}…';
    final nonce =
        Uint8List.fromList(List.generate(12, (_) => _rng.nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final out = gcm.process(Uint8List.fromList(utf8.encode(clipped)));
    return base64.encode(Uint8List.fromList([...nonce, ...out]));
  }

  /// Opens what [seal] produced. The extension does this in Swift; this exists
  /// so the round trip is provable in a test on a machine with no iPhone —
  /// which is the only place any of this can be checked before an archive.
  static String? open(Uint8List key, String blob) {
    Uint8List raw;
    try {
      raw = base64.decode(blob);
    } catch (_) {
      return null;
    }
    if (raw.length < 12 + 16) return null;
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
          false,
          AEADParameters(
              KeyParameter(key), 128, raw.sublist(0, 12), Uint8List(0)));
    try {
      return utf8.decode(gcm.process(raw.sublist(12)));
    } catch (_) {
      // Wrong key or a touched payload. The extension treats this exactly as
      // "no preview available" and leaves the fallback body standing, which
      // is why a failure here can never turn into a wrong banner.
      return null;
    }
  }
}
