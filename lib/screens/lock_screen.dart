import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_lock.dart';
import '../theme/app_theme.dart';

/// Full-screen PIN entry shown over the app while it's locked.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _controller = TextEditingController();
  bool _error = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (value.length < 4) return;
    if (!AppLock.instance.unlock(value)) {
      setState(() => _error = true);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : const Color(0xFF0F1419);
    return Scaffold(
      backgroundColor:
          isDark ? AppColors.darkSurface : AppColors.lightSurface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 56, color: ink),
              const SizedBox(height: 18),
              Text('Okay Messaging is locked',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: ink)),
              const SizedBox(height: 6),
              Text('Enter your PIN to unlock',
                  style: TextStyle(color: Colors.grey.shade600)),
              const SizedBox(height: 28),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 6,
                  style: const TextStyle(fontSize: 24, letterSpacing: 10),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '••••',
                    errorText: _error ? 'Incorrect PIN' : null,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_error) setState(() => _error = false);
                  },
                  onSubmitted: _submit,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _submit(_controller.text),
                style: FilledButton.styleFrom(
                  // Theme primary flips to near-white in dark mode, so the
                  // button stays visible in both themes.
                  backgroundColor: isDark ? Colors.white : ink,
                  foregroundColor: isDark ? Colors.black : Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                ),
                child: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
