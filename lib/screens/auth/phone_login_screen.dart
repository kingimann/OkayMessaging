import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../state/two_step.dart';
import '../../theme/app_theme.dart';

/// Phone-number sign-in.
///
/// Two modes, chosen at build time by [AccountService.isEnabled]:
///
///  * **Local** (default) — the number is your identity, stored only on this
///    device; entering it signs you in instantly. No server involved.
///  * **Verified** (`--dart-define=REQUIRE_OTP=true`) — a real flow: enter
///    number → receive an SMS code → verify → choose a server-checked unique
///    username. Only the phone↔username mapping is ever stored on the server.
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

enum _Step { phone, code, username }

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  String _dialCode = '+1';
  bool _busy = false;
  _Step _step = _Step.phone;
  String? _error;

  static const _dialCodes = ['+1', '+44', '+91', '+61', '+81', '+49', '+234'];

  String get _fullPhone => '$_dialCode ${_phone.text.trim()}';

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  // --- Local (instant) sign-in -------------------------------------------

  Future<void> _continueLocal() async {
    if (!_formKey.currentState!.validate()) return;
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signIn(
      phone: _fullPhone,
      name: _name.text.trim(),
      username: _username.text.trim(),
    );
    // The auth gate reacts to the new session and shows the home screen.
  }

  /// When two-step verification is enabled on this device, require the PIN
  /// before completing sign-in. Returns true when allowed to proceed.
  Future<bool> _passTwoStep() async {
    if (!TwoStepVerification.instance.enabled.value) return true;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TwoStepPrompt(),
    );
    if (pin == null) return false;
    if (!TwoStepVerification.instance.verify(pin)) {
      if (mounted) {
        setState(() => _error = 'Incorrect two-step verification PIN.');
      }
      return false;
    }
    return true;
  }

  // --- Verified (SMS OTP + server username) ------------------------------

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('provider') || s.contains('not enabled') || s.contains('sms')) {
      return 'Couldn\'t send the code. The SMS provider may not be enabled yet.';
    }
    return 'Something went wrong. Please try again.';
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    await _run(() async {
      await AccountService.instance.sendCode(_fullPhone);
      if (mounted) setState(() => _step = _Step.code);
    });
  }

  Future<void> _verifyCode() async {
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we sent you.');
      return;
    }
    await _run(() async {
      await AccountService.instance.verifyCode(_fullPhone, _code.text);
      // Pre-fill any username already linked to this number.
      final existing =
          await AccountService.instance.usernameForPhone(_fullPhone);
      if (mounted) {
        setState(() {
          if (existing != null) _username.text = existing;
          _step = _Step.username;
        });
      }
    });
  }

  Future<void> _claimAndFinish() async {
    final u = AccountService.normalizeUsername(_username.text);
    if (!AccountService.isValidUsername(u)) {
      setState(() => _error = 'Choose a username (3+ letters, numbers, _ or .).');
      return;
    }
    if (!await _passTwoStep()) return;
    await _run(() async {
      final status =
          await AccountService.instance.checkUsername(_fullPhone, u);
      switch (status) {
        case UsernameStatus.taken:
          if (mounted) setState(() => _error = '@$u is already taken.');
          return;
        case UsernameStatus.invalid:
          if (mounted) setState(() => _error = 'That username isn\'t valid.');
          return;
        case UsernameStatus.available:
        case UsernameStatus.mine:
          // Claim is authoritative — the DB unique index rejects a name taken
          // between the check and now.
          final claimed =
              await AccountService.instance.claimUsername(_fullPhone, u);
          if (!claimed) {
            if (mounted) setState(() => _error = '@$u was just taken.');
            return;
          }
          await Session.instance.signIn(
            phone: _fullPhone,
            name: _name.text.trim(),
            username: u,
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.chat_bubble,
                      size: 64, color: AppColors.tealGreenDark),
                  const SizedBox(height: 12),
                  Text(
                    'Okay Messaging',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _subtitle(),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 28),
                  ..._body(),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Your number and messages stay on this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    if (!AccountService.isEnabled) {
      return 'Enter your phone number to get started';
    }
    switch (_step) {
      case _Step.phone:
        return 'Enter your phone number to get started';
      case _Step.code:
        return 'Enter the code we texted to $_fullPhone';
      case _Step.username:
        return 'Pick a username others can find you by';
    }
  }

  List<Widget> _body() {
    if (!AccountService.isEnabled) return _localFields();
    switch (_step) {
      case _Step.phone:
        return _phoneFields(onSubmit: _sendCode, cta: 'Send code');
      case _Step.code:
        return _codeFields();
      case _Step.username:
        return _usernameFields();
    }
  }

  // --- Field groups ------------------------------------------------------

  Widget _nameField() => TextFormField(
        controller: _name,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Your name',
          border: OutlineInputBorder(),
        ),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
      );

  Widget _usernameField() => TextFormField(
        controller: _username,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Username',
          prefixText: '@',
          helperText: 'Letters, numbers, _ and .',
          border: OutlineInputBorder(),
        ),
        validator: (v) {
          final u = AccountService.normalizeUsername(v ?? '');
          if (u.isEmpty) return 'Choose a username';
          if (!AccountService.isValidUsername(u)) {
            return 'At least 3 letters/numbers';
          }
          return null;
        },
      );

  Widget _phoneRow({VoidCallback? onSubmit}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: DropdownButtonFormField<String>(
              initialValue: _dialCode,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10),
              ),
              items: [
                for (final code in _dialCodes)
                  DropdownMenuItem(value: code, child: Text(code)),
              ],
              onChanged: (v) => setState(() => _dialCode = v ?? _dialCode),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone number',
                border: OutlineInputBorder(),
              ),
              onFieldSubmitted: (_) => onSubmit?.call(),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                return digits.length < 6 ? 'Enter a valid number' : null;
              },
            ),
          ),
        ],
      );

  Widget _cta(String label, VoidCallback onPressed) => FilledButton(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.tealGreenDark,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Text(label),
      );

  // Local instant flow: name + username + phone + Continue.
  List<Widget> _localFields() => [
        _nameField(),
        const SizedBox(height: 14),
        _usernameField(),
        const SizedBox(height: 14),
        _phoneRow(onSubmit: _continueLocal),
        const SizedBox(height: 24),
        _cta('Continue', _continueLocal),
      ];

  // Verified step 1: name + phone → Send code.
  List<Widget> _phoneFields({required VoidCallback onSubmit, required String cta}) =>
      [
        _nameField(),
        const SizedBox(height: 14),
        _phoneRow(onSubmit: onSubmit),
        const SizedBox(height: 24),
        _cta(cta, onSubmit),
      ];

  // Verified step 2: SMS code → Verify.
  List<Widget> _codeFields() => [
        TextFormField(
          controller: _code,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, letterSpacing: 8),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(
            labelText: 'Code',
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (_) => _verifyCode(),
        ),
        const SizedBox(height: 24),
        _cta('Verify', _verifyCode),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _step = _Step.phone),
          child: const Text('Change number'),
        ),
      ];

  // Verified step 3: username → Continue.
  List<Widget> _usernameFields() => [
        _usernameField(),
        const SizedBox(height: 24),
        _cta('Continue', _claimAndFinish),
      ];
}

/// Prompts for the two-step verification PIN during sign-in.
class _TwoStepPrompt extends StatefulWidget {
  const _TwoStepPrompt();

  @override
  State<_TwoStepPrompt> createState() => _TwoStepPromptState();
}

class _TwoStepPromptState extends State<_TwoStepPrompt> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email = TwoStepVerification.instance.email;
    return AlertDialog(
      title: const Text('Two-step verification'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter your 6-digit PIN to sign in.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            obscureText: true,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, letterSpacing: 6),
            decoration: const InputDecoration(counterText: ''),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          if (email.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Forgot it? Recovery email: $email',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(_pin.text),
            child: const Text('Verify')),
      ],
    );
  }
}
