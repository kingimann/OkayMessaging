import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../crypto/double_ratchet.dart';
import '../crypto/e2e.dart';
import '../crypto/key_exchange.dart';
import '../models/user.dart';
import '../widgets/user_avatar.dart';

/// Shows the conversation's security code (safety number). If it matches on
/// both devices, the chat's end-to-end encryption is verified — a
/// person-in-the-middle would produce a different code.
class SecurityCodeScreen extends StatelessWidget {
  final AppUser contact;

  const SecurityCodeScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    // The code fingerprints BOTH devices' identity keys — it exists only
    // once the peer's key has arrived. It used to be derived from the two
    // phone numbers, which an interceptor also has, so it matched through
    // any attack and verified nothing. No code beats a code that lies.
    final myPub = SecureKeyExchange.instance.myPublicKey;
    final peerPub = SecureKeyExchange.instance.peerKey(contact.phone);
    final code = (myPub != null && peerPub != null)
        ? E2eCrypto.safetyNumberForKeys(myPub, peerPub)
        : null;
    final groups = code?.split(' ') ?? const <String>[];
    // Say which rung of the encryption ladder this conversation is really
    // on, instead of one static sentence for all three. The ladder only
    // climbs: a chat starts against the number, steps up when the peer's
    // device introduces its key, and lands on the ratchet as you message.
    final ratchet = DoubleRatchet.instance.hasSession(contact.phone);
    final ecdh = peerPub != null;
    final level = ratchet
        ? 'Signal protocol — Double Ratchet active'
        : ecdh
            ? 'Encrypted between your devices\' keys'
            : 'Encrypted, waiting for their device';
    final how = ratchet
        ? 'end-to-end encrypted with the Signal protocol\'s Double Ratchet: '
            'every message gets its own key, so even a key stolen later '
            'cannot unlock what was already said'
        : ecdh
            ? 'end-to-end encrypted with keys agreed directly between your '
                'devices, and step up to the Signal Double Ratchet as you '
                'message'
            : 'end-to-end encrypted, and step up to the Signal Double '
                'Ratchet once their device introduces itself';

    return Scaffold(
      appBar: AppBar(title: const Text('Security code')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: [
          const SizedBox(height: 8),
          Center(child: UserAvatar(user: contact, radius: 40)),
          const SizedBox(height: 14),
          Center(
            child: Icon(Icons.lock, size: 22, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              level,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              code == null
                  ? 'Messages and calls with ${contact.name} are $how. The '
                      'security code appears once your devices have '
                      'exchanged keys — send a message each way, then '
                      'compare it here.'
                  : 'Messages and calls with ${contact.name} are $how. This '
                      'code is a fingerprint of both devices\' encryption '
                      'keys — compare it on both phones, and if it matches, '
                      'nobody is between you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), height: 1.4),
            ),
          ),
          const SizedBox(height: 26),
          if (code != null) ...[
            Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
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
          ] else
            Center(
              child: Icon(Icons.hourglass_empty,
                  size: 32, color: AppColors.subtle(context)),
            ),
        ],
      ),
    );
  }
}
