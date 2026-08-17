import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/app_pages.dart';
import '../relay/relay_config.dart';
import '../util/disposable_emails.dart';
import 'account_service.dart';
import 'platform_moderation.dart';
import 'two_step.dart';

/// The outcome of trying to attach an email to the account.
enum EmailSaveResult {
  /// Saved, and a confirmation email is on its way.
  verificationSent,

  /// Saved on this device, but nothing could be sent to confirm it — the
  /// project has no email auth configured, or we're signed in locally only.
  savedUnverified,

  /// The address isn't a valid email.
  invalid,

  /// Refused: the existing address changed too recently. Like the
  /// username, an email changes at most once every 30 days — it is the
  /// way back into the account, and a recovery address that moves weekly
  /// is what a takeover looks like.
  tooSoon,

  /// Refused: this email was banned by a moderator, so it can't be attached
  /// to any account (docs/banned_signups.sql).
  banned,

  /// Refused: a throwaway inbox. An email is one third of what full
  /// verification means here, and a mailbox that expires in ten minutes
  /// proves nothing about who is behind the account.
  disposable,

  /// Refused: another account already holds this address. An email is a way
  /// back INTO an account, so two accounts sharing one is two people with a
  /// claim on the same recovery route (docs/taken_signups.sql).
  taken,
}

extension EmailSaveOutcome on EmailSaveResult {
  /// Whether the address was actually attached. Six of the eight outcomes are
  /// refusals, and a caller that ignores the result silently drops the
  /// address while its own success message says otherwise.
  bool get saved =>
      this == EmailSaveResult.verificationSent ||
      this == EmailSaveResult.savedUnverified;

  /// A short reason a save was refused, for a caller whose main job was
  /// something else and which has one line to spare. Null when it saved.
  ///
  /// Deliberately terser than the sentences on the email screen, which owns
  /// the field and can afford to explain — this one has to fit on the end of
  /// somebody else's confirmation.
  String? get shortRefusal => switch (this) {
        EmailSaveResult.verificationSent ||
        EmailSaveResult.savedUnverified =>
          null,
        EmailSaveResult.invalid => 'it isn\'t a valid address',
        EmailSaveResult.tooSoon => 'it changed too recently',
        EmailSaveResult.banned => 'it can\'t be used here',
        EmailSaveResult.disposable => 'it\'s a temporary email service',
        EmailSaveResult.taken => 'another account has it',
      };
}

/// An email address attached to the account, for recovery and security.
///
/// The phone number is the identity here; an email is the second way back in
/// if that number is lost, and where a "new device signed in" notice would go.
/// It's held on the device (and in the encrypted cloud sync), never in a
/// server table of our own.
///
/// Confirming the address needs Supabase Auth: with a signed-in session,
/// `updateUser` makes Supabase send its own confirmation link, and the address
/// counts as verified once that session reports it confirmed. Without a
/// session (this project runs with `REQUIRE_OTP` off) the address is still
/// stored and used — it's just flagged unverified, which the UI says plainly
/// rather than implying a check that never happened.
class AccountEmail extends ChangeNotifier {
  AccountEmail._();
  static final AccountEmail instance = AccountEmail._();

  static const _kEmail = 'account_email_v1';
  static const _kVerified = 'account_email_verified_v1';
  static const _kChangedAt = 'account_email_changed_at_v1';

  /// Changing an EXISTING address (or removing it — the remove-then-add
  /// two-step would dodge the clock) waits this long. First set is free.
  static const Duration changeCooldown = Duration(days: 30);

  SharedPreferences? _prefs;
  String _email = '';
  bool _verified = false;
  DateTime? _changedAt;

  /// How much longer the address is locked, or zero when it may change.
  Duration changeCooldownLeft() {
    final at = _changedAt;
    if (at == null) return Duration.zero;
    final left = changeCooldown - DateTime.now().difference(at);
    return left.isNegative ? Duration.zero : left;
  }

  @visibleForTesting
  set debugChangedAt(DateTime? at) => _changedAt = at;

  /// The address on the account, or empty when none is set.
  String get email => _email;

  /// Whether the address has been confirmed by the auth provider.
  bool get isVerified => _verified;

  /// True once an address is attached, verified or not.
  bool get isSet => _email.isNotEmpty;

