import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../relay/relay_config.dart';
import '../state/account_service.dart';
import '../state/app_lock.dart';
import '../state/payment_security_store.dart';
import '../state/session.dart';
import '../state/two_step.dart';
import '../util/account_code.dart';

/// Asks for the second factor before a money send that left a trusted place.
///
/// The factor is a **texted code** to the account's own phone — the same SMS
/// check as signing in — so a phone in the wrong hands can't send money by
/// walking out the door, even if it's unlocked. Returns true only when the
/// code checks out.
///
/// When SMS can't run — no relay configured, or a numberless account with no
/// number to text — it falls back to the app's PIN (two-step, then app-lock).
/// If NEITHER is possible there is nothing to verify, so rather than wave the
/// send through it refuses.
Future<bool> requestPaymentStepUp(
  BuildContext context, {
  required StepUpDecision reason,
  required String recipientName,
}) async {
  final line = reason == StepUpDecision.locationUnknown
      ? "Your location couldn't be confirmed, so this send needs a code."
      : "You're away from your trusted places, so this send needs a code.";

  final phone = Session.instance.user.value?.phone ?? '';
  final canSms =
      RelayConfig.isEnabled && phone.isNotEmpty && !AccountCode.isCode(phone);

  if (canSms) {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SmsStepUpDialog(
        phone: phone,
        subtitle: line,
        recipientName: recipientName,
      ),
    );
    return ok ?? false;
  }
  return _pinFallback(context, line, recipientName);
}

/// Last-resort PIN check when a code can't be texted (offline, or a numberless
/// account). Uses two-step, then the app-lock PIN.
Future<bool> _pinFallback(
    BuildContext context, String subtitle, String recipientName) async {
  final twoStep = TwoStepVerification.instance;
  final appLock = AppLock.instance;
  final useTwoStep = twoStep.enabled.value;
  final useAppLock = !useTwoStep && appLock.enabled.value;
  if (!useTwoStep && !useAppLock) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Can\'t verify this send'),
        content: const Text(
            'Sending money from outside a trusted place needs a texted code, '
            'but your phone couldn\'t be reached. Check your connection and try '
            'again.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _PinStepUpDialog(
      subtitle:
          '$subtitle\n\n(No connection to text a code — using your PIN.)',
      recipientName: recipientName,
      verify: (pin) => useTwoStep ? twoStep.verify(pin) : appLock.unlock(pin),
      lockedFor: () => useTwoStep ? twoStep.lockedFor : Duration.zero,
    ),
  );
  return ok ?? false;
}

/// The account's phone, shown with only the last digits so a shoulder-surfer
/// learns nothing: `••• ••• 0123`.
String _maskPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 4) return phone;
  return '••• ••• ${digits.substring(digits.length - 4)}';
}

class _SmsStepUpDialog extends StatefulWidget {
  final String phone;
  final String subtitle;
  final String recipientName;

  const _SmsStepUpDialog({
    required this.phone,
    required this.subtitle,
    required this.recipientName,
  });

  @override
  State<_SmsStepUpDialog> createState() => _SmsStepUpDialogState();
}

class _SmsStepUpDialogState extends State<_SmsStepUpDialog> {
  final _field = TextEditingController();
  String? _error;
  bool _sending = false;
  bool _verifying = false;
  int _resendIn = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _send();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _resendIn = 30);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _resendIn--;
        if (_resendIn <= 0) t.cancel();
      });
    });
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await AccountService.instance.sendCode(widget.phone);
      if (!mounted) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Couldn\'t text a code — check your connection '
          'and tap Resend.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    if (_field.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we texted you.');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await AccountService.instance.verifyCode(widget.phone, _field.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'That code was wrong or expired.';
        _field.clear();
      });
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.sms_outlined, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text('Confirm it\'s you')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.subtitle}\n\nWe texted a code to '
              '${_maskPhone(widget.phone)}. Sending to '
              '${widget.recipientName.isEmpty ? 'this contact' : widget.recipientName}.'),
          const SizedBox(height: 16),
          TextField(
            controller: _field,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            decoration: InputDecoration(
              counterText: '',
              labelText: 'Texted code',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _verify(),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: (_sending || _resendIn > 0) ? null : _send,
              child: Text(_resendIn > 0
                  ? 'Resend code in ${_resendIn}s'
                  : (_sending ? 'Sending…' : 'Resend code')),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              _verifying ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Verify & send'),
        ),
      ],
    );
  }
}

class _PinStepUpDialog extends StatefulWidget {
  final String subtitle;
  final String recipientName;
  final bool Function(String pin) verify;
  final Duration Function() lockedFor;

  const _PinStepUpDialog({
    required this.subtitle,
    required this.recipientName,
    required this.verify,
    required this.lockedFor,
  });

  @override
  State<_PinStepUpDialog> createState() => _PinStepUpDialogState();
}

class _PinStepUpDialogState extends State<_PinStepUpDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final locked = widget.lockedFor();
    if (locked > Duration.zero) {
      setState(() => _error =
          'Too many wrong PINs. Try again in ${locked.inSeconds + 1}s.');
      return;
    }
    if (widget.verify(_field.text)) {
      Navigator.of(context).pop(true);
      return;
    }
    final now = widget.lockedFor();
    setState(() {
      _error = now > Duration.zero
          ? 'Too many wrong PINs. Try again in ${now.inSeconds + 1}s.'
          : 'Wrong PIN.';
      _field.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm it\'s you'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.subtitle),
          const SizedBox(height: 16),
          TextField(
            controller: _field,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            decoration: InputDecoration(
              counterText: '',
              labelText: 'Verification PIN',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Verify & send'),
        ),
      ],
    );
  }
}
