import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../theme/app_theme.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import '../util/account_code.dart';
import '../state/contacts_sync.dart';
import '../util/phone_format.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/invite_prompt.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'contacts_on_app_screen.dart';
import 'create_group_screen.dart';
import 'find_people_screen.dart';

/// Contact picker shown from the Chats FAB. Start a chat with a sample contact
/// or with any phone number — everything is created and stored locally.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  void _openChat(BuildContext context, Chat chat) {
    // Replace this screen so back returns to the chats list, not the picker.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  void _startChat(BuildContext context, AppUser contact) {
    final chat = ChatStore.instance.startChatWith(contact,
        myPhone: Session.instance.user.value?.phone,
        myAvatarColor: AppState.profile.value.avatarColor);
    _openChat(context, chat);
  }

  Future<void> _startByNumber(BuildContext context) async {
    final result = await showAppTextPrompt(
      context,
      icon: Icons.dialpad,
      title: 'Chat with a number or code',
      hint: '+1 555 0199  ·  0012 3456 7890',
      confirmLabel: 'Start',
      keyboardType: TextInputType.phone,
    );
    final typed = result?.trim();
    if (typed == null || typed.isEmpty || !context.mounted) return;

    // An account with no phone number is reached by its code. Normalising it
    // to bare digits matters: somebody reading one off another phone types
    // the spaces in, and "0012 3456 7890" addressed verbatim is a different
    // inbox from "001234567890".
    //
    // A REAL phone number needs the same care, for a different reason: the
    // relay addresses a chat by RelayService.digits(phone) — bare digits,
    // no country-code awareness — so "5551234567" and "+15551234567" are
    // two different inboxes even though they're the same person. Typing a
    // number the way people normally give it out (no country code) used to
    // create a chat that looked like it worked — it sent, no error — but
    // broadcast to an inbox nobody was listening on, so nothing ever
    // arrived. phoneToE164 (already trusted at the verify-your-number
    // choke point for the identical reason) fixes this before the number
    // becomes a Chat's address; it's idempotent, so an already-full number
    // passes through unchanged.
    final code = AccountCode.normalize(typed);
    final number = code ?? phoneToE164(typed);

    final store = ChatStore.instance;
    if (store.isOwnNumber(number, myPhone: Session.instance.user.value?.phone)) {
      _openChat(context,
          store.noteToSelfChat(myAvatarColor: AppState.profile.value.avatarColor));
      return;
    }
    final existing = store.chatWithContact(number);
    final Chat chat;
    if (existing != null) {
      chat = existing;
    } else {
      // A NEW reach-out only: an existing conversation is history, not a
      // first message into a void. Confidently-unknown numbers get an
      // invite instead of a chat that can never deliver.
      if (!await allowChatWithNumber(context, number)) return;
      if (!context.mounted) return;
      final contact = AppUser(
        id: number,
        name: code == null ? number : AccountCode.pretty(number),
        avatarColor: '#64B5F6',
        about: '',
        phone: number,
      );
      chat = Chat(id: 'chat_$number', contact: contact, messages: const []);
      store.upsert(chat);
    }
    _openChat(context, chat);
  }

  /// Opens (or creates) the private notes chat with yourself: a place for
  /// reminders, links, and drafts. Nothing leaves the device — the "peer"
  /// is you, so the relay never delivers it anywhere else.
  void _openNoteToSelf(BuildContext context) {
    _openChat(
        context,
        ChatStore.instance
            .noteToSelfChat(myAvatarColor: AppState.profile.value.avatarColor));
  }

  @override
  Widget build(BuildContext context) {
    // Sample contacts are dev/test-only; a real install starts empty.
    final contacts = kReleaseMode ? <AppUser>[] : MockData.contacts();
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: PullToRefresh(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const _SectionLabel('Start a conversation'),
            _ActionCard(
              children: [
                _ActionTile(
                  icon: Icons.group_add_outlined,
                  label: 'New group',
                  subtitle: 'Message several people at once',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
                  ),
                ),
                _ActionTile(
                  icon: Icons.alternate_email,
                  label: 'Find people by username',
                  subtitle: 'Search @handles across OkayMessenger',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FindPeopleScreen()),
                  ),
                ),
                if (ContactsSync.instance.supported)
                  _ActionTile(
                    icon: Icons.contacts_outlined,
                    label: 'Find contacts on OkayMessenger',
                    subtitle: 'See which of your contacts are already here',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const ContactsOnAppScreen()),
                    ),
                  ),
                _ActionTile(
                  icon: Icons.dialpad,
                  label: 'Chat with a number or code',
                  subtitle: 'Start with a phone number or account code',
                  onTap: () => _startByNumber(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ActionCard(
              children: [
                _ActionTile(
                  icon: Icons.bookmark_outline,
                  label: 'Note to self',
                  subtitle: 'Private notes, reminders and drafts',
                  onTap: () => _openNoteToSelf(context),
                ),
              ],
            ),
            if (contacts.isNotEmpty) ...[
              const _SectionLabel('Contacts on OkayMessenger'),
              _ActionCard(
                children: [
                  for (final c in contacts)
                    ListTile(
                      leading: UserAvatar(user: c, radius: 22),
                      title: Text(c.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(c.bio,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _startChat(context, c),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A quiet all-caps section header, spaced like the grouped lists elsewhere.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.subtle(context),
        ),
      ),
    );
  }
}

/// A rounded, inset card that groups a set of tiles — the iOS-grouped-list
/// shape, so the picker reads as tidy sections rather than a flat run of rows.
class _ActionCard extends StatelessWidget {
  final List<Widget> children;
  const _ActionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // A Material (not a coloured Container) so the tiles' ink and highlights
    // still paint; the border rides on the Material's shape.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: isDark ? AppColors.darkAppBar : Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? const Color(0xFF2A2E34) : const Color(0xFFEAECEF),
          ),
        ),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, indent: 64, endIndent: 0),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  const _ActionTile(
      {required this.icon, required this.label, this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          // The app's own accent, tinted — not the old hard-coded green, which
          // matched nothing else in the app.
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: accent, size: 22),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
      trailing: Icon(Icons.chevron_right,
          size: 20, color: AppColors.subtle(context)),
      onTap: onTap ?? () {},
    );
  }
}
