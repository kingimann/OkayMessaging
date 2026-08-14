/// Turns what someone typed into a phone field into a full E.164 number
/// ("+14165551234"), taking the country from [dialCode] when the typed text
/// doesn't carry one. Pure.
///
/// **A bare '+' in front of a local number is not E.164**, and that is the bug
/// this exists to stop: the verify-your-number screen used to prepend '+' to
/// whatever was typed, so a Toronto number went out as `+4167813638` — which
/// the network reads as Switzerland (+41) and refuses (Twilio 60200,
/// `sms_send_failed`). The country code cannot be guessed from the digits, so
/// it has to come from the picker beside the field.
///
/// Idempotent on anything already in E.164, which is what lets it sit at the
/// send-the-SMS choke point without changing numbers that were already right.
String phoneToE164(String typed, {String dialCode = '+1'}) {
  final trimmed = typed.trim();
  if (trimmed.isEmpty) return '';
  // An explicit '+' is the caller saying "this is already international".
  // Taken at its word — there is nothing left to infer from.
  if (trimmed.startsWith('+')) {
    final d = trimmed.replaceAll(RegExp(r'\D'), '');
    return d.isEmpty ? '' : '+$d';
  }
  var local = trimmed.replaceAll(RegExp(r'\D'), '');
  if (local.isEmpty) return '';
  final cc = dialCode.replaceAll(RegExp(r'\D'), '');
  if (cc.isEmpty) return '+$local';
  // The national trunk prefix ('0' before the subscriber number across most
  // of Europe and beyond) is never part of the international form.
  local = local.replaceFirst(RegExp(r'^0+'), '');
  if (local.isEmpty) return '';
  // Already carries its own country code — someone typed 1-416-… under +1.
  // The length guard keeps a genuine local number that happens to start with
  // the country's digits from losing its front.
  if (local.startsWith(cc) && local.length - cc.length >= 7) return '+$local';
  return '+$cc$local';
}

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

/// Groups a number as it is being TYPED on the dial pad, so a run of digits
/// reads as a phone number instead of a bare string. Pure.
///
/// Different from [formatPhoneForDisplay], which only knows what to do with a
/// number that is already complete: this one has to say something sensible
/// after every single keystroke, including halfway through an area code.
///
/// **It only ever groups NANP numbers, and that is deliberate.** The dial pad
/// takes anything, and there is no way to know which country a bare run of
/// digits belongs to — Apple and Google guess from the SIM's region, which
/// this app has no equivalent of. Inventing "(xx) xx-xx-xx" for a number that
/// turns out to be German would be worse than not grouping it, so anything
/// that is not plainly a 10-digit local or 11-digit +1 number is handed back
/// exactly as typed.
///
/// Left alone entirely:
/// * anything carrying `*` or `#` — a feature code (`*67`), not a number;
/// * anything starting `+` — the caller has said which country it is, and it
///   is not this function's to reformat;
/// * more than 11 digits — a shape this cannot name.
String formatDialedNumber(String typed) {
  if (typed.isEmpty) return typed;
  if (typed.startsWith('+') || typed.contains('*') || typed.contains('#')) {
    return typed;
  }
  final d = typed.replaceAll(RegExp(r'\D'), '');
  if (d.length != typed.length) return typed;
  // A leading 1 is the country code, and it stands outside the brackets the
  // way it does on a business card.
  if (d.length == 11 && d.startsWith('1')) {
    return '1 (${d.substring(1, 4)}) ${d.substring(4, 7)}-${d.substring(7)}';
  }
  if (d.length > 10) return typed;
  if (d.length <= 3) return d;
  if (d.length <= 6) return '(${d.substring(0, 3)}) ${d.substring(3)}';
  return '(${d.substring(0, 3)}) ${d.substring(3, 6)}-${d.substring(6)}';
}
