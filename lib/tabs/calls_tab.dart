import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/call.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../screens/chat_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/dialer_screen.dart';
import '../screens/home_screen.dart';
import '../screens/find_people_screen.dart';
import '../state/call_log.dart';
import '../state/favourites_store.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';

void _startCall(BuildContext context, AppUser user, {required bool video}) {
  CallService.instance.startOutgoing(user, video: video);
}

/// A favourite tap: Voice / Video / Message on one sheet, so quick calling
/// isn't a blind single-tap and video is one tap away too.
Future<void> _favouriteActions(BuildContext context, AppUser user) async {
  final chat = ChatStore.instance.chatWithContact(user.id);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: UserAvatar(user: user, radius: 20),
            title: Text(user.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: user.username.isEmpty ? null : Text('@${user.username}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.call),
            title: const Text('Voice call'),
            onTap: () {
              Navigator.pop(sheetContext);
              _startCall(context, user, video: false);
            },
          ),
          ListTile(
            leading: const Icon(Icons.videocam),
            title: const Text('Video call'),
            onTap: () {
              Navigator.pop(sheetContext);
              _startCall(context, user, video: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Message'),
            onTap: () {
              Navigator.pop(sheetContext);
              final c = chat ??
                  ChatStore.instance.upsertReturning(Chat(
                      id: 'chat_${user.id}',
                      contact: user,
                      messages: const []));
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatScreen(chat: c)));
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.star_outline, color: Colors.red),
            title: const Text('Remove favourite',
                style: TextStyle(color: Colors.red)),
            onTap: () {
              FavouritesStore.instance.remove(user.id);
              Navigator.pop(sheetContext);
            },
          ),
        ],
      ),
    ),
  );
}

/// A received voicemail — a voicemail voice message plus the chat it lives in.
class _Voicemail {
  final Chat chat;
  final Message message;
  const _Voicemail(this.chat, this.message);
}

List<_Voicemail> _receivedVoicemails() {
  final out = <_Voicemail>[];
  for (final chat in ChatStore.instance.allChats) {
    for (final m in chat.messages) {
      if (m.isVoicemail && !m.isMe) out.add(_Voicemail(chat, m));
    }
  }
  out.sort((a, b) => b.message.time.compareTo(a.message.time));
  return out;
}

/// The "Calls" tab: a modern layout with a search field, quick-call
/// favourites, received voicemails, and the persisted call log.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  Future<void> _clearLog(BuildContext context) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.delete_sweep_outlined,
      title: 'Clear call history?',
      message: 'This removes every entry from the call log.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok) CallLog.instance.clear();
  }

  // No phone gate: a call rides the same anon-key relay broadcast that chat
  // does, addressed by the account code a numberless account already mints,
  // so calls work with no session exactly as chat does. (Ringing a CLOSED
  // app still needs a push token, which is session-gated — the same live-only
  // caveat chat delivery has for these accounts; a call placed while both
  // apps are open connects.)
  @override
  Widget build(BuildContext context) => Builder(builder: _guarded);

  Widget _guarded(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        CallLog.instance,
        ChatStore.instance,
        FavouritesStore.instance,
      ]),
      builder: (context, _) {
        final calls = CallLog.instance.records;
        final voicemails = _receivedVoicemails();
        return PullToRefresh(
          child: ListView(
            // Clear the floating glass bar, measured rather than
            // guessed. The old constant 96 was SHORT of it on a
            // home-indicator iPhone, so the last row sat under the glass.
            padding:
                EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
            children: [
              const _FavouritesRow(),
              if (voicemails.isNotEmpty) ...[
                const _SectionHeader('Voicemail'),
                ...voicemails.map((v) => _VoicemailTile(voicemail: v)),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _SectionHeader('Recent'),
                  if (calls.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton(
                        onPressed: () => _clearLog(context),
                        child: const Text('Clear'),
                      ),
                    ),
                ],
              ),
              if (calls.isEmpty)
                const _EmptyRecent()
              else
                ...calls.map((c) => _CallTile(record: c)),
            ],
          ),
        );
      },
    );
  }
}

