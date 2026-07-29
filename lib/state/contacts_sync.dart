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

  /// iOS 18+ limited access, and the shared subset came back empty.
  ///
  /// Its own status because the fix is different: the address book is NOT
  /// empty — the user picked "Select Contacts" and shared none (or dismissed
  /// the picker), so the app is only allowed to see an empty slice. Reporting
  /// it as [empty] told people with full address books that they had no
  /// contacts, which reads as a broken app blaming its user.
  limitedEmpty,

  /// Something went wrong reading contacts or reaching the directory.
  error,
}

class ContactSyncResult {
  final ContactSyncStatus status;

  /// People from the address book who use OkayMessenger.
  final List<AppUser> matches;

  /// How many device contact numbers were scanned (for the summary line).
  final int scanned;

  /// True when the OS only let the app see a user-picked subset (iOS 18+),
  /// so [matches] can be honest about being incomplete.
  final bool limited;

  const ContactSyncResult(this.status,
      {this.matches = const [], this.scanned = 0, this.limited = false});
}

/// Finds which of the user's phone contacts already use OkayMessenger, without
/// uploading the address book: contact numbers are normalised and SHA-256
/// hashed on-device, and only the hashes are matched against the server
/// directory (the `usernames` table's `phone_hash` column).
///
/// History, so nobody repeats it: flutter_contacts 1.x crashed the app at
/// launch on iOS. Its plugin *registration* force-unwrapped
/// `UIApplication.shared.delegate.window`, which is nil under the scene
/// lifecycle this app uses — a native crash before any Dart ran, with or
/// without the permission ever being asked. 2.x registers without touching
/// the window and resolves views lazily and scene-aware, so the plugin is
/// safe to carry again. Keep the dependency on 2.x.
class ContactsSync {
  ContactsSync._();
  static final ContactsSync instance = ContactsSync._();

  /// Contact reading is a mobile-only capability.
  bool get supported => !kIsWeb;

  /// Test hook: replaces the plugin round-trip (permission + address book)
  /// with a canned list of raw phone numbers (null = permission declined).
  @visibleForTesting
  static Future<List<String>?> Function()? debugNumbersOverride;

  /// Test hook: whether the canned numbers came through limited access.
  @visibleForTesting
  static bool debugLimited = false;

  /// Test hook: replaces the jump to the OS settings page.
  @visibleForTesting
  static void Function()? debugOpenSettingsOverride;

  /// Test hook: replaces the silent limited-access check.
  @visibleForTesting
  static Future<bool> Function()? debugAccessLimitedOverride;

  /// Whether contact access is currently limited (iOS 18+ "Select
  /// Contacts"), without showing any prompt.
  ///
  /// Checked before a sync so the app can ask the question iOS won't ask
  /// twice: once someone picks limited access, the OS never re-raises its
  /// dialog, and the only ways forward are Settings or living with the
  /// selection. Undecided (never asked) reads as not limited, so the first
  /// sync still goes straight to the real OS prompt.
  Future<bool> isAccessLimited() async {
    final debug = debugAccessLimitedOverride;
    if (debug != null) return debug();
    if (!supported) return false;
    try {
      // Bounded, and failing open: this check gates the sync button, and a
      // stalled plugin channel must degrade to "just sync" — the sync path
      // asks for permission itself and copes with whatever it gets.
      final status = await FlutterContacts.permissions
          .check(PermissionType.read)
          .timeout(const Duration(seconds: 3));
      return status == PermissionStatus.limited;
    } catch (_) {
      return false;
    }
  }

  /// Test hook: replaces the server directory lookup.
  @visibleForTesting
  static Future<List<AppUser>> Function(List<String> hashes)?
      debugLookupOverride;

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

  /// Reads every phone number the device will let the app see, or null when
  /// the user declines. Nothing touches the plugin until the user actually
  /// taps "sync"; the permission prompt is the OS one, raised here.
  ///
  /// The bool is whether access is *limited* (iOS 18+ "Select Contacts") —
  /// the list is then the shared subset, not the address book, and an empty
  /// one means "nothing shared", never "no contacts".
  Future<(List<String>?, bool)> _deviceNumbers() async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.read);
    final limited = status == PermissionStatus.limited;
    if (status != PermissionStatus.granted && !limited) {
      return (null, false);
    }
    final contacts =
        await FlutterContacts.getAll(properties: {ContactProperty.phone});
    return (
      <String>[
        for (final c in contacts)
          for (final p in c.phones)
            if (p.number.trim().isNotEmpty) p.number
      ],
      limited,
    );
  }

  /// The OS settings page for this app — where limited contact access is
  /// widened and a denied permission is granted.
  Future<void> openSettings() async {
    final debug = debugOpenSettingsOverride;
    if (debug != null) {
      debug();
      return;
    }
    await FlutterContacts.permissions.openSettings();
  }

  Future<ContactSyncResult> sync() async {
    final numbersSource = debugNumbersOverride;
    if (!supported && numbersSource == null) {
      return const ContactSyncResult(ContactSyncStatus.unsupported);
    }
    try {
      final (numbers, limited) = numbersSource != null
          ? (await numbersSource(), debugLimited)
          : await _deviceNumbers();
      if (numbers == null) {
        return const ContactSyncResult(ContactSyncStatus.permissionDenied);
      }
      if (numbers.isEmpty) {
        // Limited access seeing nothing is not an empty address book — it is
        // an empty *selection*, fixed in Settings, and saying otherwise sends
        // someone with a full address book hunting a bug in their contacts.
        return ContactSyncResult(limited
            ? ContactSyncStatus.limitedEmpty
            : ContactSyncStatus.empty);
      }
      final hashes = hashesFor(numbers, countryCode: defaultCountryCode());
      final matches = debugLookupOverride != null
          ? await debugLookupOverride!(hashes)
          : await AccountService.instance.lookupByPhoneHashes(hashes);
      return ContactSyncResult(ContactSyncStatus.ok,
          matches: matches, scanned: numbers.length, limited: limited);
    } catch (_) {
      return const ContactSyncResult(ContactSyncStatus.error);
    }
  }
}
