/// Pure digit-matching helpers for phone numbers, kept free of any app
/// imports so both sides of the state/relay import cycle can use them —
/// `chat_store.dart` (which cannot import `session.dart`) and
/// `contacts_sync.dart` (which already does) both need the same
/// country-code-robust comparison.
library;

/// The set of E.164-digit candidates for one raw phone string. A bare
/// 10-digit number is also tried with [countryCode] prefixed so a local
/// address-book entry still matches a fully-qualified directory number.
Set<String> phoneCandidates(String raw, {String countryCode = '1'}) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  final out = <String>{};
  if (digits.length < 7) return out; // too short to be a dialable number
  out.add(digits);
  if (digits.length == 10) out.add('$countryCode$digits');
  if (digits.length == 11 && digits.startsWith('0')) {
    out.add('$countryCode${digits.substring(1)}');
  }
  return out;
}

/// Whether [a] and [b] plausibly name the same phone number, allowing for
/// country-code formatting differences (a bare 10-digit number vs. its
/// 11-digit +1 form) rather than requiring an exact digit match.
bool samePhoneNumber(String a, String b, {String countryCode = '1'}) {
  final da = a.replaceAll(RegExp(r'\D'), '');
  final db = b.replaceAll(RegExp(r'\D'), '');
  if (da.isEmpty || db.isEmpty) return false;
  if (da == db) return true;
  final ca = phoneCandidates(a, countryCode: countryCode);
  final cb = phoneCandidates(b, countryCode: countryCode);
  return ca.intersection(cb).isNotEmpty;
}