/// The Calls tab's app-bar actions. These used to be four stacked tiles at the
/// top of the list, which squeezed favourites and recents into the bottom
/// half of the screen; up here they leave the whole list to the call history.
class CallsTabActions extends StatelessWidget {
  const CallsTabActions({super.key});

  void _onSelected(BuildContext context, String value) {
    switch (value) {
      case 'link':
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => _CallLinkSheet(link: _newCallLink()),
        );
        break;
      case 'dial':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DialerScreen()),
        );
        break;
      case 'contact':
        showCallContactPicker(context);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The magnifying glass that used to sit here opened the DIRECTORY,
        // while the identical one on the Chats tab opened a search of this
        // device — one icon meaning two things, depending which tab you were
        // on. The device search is now in the bar on every tab, and it offers
        // the directory itself when it finds nobody.
        //
        // Contacts lives here now, not on the sidebar (the owner's call):
        // the people you call are the people you saved.
        IconButton(
          icon: const Icon(Icons.contacts_outlined),
          tooltip: 'Contacts',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ContactsScreen()),
          ),
        ),
        // The dialer rates its own button: it's how you call anyone,
        // on the app or off it.
        IconButton(
          icon: const Icon(Icons.dialpad),
          tooltip: 'Dial a number',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DialerScreen()),
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.add_call),
          tooltip: 'Start a call',
          onSelected: (v) => _onSelected(context, v),
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'contact',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.contact_phone_outlined),
                title: Text('Call a contact'),
                subtitle: Text('Pick someone from your chats'),
              ),
            ),
            PopupMenuItem(
              value: 'dial',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.dialpad),
                title: Text('Dial a number'),
                subtitle: Text('Call any number directly'),
              ),
            ),
            PopupMenuItem(
              value: 'link',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.link),
                title: Text('Create call link'),
                subtitle: Text('Share a link for your call'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Builds a fresh, shareable call link. Mirrors the community invite-link
/// scheme (`https://okay.chat/...`) so every link in the app looks the same.
String _newCallLink() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random();
  final code = List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  return 'https://okay.chat/call/$code';
}

/// Sheet shown after tapping "Create call link": presents the generated link
/// with Copy and Share actions.
class _CallLinkSheet extends StatelessWidget {
  final String link;
  const _CallLinkSheet({required this.link});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CircleAvatar(
                radius: 28,
                backgroundColor: AppColors.accentOn(context).withValues(alpha: 0.15),
                child: Icon(Icons.link,
                    color: AppColors.accentOn(context), size: 30),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Call link ready',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Share this link with anyone you want on the call. They can join '
              'straight from it — no number needed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), fontSize: 13.5),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF22252B) : const Color(0xFFF0F2F3),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link, size: 18, color: Colors.grey),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(link,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _share(context),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Share'),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accentOn(context),
                        foregroundColor: AppColors.onAccent(context),
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Call link copied')),
    );
  }

  Future<void> _share(BuildContext context) async {
    // iOS needs an anchor rect for the share sheet, or it can fail to present.
    final box = context.findRenderObject() as RenderBox?;
    try {
      await Share.share('Join my call on OkayMessenger: $link',
          subject: 'OkayMessenger call',
          sharePositionOrigin:
              box != null ? box.localToGlobal(Offset.zero) & box.size : null);
    } catch (_) {
      // Web browsers without the Share API (and headless tests) fall back to
      // the clipboard so the button always does something useful.
      if (!context.mounted) return;
      _copy(context);
    }
  }
}

/// Everyone callable from local state: people from chats and the call log,
/// deduped, no groups.
List<AppUser> callableContacts() {
  final seen = <String>{};
  final out = <AppUser>[];
  void consider(AppUser u) {
    if (u.isGroup || u.phone.isEmpty) return;
    if (seen.add(u.id)) out.add(u);
  }

  for (final c in ChatStore.instance.allChats) {
    consider(c.contact);
  }
  for (final r in CallLog.instance.records) {
    consider(r.user);
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// Picks a contact (from chats and call history) and calls them.
void showCallContactPicker(BuildContext context) {
  final contacts = callableContacts();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: contacts.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'No contacts yet. Find people by username or dial a number '
                    'to make your first call.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.subtle(context)),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const FindPeopleScreen()));
                    },
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Find people'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: contacts.length,
              itemBuilder: (context, i) {
                final user = contacts[i];
                return ListTile(
                  leading: UserAvatar(user: user, radius: 22),
                  title: Text(user.name),
                  subtitle:
                      user.username.isEmpty ? null : Text('@${user.username}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.call,
                            color: AppColors.accentOn(context)),
                        tooltip: 'Voice call',
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _startCall(context, user, video: false);
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.videocam,
                            color: AppColors.accentOn(context)),
                        tooltip: 'Video call',
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _startCall(context, user, video: true);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
    ),
  );
}

