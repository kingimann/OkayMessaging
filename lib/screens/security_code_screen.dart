import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/e2e.dart';
import '../models/user.dart';
import '../state/session.dart';
import '../widgets/user_avatar.dart';

/// Shows the conversation's security code (safety number). If it matches on
/// both devices, the chat's end-to-end encryption is verified — a
/// person-in-the-middle would produce a different code.
class SecurityCodeScreen extends StatelessWidget {
  final AppUser contact;

  const SecurityCodeScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    final myPhone = Session.instance.user.value?.phone ?? '';
    final code = E2eCrypto.safetyNumber(myPhone, contact.phone);
    final groups = code.split(' ');

    return Scaffold(
      appBar: AppBar(title: const Text('Security code')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: [
          const SizedBox(height: 8),
          Center(child: UserAvatar(user: contact, radius: 40)),
          const SizedBox(height: 14),
          Center(
            child: Icon(Icons.lock, size: 22, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Messages and calls with ${contact.name} are end-to-end '
              'encrypted with AES-256-GCM. Compare this code on both devices '
              'to verify — if they match, no one else can read this chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, height: 1.4),
            ),
          ),
          const SizedBox(height: 26),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF23262B)
                  : const Color(0xFFF4F6F7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 12,
              children: [
                for (final g in groups)
                  Text(
                    g,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 20,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Security code copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy code'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}
