import 'dart:math';

/// An account code: what identifies you here when you have no phone number.
///
/// Everything downstream is addressed by digits — the relay listens on
/// `inbox_<digits>`, the mesh addresses a packet by them — so an account
/// without a number still needs a digit string to be reachable at. This mints
/// one that is unmistakably NOT a phone number.
///
/// The leading zeros are the whole trick. An international number never starts
/// with one (a country code runs 1–998), and at twelve digits this is longer
/// than most and shorter than the fifteen E.164 allows, so a code can never be
/// confused with somebody's real number — which matters more than it sounds:
/// a collision would route somebody's messages to a stranger.
class AccountCode {
  AccountCode._();

  /// Marks a digit string as a code rather than a number.
  static const String prefix = '00';

  /// Total length including [prefix].
  static const int length = 12;

  /// The SERVER-minted twin of [prefix], for a code that has to survive
  /// Supabase Auth.
  ///
  /// **The leading zeros are unusable there, and finding out cost a real
  /// round of debugging.** `email-account` stamps a code into the auth user's
  /// `phone` field so the 135 `auth.jwt() ->> 'phone'` conditions accept an
  /// email-verified account — but GoTrue validates that field as E.164, whose
  /// grammar is `[1-9]\d{1,14}`: a leading zero is refused outright. Every
  /// attempt came back `Invalid phone number format (E.164 required)`, which
  /// is why not one account in the project ever carried a `00` phone.
  ///
  /// `999` is the replacement because the ITU **reserves +999** for future
  /// global service applications — it is assigned to no country, so it can
  /// never collide with somebody's real number, which is the same property
  /// the leading zeros were chosen for. Fifteen digits total is E.164's
  /// maximum, so this is the longest a code can be and still be legal.
  static const String serverPrefix = '999';

  /// Total length of a [serverPrefix] code — E.164's ceiling.
  static const int serverLength = 15;

  /// A fresh code. Ten random digits after the prefix — one in ten billion of
  /// meeting another, which for a thing minted once per device is enough.
  static String mint([Random? random]) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer(prefix);
    for (var i = 0; i < length - prefix.length; i++) {
      buffer.write(rng.nextInt(10));
    }
    return buffer.toString();
  }

  /// Whether [value] is one of these rather than a phone number. Tolerant of
  /// how it was typed — somebody reading a code off another phone will put
  /// spaces or dashes in it.
  static bool isCode(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    // A '+' means the person meant a phone number, whatever they typed after.
    if (value.trim().startsWith('+')) return false;
    if (digits.length == length && digits.startsWith(prefix)) return true;
    // The server-minted form. Recognised HERE rather than treated as a real
    // number, so an email-verified account still reads as having no phone:
    // its gates open on the session claim it now holds
    // ([AccountVerification.hasServerSession]), while the verification
    // checklist keeps saying — accurately — that no number was ever proved.
    return digits.length == serverLength && digits.startsWith(serverPrefix);
  }

  /// Whether [value] is the SERVER-minted kind specifically.
  static bool isServerCode(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (value.trim().startsWith('+')) return false;
    return digits.length == serverLength && digits.startsWith(serverPrefix);
  }

  /// Grouped for reading aloud and typing in: `0012 3456 7890`, or
  /// `999 1234 5678 9012` for the server-minted kind.
  static String pretty(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (!isCode(digits)) return value;
    if (digits.length == serverLength) {
      return '${digits.substring(0, 3)} ${digits.substring(3, 7)} '
          '${digits.substring(7, 11)} ${digits.substring(11)}';
    }
    return '${digits.substring(0, 4)} ${digits.substring(4, 8)} '
        '${digits.substring(8)}';
  }

  /// The bare digits of something typed in, ready to address with. Returns
  /// null when it is not a code at all, so a caller can fall through to
  /// treating it as a phone number.
  static String? normalize(String typed) {
    if (!isCode(typed)) return null;
    return typed.replaceAll(RegExp(r'\D'), '');
  }
}