/// Horizontally scrolling quick-call favourites, editable: tap to call, an
/// "Add" tile to pick more, long-press (or the Edit action) to remove.
class _FavouritesRow extends StatelessWidget {
  const _FavouritesRow();

  /// People the user could add as favourites: everyone they've chatted with or
  /// called (deduped), minus groups and current favourites.
  List<AppUser> _candidates() {
    final seen = <String>{};
    final out = <AppUser>[];
    void consider(AppUser u) {
      if (u.isGroup || FavouritesStore.instance.isFavourite(u.id)) return;
      if (seen.add(u.id)) out.add(u);
    }

    for (final c in ChatStore.instance.allChats) {
      consider(c.contact);
    }
    for (final r in CallLog.instance.records) {
      consider(r.user);
    }
    return out;
  }

  Future<void> _addFavourite(BuildContext context) async {
    final candidates = _candidates();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text('Add favourite',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              if (candidates.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      Text(
                        'Chat with or call someone first, then add them here '
                        'for one-tap calling.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.subtle(context)),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const FindPeopleScreen()));
                        },
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Find people'),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    itemBuilder: (context, i) {
                      final user = candidates[i];
                      return ListTile(
                        leading: UserAvatar(user: user, radius: 22),
                        title: Text(user.name),
                        subtitle: user.username.isEmpty
                            ? null
                            : Text('@${user.username}'),
                        trailing: const Icon(Icons.add),
                        onTap: () {
                          FavouritesStore.instance.add(user);
                          Navigator.pop(sheetContext);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, AppUser user) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.star_outline,
      title: 'Remove ${user.name.split(' ').first}?',
      message: 'Remove this person from your call favourites.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (ok) FavouritesStore.instance.remove(user.id);
  }

  @override
  Widget build(BuildContext context) {
    // Self-subscribe: this row is a `const` child of CallsTab, so Flutter's
    // const canonicalization can skip rebuilding it when the parent
    // rebuilds — which meant a just-added favourite didn't appear until you
    // left and came back. Listening here guarantees it refreshes on add.
    return ListenableBuilder(
      listenable: FavouritesStore.instance,
      builder: (context, _) => _buildRow(context),
    );
  }

  Widget _buildRow(BuildContext context) {
    final favourites = FavouritesStore.instance.favourites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Favourites'),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: favourites.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (context, i) {
              if (i == favourites.length) {
                return _AddFavouriteTile(onTap: () => _addFavourite(context));
              }
              final user = favourites[i];
              return GestureDetector(
                onTap: () => _favouriteActions(context, user),
                onLongPress: () => _confirmRemove(context, user),
                child: SizedBox(
                  width: 66,
                  child: Column(
                    children: [
                      UserAvatar(user: user, radius: 30),
                      const SizedBox(height: 6),
                      Text(
                        user.name.split(' ').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (favourites.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text('Tap for call, video or message',
                style: TextStyle(fontSize: 11.5, color: AppColors.subtle(context))),
          ),
      ],
    );
  }
}

/// The trailing "+" tile in the favourites row.
class _AddFavouriteTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddFavouriteTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 66,
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark
                    ? const Color(0xFF22252B)
                    : const Color(0xFFF0F2F3),
                border: Border.all(color: Colors.grey.shade400, width: 1),
              ),
              child: Icon(Icons.add, color: AppColors.subtle(context), size: 28),
            ),
            const SizedBox(height: 6),
            Text('Add',
                style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
          ],
        ),
      ),
    );
  }
}

