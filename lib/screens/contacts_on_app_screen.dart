import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat.dart';
import '../models/user.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../state/contacts_sync.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_shell.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
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

/// Test hook: replaces the OS share sheet behind "Invite friends".
@visibleForTesting
void Function(String text)? debugInviteShareOverride;

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
    // iOS decides contact access once and never re-raises its own dialog, so
    // when access is limited the app has to be the one that asks: here, at
    // the moment of syncing, when the question is concrete. Skipped entirely
    // for full access and for a first run (the real OS prompt handles that).
    if (await ContactsSync.instance.isAccessLimited()) {
      if (!mounted) return;
      final toSettings = await showAppConfirmDialog(
        context,
        icon: Icons.playlist_add_check_circle_outlined,
        title: 'Only some contacts are shared',
        message: 'OkayMessenger can only see the contacts you selected. '
            'Allow full access in Settings to check all of them, or '
            'continue with the ones you picked.',
        confirmLabel: 'Open Settings',
        cancelLabel: 'Use selected',
      );
      if (!mounted) return;
      if (toSettings) {
        // Off to Settings — stay on the intro so coming back lands on the
        // button, not on results computed from the old selection.
        await ContactsSync.instance.openSettings();
        return;
      }
    }
    if (!mounted) return;
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
      appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: const SidebarButton(),
          title: const Text('Contacts on OkayMessenger')),
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
            result.limited
                // Only a shared subset was checked, so "none of your
                // contacts are here" would be a claim about contacts the
                // app never saw.
                ? 'None of the contacts you shared are on OkayMessenger yet. '
                    'You can share more in Settings, or invite them.'
                : 'None of your contacts are on OkayMessenger yet. Invite '
                    'them and they\'ll show up here.',
            retry: true,
            settings: result.limited,
            invite: true,
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
            if (result.limited)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: ContactsSync.instance.openSettings,
                    child: Text(
                      'Only the contacts you shared were checked — '
                      'share more in Settings.',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade600),
                    ),
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
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(user.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (user.verified) ...[
                            const SizedBox(width: 4),
                            const VerifiedBadge(size: 15),
                          ],
                        ],
                      ),
                      subtitle: user.username.isEmpty
                          ? null
                          : Text('@${user.username}'),
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
          settings: true,
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
      case ContactSyncStatus.limitedEmpty:
        // The address book is fine — the app was only shown a hand-picked
        // slice of it, and the slice is empty. Blaming "your address book"
        // here (which this used to do) reads as the app being broken.
        return _message_(
          Icons.playlist_add_check_circle_outlined,
          'No contacts shared yet',
          'OkayMessenger only has access to contacts you select, and none '
              'are selected. Choose some in Settings — or allow full access '
              '— then try again.',
          retry: true,
          settings: true,
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

  void _invite() {
    const link = 'https://kingimann.github.io/OkayMessaging/';
    const text = 'I\'m on OkayMessenger — a private messenger where chats '
        'stay on your own phone. Join me: $link';
    final debug = debugInviteShareOverride;
    if (debug != null) {
      debug(text);
      return;
    }
    Share.share(text, subject: 'Join me on OkayMessenger');
  }

  Widget _message_(IconData icon, String title, String body,
      {bool retry = false, bool settings = false, bool invite = false}) {
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
            // "Nobody's here yet" is an invitation problem, not a retry
            // problem — so the primary action is inviting, via the OS share
            // sheet, and syncing again is the secondary one.
            if (invite) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _invite,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Invite friends'),
              ),
            ],
            // "Fix it in Settings" needs a button that goes there. The text
            // alone left people to find the right settings page themselves,
            // which most reasonably read as a dead end.
            if (settings) ...[
              SizedBox(height: invite ? 8 : 20),
              FilledButton(
                onPressed: ContactsSync.instance.openSettings,
                child: const Text('Open Settings'),
              ),
            ],
            if (retry) ...[
              SizedBox(height: settings || invite ? 8 : 20),
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
