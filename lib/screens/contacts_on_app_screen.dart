import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/user.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../state/contacts_sync.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// Asks to sync the device address book and shows which contacts already use
/// OkayMessenger, with quick message / call actions. Phone numbers never leave
/// the device — only salted hashes are matched against the directory.
class ContactsOnAppScreen extends StatefulWidget {
  const ContactsOnAppScreen({super.key});

  @override
  State<ContactsOnAppScreen> createState() => _ContactsOnAppScreenState();
}

enum _View { intro, loading, done }

class _ContactsOnAppScreenState extends State<ContactsOnAppScreen> {
  _View _view = _View.intro;
  ContactSyncResult? _result;

  @override
  void initState() {
    super.initState();
    if (!ContactsSync.instance.supported) {
      _view = _View.done;
      _result = const ContactSyncResult(ContactSyncStatus.unsupported);
    }
  }

  Future<void> _run() async {
    setState(() => _view = _View.loading);
    final result = await ContactsSync.instance.sync();
    if (!mounted) return;
    setState(() {
      _result = result;
      _view = _View.done;
    });
  }

  void _message(AppUser user) {
    final store = ChatStore.instance;
    final existing = store.chatWithContact(user.id);
    final Chat chat;
    if (existing != null) {
      if (existing.isArchived) store.setArchived(existing.id, false);
      chat = existing;
    } else {
      chat = Chat(id: 'chat_${user.id}', contact: user, messages: const []);
      store.upsert(chat);
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  void _call(AppUser user, {required bool video}) =>
      CallService.instance.startOutgoing(user, video: video);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts on OkayMessenger')),
      body: switch (_view) {
        _View.intro => _intro(),
        _View.loading => const Center(child: CircularProgressIndicator()),
        _View.done => _done(_result!),
      },
    );
  }

  Widget _intro() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircleAvatar(
              radius: 40,
              child: Icon(Icons.contacts_outlined, size: 40),
            ),
            const SizedBox(height: 24),
            const Text('Find your contacts',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(
              'See which of your contacts already use OkayMessenger so you can '
              'message and call them right away.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
            ),
            const SizedBox(height: 20),
            _PrivacyNote(),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.sync),
              label: const Text('Find contacts'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _done(ContactSyncResult result) {
    switch (result.status) {
      case ContactSyncStatus.ok:
        if (result.matches.isEmpty) {
          return _message_(
            Icons.person_off_outlined,
            'No contacts yet',
            'None of your contacts are on OkayMessenger yet. Invite them and '
                'they\'ll show up here.',
            retry: true,
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${result.matches.length} '
                  '${result.matches.length == 1 ? "contact" : "contacts"} on '
                  'OkayMessenger',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: Colors.grey),
                ),
              ),
            ),
            Expanded(
              child: PullToRefresh(
                child: ListView.builder(
                  itemCount: result.matches.length,
                  itemBuilder: (context, i) {
                    final user = result.matches[i];
                    return ListTile(
                      leading: UserAvatar(user: user, radius: 24),
                      title: Text(user.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle:
                          user.username.isEmpty ? null : Text('@${user.username}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.call),
                            tooltip: 'Voice call',
                            onPressed: () => _call(user, video: false),
                          ),
                          IconButton(
                            icon: const Icon(Icons.videocam),
                            tooltip: 'Video call',
                            onPressed: () => _call(user, video: true),
                          ),
                        ],
                      ),
                      onTap: () => _message(user),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      case ContactSyncStatus.permissionDenied:
        return _message_(
          Icons.lock_outline,
          'Contacts permission needed',
          'To find your contacts, allow OkayMessenger to access your contacts '
              'in Settings, then try again.',
          retry: true,
        );
      case ContactSyncStatus.unsupported:
        return _message_(
          Icons.phone_iphone,
          'Use the mobile app',
          'Finding your contacts is available in the OkayMessenger app on your '
              'phone.',
        );
      case ContactSyncStatus.empty:
        return _message_(
          Icons.contacts_outlined,
          'No contacts found',
          'Your address book doesn\'t have any phone numbers to check.',
          retry: true,
        );
      case ContactSyncStatus.error:
        return _message_(
          Icons.error_outline,
          'Something went wrong',
          'We couldn\'t read your contacts. Please try again.',
          retry: true,
        );
    }
  }

  Widget _message_(IconData icon, String title, String body,
      {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
            if (retry) ...[
              const SizedBox(height: 20),
              OutlinedButton(onPressed: _run, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF22252B) : const Color(0xFFF0F2F3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Your contacts are never uploaded. Only encrypted hashes of phone '
              'numbers are checked against the directory.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
