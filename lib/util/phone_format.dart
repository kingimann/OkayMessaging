/// Pretty-prints a bare phone number for display: "14386386261" becomes
/// "+1 (438) 638-6261" and a ten-digit local number gets the "(438)
/// 638-6261" shape. Anything that isn't purely a phone number — a real
/// name, a username — passes through untouched, so it's safe to run over
/// every title. Pure.
String formatPhoneForDisplay(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return raw;
  // Only numbers-with-phone-punctuation qualify; a single letter disquali-
  // fies, so real names never get mangled.
  if (trimmed.replaceAll(RegExp(r'[\d\s()+.\-]'), '').isNotEmpty) return raw;
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('1')) {
    return '+1 (${digits.substring(1, 4)}) '
        '${digits.substring(4, 7)}-${digits.substring(7)}';
  }
  if (digits.length == 10) {
    return '(${digits.substring(0, 3)}) '
        '${digits.substring(3, 6)}-${digits.substring(6)}';
  }
  // Other international shapes keep their plus; short local fragments are
  // left exactly as typed.
  if (digits.length >= 7 && trimmed.startsWith('+')) return '+$digits';
  return raw;
}
