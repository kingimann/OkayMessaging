import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/account_email.dart';
import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import 'numberless_verify_screen.dart';

/// Earns a name-only account a real server session with an EMAIL instead of a
/// phone number, in place — the twin of [NumberlessVerifyScreen], reached from
/// the same gates.
///
/// **Why an email needs a whole flow rather than a checkbox.** Adding an
/// address to a name-only account has never verified it and could not: the
/// app asks Supabase to send its confirmation through `updateUser`, which
/// needs a session, and a name-only account has none. So the address was
/// stored and flagged unverified, which is honest but unlocks nothing. This
/// screen inverts it — the emailed code IS the sign-in, so confirming the
/// address and gaining the session are the same act.
///
/// On success the account keeps every bit of its on-device data
/// ([Session.attachNumberInPlace]) and gains the phone CLAIM that every RLS
/// policy and `callerPhone()` require. Pops true when the upgrade lands.
class EmailVerifyScreen extends StatefulWidget {
  const EmailVerifyScreen({super.key, this.sendCode, this.verify});

  /// Sends the one-time code. Null uses the real
  /// [AccountService.sendEmailSignupCode]. Injected for the same reason
  /// [verify] is: both halves talk to Supabase Auth, which the suite cannot
  /// stand up, and a screen that can only be tested up to its first network
  /// call is a screen whose success path is never exercised.
  final Future<void> Function(String email)? sendCode;

  /// Runs the confirm step, so a test can drive the screen without standing
  /// up Supabase Auth. Null uses the real chain
  /// ([AccountService.verifyEmailForNumberless]); returns the stamped account
  /// code, or null when the account was not upgraded.
  final Future<String?> Function(String email, String code)? verify;

  /// What went wrong, in a sentence somebody can act on.
  ///
  /// Deliberately its own list rather than reusing the phone screen's: the
  /// failures are different (there is no country to get wrong, and there IS a
  /// stamp step that can fail on its own), and a shared function would have
  /// to answer for both with sentences that fit neither.
  static String readableError(Object e) {
    final raw = e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('invalid token') ||
        lower.contains('expired') ||
        lower.contains('otp_expired')) {
      return 'That code is wrong or has expired. Ask for a new one.';
    }
    if (lower.contains('rate limit') || lower.contains('too many')) {
      // Deliberately NOT "wait a minute": the cap is per project and per
      // hour, not per attempt, so a minute is usually not enough and saying
      // so sends somebody into a retry loop that cannot succeed. It also
      // names the exit that is not rate-limited at all.
      return 'Too many code requests just now. Try again later, or verify a '
          'phone number instead.';
    }
    if (lower.contains('signups not allowed') ||
        lower.contains('email_provider_disabled')) {
      return 'Email sign-in isn\'t switched on for this app yet.';
    }
    final s = raw.replaceFirst(RegExp(r'^[A-Za-z]*(Error|Exception):\s*'), '');
    return s.isEmpty ? 'That didn\'t work.' : s;
  }

  @override
  State<EmailVerifyScreen> createState() => _EmailVerifyScreenState();
}

class _EmailVerifyScreenState extends State<EmailVerifyScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill whatever address the account already carries — most people
    // reaching this screen added one already and were told it was unverified.
    _email.text = AccountEmail.instance.email;
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!AccountEmail.isValid(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final send =
          widget.sendCode ?? AccountService.instance.sendEmailSignupCode;
      await send(email);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = EmailVerifyScreen.readableError(e);
      });
    }
  }

  Future<void> _confirm() async {
    final email = _email.text.trim();
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the code from your email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final run = widget.verify ??
          AccountService.instance.verifyEmailForNumberless;
      final stamped = await run(email, code);
      if (!mounted) return;
      if (stamped == null || stamped.isEmpty) {
        // The code was right — there is a session now — but the account was
        // not upgraded. Its own sentence rather than "wrong code", which
        // would send somebody to re-check six digits that were fine, and it
        // NAMES the reason the server gave: this step has six different ways
        // to refuse, and one sentence for all of them is what made this
        // undebuggable from a phone.
        final why = AccountService.instance.lastEmailUpgradeError;
        setState(() {
          _busy = false;
          _error = 'Your email is confirmed, but this account could not be '
              'upgraded.${why.isEmpty ? '' : ' The server said: $why.'}';
        });
        return;
      }
      // In place: same account, every chat, server and note kept, and the
      // 14-day name-only clock stops here for good.
      await Session.instance.attachNumberInPlace(stamped);
      await AccountEmail.instance.refreshVerification();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = EmailVerifyScreen.readableError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your email')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        children: [
          Text(
            _codeSent
                ? 'Enter the code we emailed you.'
                : 'Use an email address instead of a phone number. We\'ll '
                    'send you a code to confirm it.',
            style: const TextStyle(fontSize: 15.5, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            'Your account and everything on this device are kept.',
            style: TextStyle(
                fontSize: 13.5, height: 1.4, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _email,
            enabled: !_codeSent && !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _code,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                labelText: 'Code',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _busy ? null : (_codeSent ? _confirm : _send),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
            child: Text(_codeSent ? 'Confirm' : 'Send code'),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _send,
              child: const Text('Send another code'),
            ),
            // The way out when no code arrives at all — which is a delivery
            // problem on the sending side, invisible from here and not
            // something a retry fixes. A number is verified over a different
            // provider entirely, so it is unaffected by whatever is wrong
            // with the mail.
            TextButton(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute<bool>(
                            builder: (_) => const NumberlessVerifyScreen()),
                      ),
              child: const Text('No code? Verify a phone number instead'),
            ),
          ],
        ],
      ),
    );
  }
}
