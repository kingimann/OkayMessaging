import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/user.dart';
import '../relay/relay_config.dart';
import '../state/account_service.dart';
import '../state/call_log.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../state/contacts_sync.dart';
import '../state/incoming_links.dart';
import '../theme/app_theme.dart';
import '../util/phone_format.dart';
import '../util/phone_match.dart';

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
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'),
    ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'),
    ('*', ''), ('0', '+'), ('#', ''),
  ];

  void _tap(String d) {
    HapticFeedback.selectionClick();
    setState(() => _number += d);
  }

  /// Long-pressing 0 types '+', the way every phone dial pad works.
  ///
  /// The '+' has been printed under the 0 key since this screen was written
  /// and there was nothing behind it: [_tap] only ever appended the digit, so
  /// the one character an international number cannot be dialled without was
  /// unreachable while being advertised.
  ///
  /// Only at the FRONT, because that is the only place it means anything —
  /// '+' is "what follows is a country code", so a second one, or one in the
  /// middle, would just be a character the network refuses.
  void _plus() {
    if (_number.isNotEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _number = '+');
  }

  void _backspace() {
    if (_number.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _number = _number.substring(0, _number.length - 1));
  }

  /// Long-pressing backspace clears the lot — a mistyped eleven-digit number
  /// took eleven taps to take back.
  void _clear() {
    if (_number.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _number = '');
  }

  /// Pastes a number from the clipboard, keeping only what can be dialled.
  ///
  /// **Read only when the button is pressed, never to decide whether to SHOW
  /// the button.** iOS and Android dialers peek at the clipboard on open so
  /// they can offer a paste chip only when there is a number on it; that is a
  /// silent read of whatever the person last copied — a password, a message —
  /// by a screen they only opened to make a call. The button is always there
  /// instead, and says so when the clipboard holds nothing dialable.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    // Keep the leading '+' if there is one, then digits and DTMF only.
    final plus = text.trimLeft().startsWith('+');
    final rest = text.replaceAll(RegExp(r'[^\d*#]'), '');
    if (!mounted) return;
    if (rest.replaceAll(RegExp(r'\D'), '').length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing on the clipboard looks like a number.')));
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _number = plus ? '+$rest' : rest);
  }

  /// The contact this number belongs to, resolved from THIS DEVICE's own
  /// chats and nothing else — no directory lookup, so it costs no network and
  /// tells the server nothing about what is being typed. A number you have
  /// never spoken to stays a number, which is the honest answer.
  AppUser? get _knownContact {
    if (_number.replaceAll(RegExp(r'\D'), '').length < 7) return null;
    for (final chat in ChatStore.instance.allChats) {
      final contact = chat.contact;
      if (contact.isGroup || contact.phone.isEmpty) continue;
      if (samePhoneNumber(contact.phone, _number)) return contact;
    }
    return null;
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

  /// The gap between the two call buttons, named because the same length is
  /// mirrored on the right to keep the big one centred on screen.
  static const double _callGap = 24;

  @override
  Widget build(BuildContext context) {
    final canCall =
        _number.replaceAll(RegExp(r'\D'), '').length >= 3 && !_placing;
    final known = _knownContact;
    return Scaffold(
      appBar: AppBar(title: const Text('Dial a number')),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            // Quick redial: the last few people/numbers called.
            _RecentsRow(onPick: (phone) => setState(() => _number = phone)),
            const SizedBox(height: 12),
            _NumberDisplay(
              number: _number,
              contactName: known?.name ?? '',
              onBackspace: _backspace,
              onClear: _clear,
              onPaste: _paste,
            ),
            const SizedBox(height: 14),
            // The 4x3 keypad. `Flexible` + `scaleDown` is what keeps it on a
            // 320x568 phone (SE 1st-gen, still supported): at a fixed 72pt it
            // overflowed the column by 33 points, and a keypad that overflows
            // is a bottom row you cannot press. It shrinks in proportion —
            // text and tap targets together — rather than clipping, and only
            // on a screen short enough to need it.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var row = 0; row < 4; row++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var col = 0; col < 3; col++)
                              _DialKey(
                                digit: _keys[row * 3 + col].$1,
                                letters: _keys[row * 3 + col].$2,
                                onTap: _tap,
                                // Only the 0 key has a long press, and it is
                                // the '+' its own label already promises.
                                onLongPress:
                                    _keys[row * 3 + col].$1 == '0' ? _plus : null,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _placing
                  ? 'Checking the number…'
                  : 'People on OkayMessenger ring here — everyone else '
                      'rings through your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.subtle(context)),
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
                const SizedBox(width: _callGap),
                _CallButton(
                  icon: Icons.call,
                  color: AppColors.accentOn(context),
                  tooltip: 'Call',
                  enabled: canCall,
                  big: true,
                  onTap: () => _call(video: false),
                ),
                // The video button's own width plus the gap, mirrored, so the
                // call button lands in the middle of the screen rather than
                // the middle of the pair.
                const SizedBox(width: _callGap + _CallButton.plainSize),
              ],
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

/// The number being typed, with the contact it belongs to when this device
/// happens to know, and the three things you can do to it.
class _NumberDisplay extends StatelessWidget {
  final String number;
  final String contactName;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onPaste;
  const _NumberDisplay({
    required this.number,
    required this.contactName,
    required this.onBackspace,
    required this.onClear,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    final empty = number.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.content_paste_outlined),
                tooltip: 'Paste a number',
                onPressed: onPaste,
              ),
              Expanded(
                // Long numbers keep their TAIL on screen. A plain ellipsis
                // hides the end, which on a dial pad is the digits that were
                // just pressed — you could not see what you had typed.
                // `reverse` pins to the end; the `minWidth` is what keeps a
                // short number centred rather than shoved against the right.
                child: LayoutBuilder(
                  builder: (context, c) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: c.maxWidth),
                      child: Center(
                        child: Text(
                          empty ? 'Enter a number' : formatDialedNumber(number),
                          style: TextStyle(
                            fontSize: empty ? 20 : 32,
                            fontWeight: FontWeight.w600,
                            color: empty ? AppColors.subtle(context) : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Held open when there is nothing to delete, so typing the
              // first digit does not shift the number sideways.
              SizedBox(
                width: 48,
                child: empty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.backspace_outlined),
                        tooltip: 'Delete — hold to clear',
                        onPressed: onBackspace,
                        onLongPress: onClear,
                      ),
              ),
            ],
          ),
          if (contactName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                contactName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14, color: AppColors.subtle(context)),
              ),
            ),
        ],
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
  final VoidCallback? onLongPress;
  const _DialKey(
      {required this.digit,
      required this.letters,
      required this.onTap,
      this.onLongPress});

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
          onLongPress: onLongPress,
          child: SizedBox(
            width: 72,
            height: 72,
            // One label for the key, so a screen reader says "2, A B C" once
            // instead of reading two unrelated pieces of text in a column.
            child: Semantics(
              button: true,
              label: letters.isEmpty ? digit : '$digit, $letters',
              excludeSemantics: true,
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
                            color: AppColors.subtle(context))),
                ],
              ),
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

  /// The width of the ordinary (not [big]) button — read by the dial pad to
  /// mirror it as empty space on the other side of the call button.
  static const double plainSize = 56;

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
    final size = big ? 68.0 : plainSize;
    return Material(
      color: enabled ? color : Colors.grey.shade400,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: size,
          height: size,
          child:
              Icon(icon, color: Colors.white, size: big ? 30 : 24),
        ),
      ),
    );
  }
}
