import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/parental_controls.dart';
import '../theme/app_theme.dart';

/// Settings → Privacy & security → Parental controls.
///
/// The toggles live BEHIND the PIN: the screen asks before showing them,
/// or a child could simply switch everything back on. First open (no PIN
/// yet) is the setup path.
class ParentalControlsScreen extends StatefulWidget {
  const ParentalControlsScreen({super.key});

  @override
  State<ParentalControlsScreen> createState() =>
      _ParentalControlsScreenState();
}

class _ParentalControlsScreenState extends State<ParentalControlsScreen> {
  bool _unlocked = false;

  static const _labels = {
    ParentalRestriction.payments: (
      'Payments',
      'Wallet, Send money and Sparks — every way money leaves'
    ),
    ParentalRestriction.marketplace: (
      'Marketplace',
      'Buying, selling and listings'
    ),
    ParentalRestriction.publicFeed: (
      'Public newsfeed',
      'The world-readable timeline, posts by strangers included'
    ),
    ParentalRestriction.servers: (
      'Servers',
      'Community channels, feeds and forums'
    ),
  };

  @override
  Widget build(BuildContext context) {
    final controls = ParentalControls.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Parental controls')),
      body: ListenableBuilder(
        listenable: controls,
        builder: (context, _) {
          if (!controls.enabled.value) return _setup(context);
          if (!_unlocked) return _locked(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text(
                'What is turned off on this phone. These apply to whoever '
                'is signed in — switching accounts does not lift them.',
                style: TextStyle(
                    fontSize: 13.5, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 8),
              for (final e in _labels.entries)
                SwitchListTile(
                  title: Text(e.value.$1),
                  subtitle: Text(e.value.$2),
                  value: controls.blocks(e.key),
                  onChanged: (on) => controls.setBlocked(e.key, on),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await controls.disable();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Parental controls turned off')));
                  }
                },
                child: const Text('Turn off parental controls',
                    style: TextStyle(color: Colors.red)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _setup(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.family_restroom, size: 54),
            const SizedBox(height: 18),
            const Text('Set up parental controls',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              'Choose a parent PIN, then pick what this phone can\'t use — '
              'payments, the marketplace, the public feed or servers. The '
              'PIN is separate from every other code in the app, and '
              'everything stays on this phone.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  color: AppColors.subtle(context)),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => _choosePin(context),
              child: const Text('Choose a parent PIN'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locked(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 54),
            const SizedBox(height: 18),
            const Text('Parent PIN required',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => _askPin(context),
              child: const Text('Enter PIN'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _askPin(BuildContext context) async {
    final pin = await _pinPrompt(context, title: 'Parent PIN');
    if (pin == null || !mounted) return;
    final controls = ParentalControls.instance;
    final locked = controls.lockedFor;
    if (locked > Duration.zero) {
      _say('Too many wrong PINs. Try again in ${locked.inSeconds + 1}s.');
      return;
    }
    if (controls.verify(pin)) {
      setState(() => _unlocked = true);
    } else {
      final now = controls.lockedFor;
      _say(now > Duration.zero
          ? 'Too many wrong PINs. Try again in ${now.inSeconds + 1}s.'
          : 'Wrong PIN.');
    }
  }

  Future<void> _choosePin(BuildContext context) async {
    final pin = await _pinPrompt(context, title: 'Choose a parent PIN');
    if (pin == null || !mounted) return;
    if (!ParentalControls.isValidPin(pin)) {
      _say('The PIN is 4–6 digits.');
      return;
    }
    final again = await _pinPrompt(this.context, title: 'Type it again');
    if (again == null || !mounted) return;
    if (again != pin) {
      _say('The PINs didn\'t match.');
      return;
    }
    await ParentalControls.instance.setPin(pin);
    setState(() => _unlocked = true);
  }

  void _say(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));

  Future<String?> _pinPrompt(BuildContext context,
      {required String title}) {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 6,
          decoration: const InputDecoration(
              counterText: '', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(field.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
