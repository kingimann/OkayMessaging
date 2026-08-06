/// Refuses phone numbers that can't stand behind an account — toll-free,
/// premium, and the non-geographic "personal communications" ranges that VoIP
/// services hand out. A number is an account's one piece of accountability
/// here (a public post has nobody to answer for it otherwise), so a throwaway
/// virtual line is exactly what this keeps out.
///
/// **Honest limit.** This is a client-side heuristic over the North American
/// Numbering Plan. It catches the ranges that are *definitionally* not a
/// mobile line, but it CANNOT catch a VoIP provider (Google Voice, TextNow)
/// that leases ordinary geographic area codes — telling those apart from a
/// real mobile needs a carrier lookup (Twilio Lookup's line-type intelligence,
/// or the like) run server-side before the code is sent. So this is the cheap
/// first gate, not the whole wall; it's deliberately conservative to avoid
/// turning away a real phone.
library;

class VoipNumbers {
  VoipNumbers._();

  /// Non-geographic NANP area codes reserved for personal-communications /
  /// VoIP-style services — never a physical mobile line.
  static const _nonGeographicNanp = <String>{
    '500', '521', '522', '523', '524', '525', '526', '527', '528', //
    '529', '533', '544', '566', '577', '588',
  };

  /// Toll-free NANP area codes — free to the caller, not a mobile, and they
  /// don't take an SMS one-time code anyway.
  static const _tollFreeNanp = <String>{
    '800', '833', '844', '855', '866', '877', '888',
  };

  /// Numbers exempt from the gate no matter what range they fall in. The App
  /// Review / demo account lives on a 500 area code (a range this otherwise
  /// blocks), and refusing it would lock the reviewer out — keep this in step
  /// with `ReviewerMode.reviewerDigits`.
  static const _allowlist = <String>{'15005550006'};

  /// A user-facing reason this number is refused, or null when it's allowed.
  /// [fullPhone] is anything with a dial code and a national number — the '+',
  /// spaces and dashes are ignored.
  static String? reason(String fullPhone) {
    final digits = fullPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null; // the length validator handles empties
    if (_allowlist.contains(digits)) return null;

    // Only the NANP (+1) has a stable, published map of which prefixes are
    // non-geographic. Outside it, let the number through rather than guess.
    if (!_isNanp(digits)) return null;

    final area = _nanpAreaCode(digits);
    if (area == null) return null;

    if (_tollFreeNanp.contains(area)) {
      return 'Toll-free numbers can\'t be used — sign up with a mobile number.';
    }
    if (area.startsWith('9') && area[1] == '0') {
      // 900-series premium.
      return 'That\'s a premium-rate number — sign up with a mobile number.';
    }
    if (_nonGeographicNanp.contains(area)) {
      return 'That looks like a VoIP or virtual number. Sign up with a '
          'mobile number.';
    }
    return null;
  }

  /// Whether [digits] is a NANP number: 10 digits, or 11 with a leading 1.
  static bool _isNanp(String digits) {
    if (digits.length == 10) return true;
    if (digits.length == 11 && digits.startsWith('1')) return true;
    return false;
  }

  /// The three-digit area code of a NANP [digits] string, or null.
  static String? _nanpAreaCode(String digits) {
    final national = digits.length == 11 ? digits.substring(1) : digits;
    if (national.length != 10) return null;
    return national.substring(0, 3);
  }
}
