import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';

/// The wall a name-only account meets when its free trial runs out: full access
/// during the trial, then this — verify a phone number to KEEP USING the app
/// and KEEP the account. Verifying is an in-place upgrade
/// ([Session.attachNumberInPlace]); the on-device data (chats, servers, notes)
/// stays exactly where it is. The only other way out is signing out.
///
/// Shown app-wide by an overlay in main.dart while [Session.numberlessLocked],
/// so there is no screen behind it to slip to.
class NumberlessLockScreen extends StatefulWidget {
  const NumberlessLockScreen({super.key});

  @override
  State<NumberlessLockScreen> createState() => _NumberlessLockScreenState();
}

class _NumberlessLockScreenState extends State<NumberlessLockScreen> {
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
      await _run(() => Session.instance.attachNumberInPlace(_fullPhone));
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_clock_outlined,
                    size: 54, color: AppColors.accentOn(context)),
                const SizedBox(height: 18),
                const Text('Your free trial has ended',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Text(
                  'You\'ve been using OkayMessenger on a name-only account. To '
                  'keep using it — and to keep this account — verify a phone '
                  'number. Everything on this device stays: your chats, servers '
                  'and notes are kept.',
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
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : Text(_codeSent ? 'Verify & keep my account' : 'Continue'),
                ),
                const SizedBox(height: 6),
                Text(
                  'Adding a number also unlocks the parts a name-only account '
                  'can\'t use — the wallet, posting, and the marketplace.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.4, color: subtle),
                ),
                const SizedBox(height: 18),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Sign out?'),
                              content: const Text(
                                  'A name-only account can\'t be recovered — '
                                  'signing out ends it and its data for good.'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Sign out')),
                              ],
                            ),
                          );
                          if (ok == true) await Session.instance.signOut();
                        },
                  child: const Text('Sign out instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
