import 'package:flutter/foundation.dart';

import 'account_email.dart';
import 'account_service.dart';
import 'identity_verification.dart';
import 'session.dart';

/// One place to ask whether the current account has proven its phone, email
/// and government ID. Each signal lives in its own store; this reads all three
/// so a caller — the Settings verification screen, the community-notes gate —
/// never has to re-derive the combination (and they can't drift apart).
///
/// Pure reads of the three singletons, plus test overrides so a gate built on
/// [fullyVerified] is testable without standing up Supabase auth and Stripe.
class AccountVerification {
  const AccountVerification._();

  @visibleForTesting
  static bool? debugPhoneVerified;
  @visibleForTesting
  static bool? debugEmailVerified;
  @visibleForTesting
  static bool? debugIdVerified;

  @visibleForTesting
  static void resetForTest() {
    debugPhoneVerified = null;
    debugEmailVerified = null;
    debugIdVerified = null;
  }

  /// The phone behind sign-in: a real number that went through the SMS code,
  /// not a minted account code. Local/name-only accounts never claim it — the
  /// same derivation the profile's phone chip uses.
  static bool get phoneVerified =>
      debugPhoneVerified ??
      (AccountService.isEnabled &&
          Session.instance.isSignedIn &&
          !Session.instance.isNumberless);

  /// A confirmed recovery email (Supabase emailConfirmedAt), not merely set.
  static bool get emailVerified =>
      debugEmailVerified ??
      (AccountEmail.instance.isSet && AccountEmail.instance.isVerified);

  /// The government-ID check passed (the blue check). Strict on purpose:
  /// `IdentityVerification.allowsTrusted` is deliberately permissive on
  /// server-less builds, and this is not that — it must mean the ID was seen.
  static bool get idVerified =>
      debugIdVerified ?? IdentityVerification.instance.isVerified;

  /// All three proven.
  static bool get fullyVerified =>
      phoneVerified && emailVerified && idVerified;

  /// Which of the three are still missing, in presentation order — so a gate
  /// can name exactly what's left ("Still to verify: email, ID").
  static List<String> get missing => [
        if (!phoneVerified) 'phone',
        if (!emailVerified) 'email',
        if (!idVerified) 'ID',
      ];

  /// A human sentence for the missing set, or '' when nothing is missing.
  static String get missingSentence {
    final m = missing;
    if (m.isEmpty) return '';
    if (m.length == 1) return m.first;
    if (m.length == 2) return '${m.first} and ${m.last}';
    return '${m.sublist(0, m.length - 1).join(', ')} and ${m.last}';
  }
}