class _VoicemailTile extends StatelessWidget {
  final _Voicemail voicemail;
  const _VoicemailTile({required this.voicemail});

  String get _duration {
    final s = voicemail.message.voiceSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        children: [
          UserAvatar(user: voicemail.chat.contact, radius: 24),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: AppColors.accentOn(context),
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).canvasColor, width: 2),
              ),
              child: const Icon(Icons.voicemail, size: 11, color: Colors.white),
            ),
          ),
        ],
      ),
      title: Text(voicemail.chat.contact.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          Icon(Icons.voicemail, size: 15, color: AppColors.subtle(context)),
          const SizedBox(width: 4),
          Text('Voicemail · $_duration'),
          const SizedBox(width: 6),
          Text('· ${DateFormatter.callLabel(voicemail.message.time)}',
              style: TextStyle(color: AppColors.subtle(context), fontSize: 12.5)),
        ],
      ),
      trailing: IconButton(
        icon: Icon(Icons.play_circle_fill,
            color: AppColors.accentOn(context), size: 34),
        tooltip: 'Open voicemail',
        onPressed: () => _openChat(context),
      ),
      onTap: () => _openChat(context),
    );
  }

  void _openChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: voicemail.chat)),
    );
  }
}

class _CallTile extends StatelessWidget {
  final CallRecord record;

  const _CallTile({required this.record});

  IconData get _directionIcon {
    switch (record.direction) {
      case CallDirection.incoming:
        return Icons.call_received;
      case CallDirection.outgoing:
        return Icons.call_made;
      case CallDirection.missed:
        return Icons.call_missed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = record.isMissed ? Colors.red : Colors.green;
    return ListTile(
      leading: UserAvatar(user: record.user, radius: 24),
      title: Text(
        record.user.name,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: record.isMissed ? Colors.red : null,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(_directionIcon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(DateFormatter.callLabel(record.time)),
          if (record.durationLabel != null) ...[
            const SizedBox(width: 6),
            Icon(Icons.timer_outlined, size: 13, color: AppColors.subtle(context)),
            const SizedBox(width: 2),
            Text(record.durationLabel!,
                style: TextStyle(color: AppColors.subtle(context))),
          ],
          // Only a POOR link is worth a word in the log — good is the
          // default and two bars is a call that still worked.
          if (record.quality == 1) ...[
            const SizedBox(width: 6),
            const Icon(Icons.signal_cellular_connected_no_internet_0_bar,
                size: 13, color: Color(0xFFF7931A)),
            const SizedBox(width: 2),
            const Text('poor connection',
                style: TextStyle(color: Color(0xFFF7931A), fontSize: 12)),
          ],
        ],
      ),
      trailing: IconButton(
        icon: Icon(
          record.type == CallType.video ? Icons.videocam : Icons.call,
          color: AppColors.accentOn(context),
        ),
        onPressed: () =>
            _startCall(context, record.user, video: record.type == CallType.video),
      ),
      onTap: () =>
          _startCall(context, record.user, video: record.type == CallType.video),
      onLongPress: () => _showActions(context),
    );
  }

  /// Long-press actions for one history entry.
  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call),
              title: const Text('Voice call'),
              onTap: () {
                Navigator.pop(sheetContext);
                _startCall(context, record.user, video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Video call'),
              onTap: () {
                Navigator.pop(sheetContext);
                _startCall(context, record.user, video: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Message'),
              onTap: () {
                Navigator.pop(sheetContext);
                final store = ChatStore.instance;
                final existing = store.chatWithContact(record.user.id);
                final chat = existing ??
                    Chat(
                        id: 'chat_${record.user.id}',
                        contact: record.user,
                        messages: const []);
                if (existing == null) store.upsert(chat);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ChatScreen(chat: chat)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Remove from history',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                CallLog.instance.remove(record.id);
                Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty state for the recent-calls section before any calls happen.
class _EmptyRecent extends StatelessWidget {
  const _EmptyRecent();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.call_outlined,
      title: 'No recent calls',
      caption: 'Calls you make and receive will show up here.',
      actionLabel: 'Call someone',
      onAction: () => showCallContactPicker(context),
      compact: true,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => SectionHeader(label);
}
