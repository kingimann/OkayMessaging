import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../models/user.dart';
import 'account_service.dart';
import 'session.dart';

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

/// Finds which of the user's phone contacts already use OkayMessenger, without
/// uploading the address book: contact numbers are normalised and SHA-256
/// hashed on-device, and only the hashes are matched against the server
/// directory (the `usernames` table's `phone_hash` column).
///
/// Nothing touches the plugin until the user actually taps "sync", and the
/// permission request comes from the plugin itself — the app deliberately
/// carries no permission_handler (its Podfile macros were the prime suspect
/// in an earlier iOS launch crash).
class ContactsSync {
  ContactsSync._();
  static final ContactsSync instance = ContactsSync._();

  /// Contact reading is a mobile-only capability.
  bool get supported => !kIsWeb;

  /// The country calling code to assume for a bare local number, inferred
  /// from the signed-in user's own number (defaults to NANP "1").
  static String defaultCountryCode() {
    final phone = Session.instance.user.value?.phone ?? '';
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('1')) return '1';
    return '1';
  }

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

  /// Requests contacts permission, reads the address book, and returns the
  /// contacts who use OkayMessenger. Never throws.
  Future<ContactSyncResult> sync() async {
    if (!supported) {
      return const ContactSyncResult(ContactSyncStatus.unsupported);
    }
    try {
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        return const ContactSyncResult(ContactSyncStatus.permissionDenied);
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final numbers = <String>[];
      for (final c in contacts) {
        for (final p in c.phones) {
          if (p.number.trim().isNotEmpty) numbers.add(p.number);
        }
      }
      if (numbers.isEmpty) {
        return const ContactSyncResult(ContactSyncStatus.empty);
      }
      final hashes = hashesFor(numbers, countryCode: defaultCountryCode());
      final matches = await AccountService.instance.lookupByPhoneHashes(hashes);
      return ContactSyncResult(ContactSyncStatus.ok,
          matches: matches, scanned: numbers.length);
    } catch (_) {
      return const ContactSyncResult(ContactSyncStatus.error);
    }
  }
}
