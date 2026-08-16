import 'package:flutter/foundation.dart';
// `show Supabase` because gotrue exports a `Session` of its own, and this
// file's whole subject is the app's [Session] — an unqualified import makes
// every mention of it ambiguous.
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../relay/relay_config.dart';
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
  static bool? debugServerSession;

  @visibleForTesting
  static void resetForTest() {
    debugPhoneVerified = null;
    debugEmailVerified = null;
    debugIdVerified = null;
    debugServerSession = null;
  }

  /// Whether this account can actually reach the parts of the app that talk
  /// to the server — the one question every gate should be asking.
  ///
  /// **It asks for the PHONE CLAIM, not for a phone number**, and the
  /// distinction is the whole point. Every server-side rule in this project
  /// keys on `auth.jwt() ->> 'phone'` — 135 conditions across 18 migrations —
  /// and `_shared/http.ts`'s `callerPhone()` returns null for any auth user
  /// without one, so an Edge Function treats such a caller as anonymous. That
  /// claim is therefore the literal, checkable precondition for the wallet,
  /// the directory, posting, moderation and payments working at all.
  ///
  /// The gates used to ask [Session.isNumberless] instead, which answered the
  /// same way only because the two happened to coincide: an account with no
  /// number never got a Supabase session, so it never had the claim. Asking
  /// the real question directly lets an account earn the claim some other way
  /// (see the email path) without every gate having to learn about it.
  ///
  /// **It fails SAFE, which is why it is worth reading live rather than
  /// caching a flag.** If the server half is missing — the Edge Function not
  /// deployed, the stamp refused, the session expired — the claim simply is
  /// not there and the gate stays shut. The failure mode is the honest
  /// padlock, never a screen that opens onto writes the database will refuse
  /// with `42501`, which is the shape of bug this file's own history keeps
  /// coming back to.
  ///
  /// False wherever there is no Supabase to ask (a relay-less build, and
  /// every test that has not overridden it): reading the client throws there,
  /// and a getter that decides whether a screen draws must not be able to
  /// take one down.
  static bool get hasServerSession {
    final override = debugServerSession;
    if (override != null) return override;
    if (!RelayConfig.isEnabled) return false;
    try {
      final phone = Supabase.instance.client.auth.currentUser?.phone ?? '';
      return phone.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether the server-session features must stay behind a gate.
  ///
  /// Deliberately written as "no number AND no claim" rather than as the
  /// claim alone, so this can only ever OPEN a gate that used to be closed
  /// and can never close one that used to be open. An account with a real
  /// number is unaffected by every part of the email path — the first term
  /// short-circuits before [hasServerSession] is consulted at all — which
  /// also keeps a relay-less build and the whole test suite behaving exactly
  /// as they did, where [hasServerSession] is false because there is nothing
  /// to ask.
  static bool get needsServerSession =>
      Session.instance.isNumberless && !hasServerSession;

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