  /// A deliberately permissive check — enough structure to be a real address,
  /// without the false rejections a stricter pattern causes for valid ones.
  static bool isValid(String raw) {
    final e = raw.trim();
    if (e.length < 5 || e.length > 254) return false;
    return RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$').hasMatch(e);
  }

  /// Hides the middle of the local part: "ada@example.com" → "a••@example.com".
  /// Used wherever the address is shown to confirm an action, so a shoulder
  /// surfer doesn't get a working address.
  static String mask(String raw) {
    final e = raw.trim();
    final at = e.indexOf('@');
    if (at <= 0) return e;
    final local = e.substring(0, at);
    final domain = e.substring(at);
    if (local.length <= 2) return '${local[0]}•$domain';
    return '${local[0]}${'•' * (local.length - 2)}${local[local.length - 1]}'
        '$domain';
  }

  Future<void> load() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      _email = prefs.getString(_kEmail) ?? '';
      _verified = prefs.getBool(_kVerified) ?? false;
      _changedAt = DateTime.tryParse(prefs.getString(_kChangedAt) ?? '');
      // An existing recovery email set through two-step counts as the
      // account email, so the two aren't kept as separate half-answers.
      if (_email.isEmpty && TwoStepVerification.instance.email.isNotEmpty) {
        _email = TwoStepVerification.instance.email;
        await prefs.setString(_kEmail, _email);
      }
      await refreshVerification();
      notifyListeners();
    } catch (_) {}
  }

  /// Attaches [raw] to the account and asks the auth provider to confirm it.
  Future<EmailSaveResult> setEmail(String raw) async {
    final email = raw.trim();
    if (!isValid(email)) return EmailSaveResult.invalid;
    // Checked before anything leaves the device: this one needs no round trip,
    // and refusing locally means a throwaway address never gets as far as
    // being claimed or mailed. Forwarding aliases (Apple Hide My Email,
    // SimpleLogin, addy.io) deliberately pass — see disposable_emails.dart.
    if (DisposableEmails.isDisposable(email)) {
      return EmailSaveResult.disposable;
    }
    // A moderator can ban an email so it can't be attached to any account.
    if (await PlatformModeration.instance.isEmailBanned(email)) {
      return EmailSaveResult.banned;
    }
    // Already somebody else's recovery address — refused before anything is
    // saved or sent, so no confirmation mail reaches a stranger's inbox.
    if (await AccountService.instance.isEmailTaken(email)) {
      return EmailSaveResult.taken;
    }
    final changingExisting =
        _email.isNotEmpty && email.toLowerCase() != _email.toLowerCase();
    if (changingExisting && changeCooldownLeft() > Duration.zero) {
      return EmailSaveResult.tooSoon;
    }
    if (changingExisting) await _recordChange();

    _email = email;
    _verified = false;
    await _persist();
    // Keep two-step's recovery address in step — one email, one place to
    // change it.
    await TwoStepVerification.instance.setEmail(email);
    // Hold the address against this account so nobody else can attach it.
    // Only the hash travels — the server never sees the address itself.
    unawaited(AccountService.instance.claimEmail(email));
    notifyListeners();

    if (await _requestVerification(email)) {
      return EmailSaveResult.verificationSent;
    }
    return EmailSaveResult.savedUnverified;
  }

  /// Removes the address from the account. Refused (false) while the
  /// change cooldown runs — removing is changing, as far as the clock is
  /// concerned, or remove-then-add would dodge it.
  Future<bool> clear() async {
    if (_email.isNotEmpty && changeCooldownLeft() > Duration.zero) {
      return false;
    }
    if (_email.isNotEmpty) await _recordChange();
    _email = '';
    _verified = false;
    await _persist();
    await TwoStepVerification.instance.setEmail('');
    // Give the address back, or removing it here would leave it locked
    // against every account including this one.
    unawaited(AccountService.instance.releaseEmail());
    notifyListeners();
    return true;
  }

  Future<void> _recordChange() async {
    _changedAt = DateTime.now();
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_kChangedAt, _changedAt!.toIso8601String());
  }

  /// Re-sends the confirmation email. Returns true when one went out.
  Future<bool> resendVerification() =>
      _email.isEmpty ? Future.value(false) : _requestVerification(_email);

  /// Where the confirmation link lands.
  ///
  /// Passed explicitly because Supabase otherwise falls back to the project's
  /// Site URL, which is `http://localhost:3000` until somebody changes it —
  /// so the link in the email opened a dead page on the reader's own phone.
  ///
  /// It still has to be on the project's Redirect URLs allow-list; Supabase
  /// silently uses the Site URL for anything that isn't.
  /// Defaults to the `pages` Edge Function on the same Supabase project, so
  /// the page is up whenever the backend is. It used to be a file on GitHub
  /// Pages, which is republished as the repository's README for minutes after
  /// every push — and this is the one link the app cannot rescue, because it
  /// is opened in a browser on whatever device read the email.
  static String get emailRedirectUrl =>
      _redirectOverride.isNotEmpty ? _redirectOverride : AppPages.emailConfirmed;

  static const String _redirectOverride =
      String.fromEnvironment('EMAIL_REDIRECT_URL', defaultValue: '');

  /// Re-reads the signed-in user to see whether the address has since been
  /// confirmed. Safe to call on launch and on pull-to-refresh.
  Future<void> refreshVerification() async {
    if (!RelayConfig.isEnabled) return;
    try {
      final auth = Supabase.instance.client.auth;
      if (auth.currentUser == null) return;
      // Ask the server rather than reading the cached session. The link is
      // clicked in a browser, often on another device, so the copy of the
      // user this app is holding has no idea it happened — which left the
      // address reading "unverified" forever after a successful confirm.
      User? user;
      try {
        user = (await auth.getUser()).user;
      } catch (_) {
        user = auth.currentUser; // offline: fall back to what we have
      }
      if (user == null) return;
      // A reinstall (or an account switch's wipe) empties the LOCAL copy,
      // but the address lives on the auth user — adopt it back, verified
      // state and all, instead of asking somebody to re-verify an email
      // the server already confirmed.
      final serverEmail = (user.email ?? '').trim();
      if (_email.isEmpty && serverEmail.isNotEmpty) {
        _email = serverEmail;
        _verified = user.emailConfirmedAt != null;
        await _persist();
        await TwoStepVerification.instance.setEmail(_email);
        notifyListeners();
        return;
      }
      if (_email.isEmpty) return;
      final confirmed = user.emailConfirmedAt != null &&
          serverEmail.toLowerCase() == _email.toLowerCase();
      if (confirmed != _verified) {
        _verified = confirmed;
        await _persist();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Asks Supabase to send its confirmation email. Only possible with a real
  /// session — otherwise there's no account for the address to attach to.
  Future<bool> _requestVerification(String email) async {
    if (!RelayConfig.isEnabled) return false;
    try {
      final auth = Supabase.instance.client.auth;
      if (auth.currentUser == null) return false;
      await auth.updateUser(
        UserAttributes(email: email),
        emailRedirectTo: emailRedirectUrl,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Marks the address on this account confirmed.
  ///
  /// Called by [EmailVerifyScreen] once the real upgrade has landed — the
  /// emailed code checked, the account code stamped into the auth user, and
  /// the session refreshed. There is no server row of the app's own for a
  /// numberless account's verification state; like the address itself (see
  /// this class's own doc comment) it is held on the device.
  ///
  /// This replaced a send-a-code/verify pair that lived here and signed
  /// straight back out afterwards, which left the address "confirmed" and
  /// USELESS as a way to sign in. There is one confirmation flow now, and it
  /// is the one that leaves a way back into the account.
  Future<void> markVerified() async {
    if (_email.isEmpty || _verified) return;
    _verified = true;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (_email.isEmpty) {
        await prefs.remove(_kEmail);
        await prefs.remove(_kVerified);
      } else {
        await prefs.setString(_kEmail, _email);
        await prefs.setBool(_kVerified, _verified);
      }
    } catch (_) {}
  }

  /// The account email as a portable document, for the encrypted cloud sync.
  Map<String, dynamic> toJson() => {'email': _email, 'verified': _verified};

  void hydrate(Map<String, dynamic> json) {
    final email = (json['email'] as String?)?.trim() ?? '';
    if (email.isEmpty || email == _email) return;
    _email = email;
    _verified = json['verified'] == true;
    _persist();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _email = '';
    _verified = false;
    _changedAt = null;
    _prefs = null;
    notifyListeners();
  }
}
