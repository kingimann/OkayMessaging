import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../widgets/user_avatar.dart';

/// Shows a scannable QR code for the signed-in user, so someone can add them
/// on Okay Messaging by scanning instead of typing a number.
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
                      style: TextStyle(color: Colors.grey.shade600)),
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
                  'Scan this code with Okay Messaging to add ${me.name}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
