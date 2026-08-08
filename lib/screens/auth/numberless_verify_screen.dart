import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';

/// Verifies a phone number for the CURRENT name-only account, IN PLACE — the
/// "verify to unlock this and keep your account" path, reached from the phone
/// gate rather than forced by any clock. On success the account keeps every bit
/// of its on-device data ([Session.attachNumberInPlace]) and gains the number
/// that lifts the tighter anti-spam limits and unlocks the server-session
/// features. Pops true when the upgrade lands.
class NumberlessVerifyScreen extends StatefulWidget {
  const NumberlessVerifyScreen({super.key});

  @override
  State<NumberlessVerifyScreen> createState() => _NumberlessVerifyScreenState();
}

class _NumberlessVerifyScreenState extends State<NumberlessVerifyScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _fullPhone {
    final t = _phone.text.trim();
    return t.startsWith('+') ? t : '+$t';
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      final s = e.toString().replaceFirst(RegExp(r'^[A-Za-z]*Error:\s*'), '');
      if (mounted) setState(() => _error = s.isEmpty ? 'That didn\'t work.' : s);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    if (_phone.text.trim().replaceAll(RegExp(r'\D'), '').length < 7) {
      setState(() => _error = 'Enter your phone number.');
      return;
    }
    // No SMS provider configured → verifying is just entering the number.
    if (!AccountService.isEnabled) {
      await _run(() async {
        await Session.instance.attachNumberInPlace(_fullPhone);
        if (mounted) Navigator.of(context).pop(true);
      });
      return;
    }
    if (!_codeSent) {
      await _run(() async {
        await AccountService.instance.sendCode(_fullPhone);
        if (mounted) setState(() => _codeSent = true);
      });
      return;
    }
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we sent you.');
      return;
    }
    await _run(() async {
      await AccountService.instance.verifyCode(_fullPhone, _code.text);
      // Keep the account's existing handle on the number where possible.
      final me = Session.instance.user.value;
      final handle = me?.username ?? '';
      if (handle.isNotEmpty) {
        try {
          await AccountService.instance.claimUsername(_fullPhone, handle);
        } catch (_) {}
      }
      await Session.instance.attachNumberInPlace(_fullPhone, username: handle);
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your number')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 54, color: AppColors.accentOn(context)),
                const SizedBox(height: 18),
                const Text('Verify your number',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Text(
                  'Adding a number lifts the anti-spam limits on a name-only '
                  'account and unlocks the parts it can\'t use — the wallet, '
                  'posting, and the marketplace. Your account and everything on '
                  'this device stay: chats, servers and notes are kept.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14.5, height: 1.45, color: subtle),
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _phone,
                  enabled: !_codeSent && !_busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    hintText: '+1 555 123 4567',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                if (_codeSent) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Verification code',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.sms_outlined),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13.5)),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _continue,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_codeSent ? 'Verify & keep my account' : 'Continue'),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
