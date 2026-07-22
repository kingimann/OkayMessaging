import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../widgets/user_avatar.dart';

/// Lists everyone the user has blocked, with a one-tap unblock. Blocked
/// contacts can't message you until unblocked.
class BlockedContactsScreen extends StatelessWidget {
  const BlockedContactsScreen({super.key});

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked contacts')),
      body: ValueListenableBuilder<Set<String>>(
        valueListenable: AppState.blockedContacts,
        builder: (context, blocked, _) {
          if (blocked.isEmpty) {
            return _empty(context);
          }
          // Resolve a friendly name/avatar from an existing chat when we have
          // one; otherwise fall back to the raw number.
          final chats = ChatStore.instance.allChats;
          final entries = blocked.toList()..sort();
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, indent: 72, thickness: 0.4),
            itemBuilder: (context, i) {
              final digits = entries[i];
              AppUser? contact;
              for (final c in chats) {
                if (_digits(c.contact.phone) == digits) {
                  contact = c.contact;
                  break;
                }
              }
              return ListTile(
                leading: contact != null
                    ? UserAvatar(user: contact, radius: 22)
                    : CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.grey.shade400,
                        child: const Icon(Icons.person, color: Colors.white),
                      ),
                title: Text(contact?.name ?? '+$digits',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: contact != null ? Text(contact.phone) : null,
                trailing: OutlinedButton(
                  onPressed: () {
                    AppState.setBlocked(digits, false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(
                              'Unblocked ${contact?.name ?? '+$digits'}')),
                    );
                  },
                  child: const Text('Unblock'),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final grey = Colors.grey.shade500;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 60, color: grey),
            const SizedBox(height: 16),
            Text('No blocked contacts',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text(
              'Blocked people can\'t call or message you.\n'
              'Block someone from their contact info.',
              textAlign: TextAlign.center,
              style: TextStyle(color: grey, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
