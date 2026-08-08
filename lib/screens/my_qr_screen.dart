import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../util/account_code.dart';
import '../theme/app_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../payments/nfc_pay.dart';
import '../widgets/user_avatar.dart';

/// Shows a scannable QR code for the signed-in user, so someone can add them
/// on OkayMessenger by scanning instead of typing a number.
class MyQrScreen extends StatelessWidget {
  const MyQrScreen({super.key});

  /// The payload encoded in the QR: an app URI carrying the handle, number and
  /// name so a scanner can start a chat.
  static String payloadFor(AppUser user) {
    final params = <String, String>{
      if (user.username.isNotEmpty) 'u': user.username,
      if (user.phone.isNotEmpty) 'p': user.phone,
      'n': user.name,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'okaymsg://add?$query';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My QR code')),
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
                Text(
                  me.name,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700),
                ),
                if (me.handle.isNotEmpty)
                  Text(me.handle,
                      style: TextStyle(color: AppColors.subtle(context))),
                const SizedBox(height: 24),
                // QR codes scan best as dark-on-white, so keep the card white
                // in both themes.
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
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF0F1419),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF0F1419),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Scan this code with the iPhone camera — it opens '
                  'OkayMessenger and starts a chat with ${me.name}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle(context), height: 1.4),
                ),
                // Write the same add-me link onto a blank NFC sticker, so a tap
                // adds you — a physical "tap to add me" card. Only offered when
                // the device can do NFC; an iPhone can write a tag but can't
                // broadcast one, which is why this is a sticker, not a phone
                // held to a phone (the QR above is the phone-to-phone way).
                FutureBuilder<bool>(
                  future: NfcPay.instance.available(),
                  builder: (context, snap) {
                    if (snap.data != true) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await NfcPay.instance
                              .shareReceiveTag(payloadFor(me));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(ok
                                  ? 'Your contact tag is ready.'
                                  : 'Couldn\'t write the tag.')));
                        },
                        icon: const Icon(Icons.contactless_outlined),
                        label: const Text('Write a contact tag'),
                      ),
                    );
                  },
                ),
                // An account with no number behind it has nothing anybody can
                // look up, so the code has to be somewhere it can be read off
                // this screen and typed into another phone. A QR is no use at
                // all when the other phone is the one you are holding.
                if (AccountCode.isCode(me.phone)) ...[
                  const SizedBox(height: 20),
                  Text('YOUR CODE',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: AppColors.subtle(context))),
                  const SizedBox(height: 6),
                  SelectableText(
                    AccountCode.pretty(me.phone),
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 17),
                    label: const Text('Copy code'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: me.phone));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                  Text(
                    'You have no phone number on this account, so this is how '
                    'people reach you. Anyone with it can start a chat.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: AppColors.subtle(context)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
