import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/user.dart';
import '../relay/relay_config.dart';
import '../state/account_service.dart';
import '../state/call_log.dart';
import '../state/call_service.dart' show CallService;
import '../state/contacts_sync.dart';
import '../state/incoming_links.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';

/// A phone-style dial pad: type any number and call it. Numbers on
/// OkayMessenger get the encrypted in-app call; everyone else is handed to
/// the phone's own dialer (or FaceTime for video), so dialing works for
/// people outside the app too.
class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key});

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> {
  String _number = '';
  bool _placing = false;

  static const _keys = [
    ('1', ''),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', ''),
    ('0', '+'),
    ('#', ''),
  ];

  void _tap(String d) {
    HapticFeedback.selectionClick();
    setState(() => _number += d);
  }

  void _backspace() {
    if (_number.isEmpty) return;
    setState(() => _number = _number.substring(0, _number.length - 1));
  }

  Future<void> _call({required bool video}) async {
    final raw = _number.replaceAll(RegExp(r'[^\d+*#]'), '');
    if (raw.replaceAll(RegExp(r'\D'), '').length < 3 || _placing) return;
    setState(() => _placing = true);
    // Is this number on OkayMessenger? The directory is asked with hashes,
    // never the raw number.
    AppUser? onApp;
    if (RelayConfig.isEnabled) {
      try {
        final matches = await AccountService.instance.lookupByPhoneHashes(
            ContactsSync.hashesFor([raw],
                countryCode: ContactsSync.defaultCountryCode()));
        if (matches.isNotEmpty) onApp = matches.first;
      } catch (_) {
        // Offline or no directory: treat as outside the app.
      }
    }
    if (!mounted) return;
    setState(() => _placing = false);
    if (onApp != null) {
      Navigator.of(context).pop();
      CallService.instance.startOutgoing(onApp, video: video);
      return;
    }
    // Outside the app: hand the number to the system so the call still
    // happens — cellular for voice, FaceTime for video.
    final handedOff = await IncomingLinks.systemDial(raw, video: video);
    if (!mounted) return;
    if (handedOff) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("This number isn't on OkayMessenger, and no phone "
              'app is available to call it.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCall =
        _number.replaceAll(RegExp(r'\D'), '').length >= 3 && !_placing;
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: const SidebarButton(),
          title: const Text('Dial a number')),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            // Quick redial: the last few people/numbers called.
            _RecentsRow(onPick: (phone) => setState(() => _number = phone)),
            const Spacer(),
            // The number being typed, large and centred like a phone app.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _number.isEmpty ? 'Enter a number' : _number,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _number.isEmpty ? 20 : 32,
                        fontWeight: FontWeight.w600,
                        color: _number.isEmpty ? Colors.grey.shade500 : null,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (_number.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.backspace_outlined),
                      tooltip: 'Delete',
                      onPressed: _backspace,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // The 4x3 keypad.
            for (var row = 0; row < 4; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var col = 0; col < 3; col++)
                      _DialKey(
                        digit: _keys[row * 3 + col].$1,
                        letters: _keys[row * 3 + col].$2,
                        onTap: _tap,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              _placing
                  ? 'Checking the number…'
                  : 'People on OkayMessenger ring here — everyone else '
                      'rings through your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: Icons.videocam,
                  color: Colors.blueGrey,
                  tooltip: 'Video call',
                  enabled: canCall,
                  onTap: () => _call(video: true),
                ),
                const SizedBox(width: 24),
                _CallButton(
                  icon: Icons.call,
                  color: AppColors.accentOn(context),
                  tooltip: 'Call',
                  enabled: canCall,
                  big: true,
                  onTap: () => _call(video: false),
                ),
                const SizedBox(width: 24 + 56),
              ],
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

/// The last few distinct numbers from the call history, as one-tap chips
/// that fill the dial pad for a quick redial.
class _RecentsRow extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _RecentsRow({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final recents = <({String label, String phone})>[];
    for (final r in CallLog.instance.records) {
      final phone = r.user.phone;
      if (phone.isEmpty || !seen.add(phone)) continue;
      recents.add((label: r.user.name, phone: phone));
      if (recents.length == 3) break;
    }
    if (recents.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          for (final r in recents)
            ActionChip(
              avatar: const Icon(Icons.history, size: 16),
              label: Text(r.label, overflow: TextOverflow.ellipsis),
              onPressed: () => onPick(r.phone),
            ),
        ],
      ),
    );
  }
}

class _DialKey extends StatelessWidget {
  final String digit;
  final String letters;
  final ValueChanged<String> onTap;
  const _DialKey(
      {required this.digit, required this.letters, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: isDark ? const Color(0xFF22252B) : const Color(0xFFF0F2F3),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onTap(digit),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(digit,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w600)),
                if (letters.isNotEmpty)
                  Text(letters,
                      style: TextStyle(
                          fontSize: 9.5,
                          letterSpacing: 1.2,
                          color: Colors.grey.shade500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final bool enabled;
  final bool big;
  final VoidCallback onTap;
  const _CallButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = big ? 68.0 : 56.0;
    return Material(
      color: enabled ? color : Colors.grey.shade400,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: big ? 30 : 24),
        ),
      ),
    );
  }
}
