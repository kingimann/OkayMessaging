import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';
import '../util/account_code.dart';
import '../widgets/user_avatar.dart';

/// Ways to be paid: your handle, a QR somebody scans to pay you, and a link
/// you can send. No money moves here — this is the side that FILLS the
/// wallet, so it needs no card and no charge, just a way for the other
/// person to find you and pay.
class ReceiveMoneyScreen extends StatelessWidget {
  const ReceiveMoneyScreen({super.key});

  /// The pay deep-link / QR payload: the same add-contact URI the profile QR
  /// uses, with `pay=1` so a scanner opens straight into paying rather than
  /// just adding. An older build without the flag still adds the contact,
  /// which is the safe degrade.
  static String payloadFor(AppUser user) {
    final params = <String, String>{
      if (user.username.isNotEmpty) 'u': user.username,
      if (user.phone.isNotEmpty) 'p': user.phone,
      'n': user.name,
      'pay': '1',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'okaymsg://add?$query';
  }

  /// The human-readable line to share — a handle beats a raw URI in a text.
  static String shareTextFor(AppUser user) {
    final who = user.handle.isNotEmpty ? user.handle : user.name;
    return 'Pay me on OkayMessenger — $who\n${payloadFor(user)}';
  }

  /// Test hook so the share sheet, which cannot open in a test, is
  /// observable — same shape as the invite-share override.
  static void Function(String text)? debugShareOverride;

  static Future<void> _share(BuildContext context, String text) async {
    final debug = debugShareOverride;
    if (debug != null) {
      debug(text);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    // iOS needs an anchor rect for the share sheet's popover; without one the
    // sheet can silently fail to present (the "Copy link" button, a plain
    // clipboard write, never had that dependency). And if the sheet still
    // won't open, fall back to copying so the button is never a dead end.
    final box = context.findRenderObject() as RenderBox?;
    try {
      await Share.share(
        text,
        subject: 'Pay me on OkayMessenger',
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Couldn\'t open the share sheet — link copied instead.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive money')),
      body: ValueListenableBuilder<AppUser>(
        valueListenable: AppState.profile,
        builder: (context, me, _) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UserAvatar(user: me, radius: 40),
                const SizedBox(height: 12),
                Text(me.name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700)),
                if (me.handle.isNotEmpty)
                  Text(me.handle,
                      style: TextStyle(color: AppColors.subtle(context))),
                const SizedBox(height: 24),
                // Dark-on-white in both themes: a QR scans worst when it
                // takes the app's dark background.
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: payloadFor(me),
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square, color: Color(0xFF0F1419)),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Color(0xFF0F1419)),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Have them scan this with their camera — it opens '
                  'OkayMessenger straight into paying you.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.subtle(context), height: 1.4),
                ),
                const SizedBox(height: 20),
                Builder(
                  builder: (context) => FilledButton.icon(
                    onPressed: () => _share(context, shareTextFor(me)),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share pay link'),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: payloadFor(me)));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Pay link copied')));
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Copy link'),
                ),
                // A numberless account has no directory entry, so its code is
                // the only thing anybody can be told — read it off here.
                if (AccountCode.isCode(me.phone)) ...[
                  const SizedBox(height: 22),
                  Text('YOUR CODE',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: AppColors.subtle(context))),
                  const SizedBox(height: 6),
                  SelectableText(AccountCode.pretty(me.phone),
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
