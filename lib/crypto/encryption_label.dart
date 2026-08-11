/// The words the app uses to tell somebody how — or whether — a message was
/// encrypted.
///
/// The app has four different protections in play and they are genuinely
/// different promises. A single "end-to-end encrypted" sentence everywhere
/// would be true of most of them and a lie about the rest, so each rung says
/// what it actually is, including the two that are weaker than the headline
/// and the one that is no encryption at all.
///
/// Pure by design — no Flutter, no crypto, no relay. It only names things, so
/// the wording can be tested and there is one copy of it to change.
library;

/// How a stored message was protected.
enum EncryptionKind {
  /// Nothing recorded. A message that predates this field, or one that was
  /// never sent anywhere (a note to self). Never claims a rung it cannot
  /// prove.
  unknown,

  /// Readable by whoever holds it, the relay included.
  none,

  /// The phone-derived key: the floor rung, used before the two devices have
  /// exchanged keys.
  basic,

  /// Static ECDH — a key agreed between the two devices' identity keys.
  keyExchange,

  /// The Signal Double Ratchet: a fresh key per message.
  ratchet,

  /// A Signal sender key: the forward-secret, signed per-sender chain the
  /// server/community bus rides.
  senderKey,

  /// The server's shared secret — every member holds the same key. Only
  /// senders on older builds still use it.
  serverSecret,
}

/// Maps [EncryptionKind] to the codes stored on a message and the sentences
/// shown to a user.
class EncryptionLabel {
  EncryptionLabel._();

  /// Codes 0–3 are the pairwise ladder and are exactly the `enc` field on the
  /// wire (see `RelayService.sealContent`). 4 and 5 are LOCAL-ONLY: they
  /// describe the community bus, which carries no `enc` field, and
  /// [fromWire] refuses them so a payload cannot claim one.
  static const int codeUnknown = -1;
  static const int codeNone = 0;
  static const int codeBasic = 1;
  static const int codeKeyExchange = 2;
  static const int codeRatchet = 3;
  static const int codeSenderKey = 4;
  static const int codeServerSecret = 5;

  /// The code stored on a message for [kind].
  static int codeOf(EncryptionKind kind) => switch (kind) {
        EncryptionKind.unknown => codeUnknown,
        EncryptionKind.none => codeNone,
        EncryptionKind.basic => codeBasic,
        EncryptionKind.keyExchange => codeKeyExchange,
        EncryptionKind.ratchet => codeRatchet,
        EncryptionKind.senderKey => codeSenderKey,
        EncryptionKind.serverSecret => codeServerSecret,
      };

  /// Reads a stored code back. Anything unrecognised reads as [unknown]
  /// rather than as a guess.
  static EncryptionKind fromCode(int? code) => switch (code) {
        codeNone => EncryptionKind.none,
        codeBasic => EncryptionKind.basic,
        codeKeyExchange => EncryptionKind.keyExchange,
        codeRatchet => EncryptionKind.ratchet,
        codeSenderKey => EncryptionKind.senderKey,
        codeServerSecret => EncryptionKind.serverSecret,
        _ => EncryptionKind.unknown,
      };

  /// Reads the `enc` field off a relay payload. Clamped to the pairwise
  /// ladder: the two community codes are local bookkeeping, so a payload
  /// claiming 4 or 5 must not be believed. A payload with no `enc` at all is
  /// the oldest wire format, which carried its fields in the clear — that is
  /// [EncryptionKind.none], not "unknown".
  static EncryptionKind fromWire(Object? enc) {
    final n = enc is num
        ? enc.toInt()
        : enc is String
            ? int.tryParse(enc)
            : enc == true
                ? codeBasic
                : null;
    if (n == null) return EncryptionKind.none;
    if (n < codeNone || n > codeRatchet) return EncryptionKind.unknown;
    return fromCode(n);
  }

  /// Whether this rung means the content was unreadable to the relay.
  static bool isEncrypted(EncryptionKind kind) =>
      kind != EncryptionKind.none && kind != EncryptionKind.unknown;

  /// The short line — a status, not a sentence.
  static String title(EncryptionKind kind) => switch (kind) {
        EncryptionKind.unknown => 'Encryption not recorded',
        EncryptionKind.none => 'Not encrypted',
        EncryptionKind.basic => 'Encrypted',
        EncryptionKind.keyExchange => 'Encrypted with their device key',
        EncryptionKind.ratchet => 'Encrypted · Signal Double Ratchet',
        EncryptionKind.senderKey => 'Encrypted · Signal sender key',
        EncryptionKind.serverSecret => 'Encrypted with the server key',
      };

  /// The honest explanation under the title, including what each rung does
  /// NOT protect against.
  static String detail(EncryptionKind kind) => switch (kind) {
        EncryptionKind.unknown =>
          'No record of a key for this one. Either it never left this device, '
              'or it was stored before the app began keeping track.',
        EncryptionKind.none =>
          'This was sent without encryption, so the relay could read it. Only '
              'the oldest builds send this way.',
        EncryptionKind.basic =>
          'Encrypted before it left this device, with a key derived from the '
              'two phone numbers. It steps up as soon as their device '
              'introduces its own key.',
        EncryptionKind.keyExchange =>
          'Encrypted with a key agreed directly between the two devices. It '
              'steps up to the Signal Double Ratchet as you keep messaging.',
        EncryptionKind.ratchet =>
          'Encrypted with the Signal protocol\'s Double Ratchet. This message '
              'had a key of its own, so a key stolen later cannot unlock it.',
        EncryptionKind.senderKey =>
          'Encrypted with a Signal sender key: one key per message, deleted '
              'after use, and signed so no other member could have forged it. '
              'The server holds only ciphertext.',
        EncryptionKind.serverSecret =>
          'Encrypted with the key every member of this server holds. Sent by '
              'a device on an older build — current ones use a per-sender key '
              'instead, which a leaked server key cannot unlock.',
      };
}
