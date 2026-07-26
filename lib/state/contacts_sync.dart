import '../models/user.dart';
import 'account_service.dart';

/// Outcome of a contact sync attempt.
enum ContactSyncStatus {
  /// Completed — [ContactSyncResult.matches] holds the contacts on the app.
  ok,

  /// The user declined the contacts permission.
  permissionDenied,

  /// Not available in this build.
  unsupported,

  /// Permission granted but the device address book has no phone numbers.
  empty,

  /// Something went wrong reading contacts or reaching the directory.
  error,
}

class ContactSyncResult {
  final ContactSyncStatus status;

  /// People from the address book who use OkayMessenger.
  final List<AppUser> matches;

  /// How many device contact numbers were scanned (for the summary line).
  final int scanned;

  const ContactSyncResult(this.status,
      {this.matches = const [], this.scanned = 0});
}

/// Finds which of the user's phone contacts already use OkayMessenger.
///
/// Contact reading is temporarily disabled while the address-book plugin is
/// re-evaluated (it was implicated in an iOS launch crash), so [supported] is
/// false and the UI shows the "unavailable" state. The phone-hash matching
/// logic and its pure helpers are kept intact so the feature can be switched
/// back on without reworking anything else.
class ContactsSync {
  ContactsSync._();
  static final ContactsSync instance = ContactsSync._();

  /// Whether device contacts can be read on this build. Currently off.
  bool get supported => false;

  /// The country calling code to assume for a bare local number (NANP "1").
  static String defaultCountryCode() => '1';

  /// Pure: the set of E.164-digit candidates for one raw phone string. A bare
  /// 10-digit number is also tried with [countryCode] prefixed so a local
  /// address-book entry still matches a fully-qualified directory number.
  static Set<String> phoneCandidates(String raw, {String countryCode = '1'}) {
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

  /// Pure: the de-duplicated list of phone hashes to look up for a batch of
  /// raw numbers.
  static List<String> hashesFor(Iterable<String> rawNumbers,
      {String countryCode = '1'}) {
    final set = <String>{};
    for (final raw in rawNumbers) {
      for (final cand in phoneCandidates(raw, countryCode: countryCode)) {
        set.add(AccountService.phoneHashHex(cand));
      }
    }
    return set.toList();
  }

  /// Contact reading is disabled in this build.
  Future<ContactSyncResult> sync() async =>
      const ContactSyncResult(ContactSyncStatus.unsupported);
}
