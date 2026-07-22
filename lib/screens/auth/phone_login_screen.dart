import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/session.dart';
import '../../theme/app_theme.dart';

/// Phone-number sign-in. The number is your identity and is stored only on
/// this device — there is no account server. (Real SMS verification could be
/// added here later with an OTP provider; for now entering the number signs
/// you in.)
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  String _dialCode = '+1';
  bool _busy = false;

  static const _dialCodes = ['+1', '+44', '+91', '+61', '+81', '+49', '+234'];

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final phone = '$_dialCode ${_phone.text.trim()}';
    await Session.instance.signIn(
      phone: phone,
      name: _name.text.trim(),
      username: _username.text.trim(),
    );
    // The auth gate reacts to the new session and shows the home screen.
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
                    'Enter your phone number to get started',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _username,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixText: '@',
                      helperText: 'Letters, numbers, _ and .',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final u = (v ?? '')
                          .trim()
                          .replaceFirst(RegExp(r'^@+'), '')
                          .toLowerCase();
                      if (u.isEmpty) return 'Choose a username';
                      if (!RegExp(r'^[a-z0-9_.]{3,}$').hasMatch(u)) {
                        return 'At least 3 letters/numbers';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 104,
                        child: DropdownButtonFormField<String>(
                          initialValue: _dialCode,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10),
                          ),
                          items: [
                            for (final code in _dialCodes)
                              DropdownMenuItem(value: code, child: Text(code)),
                          ],
                          onChanged: (v) =>
                              setState(() => _dialCode = v ?? _dialCode),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9 ]')),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Phone number',
                            border: OutlineInputBorder(),
                          ),
                          onFieldSubmitted: (_) => _continue(),
                          validator: (v) {
                            final digits =
                                (v ?? '').replaceAll(RegExp(r'\D'), '');
                            return digits.length < 6
                                ? 'Enter a valid number'
                                : null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _continue,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.tealGreenDark,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Continue'),
                  ),
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
}
