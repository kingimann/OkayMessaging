import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';
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

  SharedPreferences? _prefs;
  String _email = '';
  bool _verified = false;

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

    _email = email;
    _verified = false;
    await _persist();
    // Keep two-step's recovery address in step — one email, one place to
    // change it.
    await TwoStepVerification.instance.setEmail(email);
    notifyListeners();

    if (await _requestVerification(email)) {
      return EmailSaveResult.verificationSent;
    }
    return EmailSaveResult.savedUnverified;
  }

  /// Removes the address from the account.
  Future<void> clear() async {
    _email = '';
    _verified = false;
    await _persist();
    await TwoStepVerification.instance.setEmail('');
    notifyListeners();
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
  static const String emailRedirectUrl = String.fromEnvironment(
    'EMAIL_REDIRECT_URL',
    defaultValue:
        'https://kingimann.github.io/OkayMessaging/email-confirmed.html',
  );

  /// Re-reads the signed-in user to see whether the address has since been
  /// confirmed. Safe to call on launch and on pull-to-refresh.
  Future<void> refreshVerification() async {
    if (_email.isEmpty || !RelayConfig.isEnabled) return;
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
      final confirmed = user.emailConfirmedAt != null &&
          (user.email ?? '').toLowerCase() == _email.toLowerCase();
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
    _prefs = null;
    notifyListeners();
  }
}
