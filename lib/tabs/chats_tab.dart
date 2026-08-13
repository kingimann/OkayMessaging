import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../widgets/chat_lock_dialogs.dart';
import '../state/chat_lock.dart';

import '../models/chat.dart';
import '../app_state.dart';
import '../models/user.dart';
import '../screens/chat_folders_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/contacts_on_app_screen.dart';
import '../screens/edit_profile_screen.dart';
import '../screens/marketplace_chats_screen.dart';
import '../screens/message_requests_screen.dart';
import '../screens/new_chat_screen.dart';
import '../screens/find_people_screen.dart';
import '../state/chat_folders.dart';
import '../state/chat_store.dart';
import '../state/inbox_tiers.dart';
import '../state/contacts_sync.dart';
import '../state/onboarding_store.dart';
import '../state/streak_store.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/sanction_notice.dart';

/// Quick filters shown as chips above the chat list, mirroring the familiar
/// All / Unread / Favourites / Groups controls, plus the three Smart Inbox
/// tiers ([InboxTier]) as three more chips in the same row.
enum ChatFilter {
  all,
  unread,
  favorites,
  groups,
  priority,
  general,
  occasional;

  String get label => switch (this) {
        ChatFilter.all => 'All',
        ChatFilter.unread => 'Unread',
        ChatFilter.favorites => 'Favourites',
        ChatFilter.groups => 'Groups',
        ChatFilter.priority => InboxTier.priority.label,
        ChatFilter.general => InboxTier.general.label,
        ChatFilter.occasional => InboxTier.occasional.label,
      };

  bool matches(Chat chat) => switch (this) {
        ChatFilter.all => true,
        ChatFilter.unread => chat.unreadCount > 0,
        ChatFilter.favorites => chat.isFavorite,
        ChatFilter.groups => chat.contact.isGroup,
        ChatFilter.priority =>
          InboxTiers.instance.tierFor(chat) == InboxTier.priority,
        ChatFilter.general =>
          InboxTiers.instance.tierFor(chat) == InboxTier.general,
        ChatFilter.occasional =>
          InboxTiers.instance.tierFor(chat) == InboxTier.occasional,
      };
}

/// The primary "Chats" tab: a clean, uncluttered list of all (non-archived)
/// conversations. Search and archived chats live in the app-bar menu.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  /// Whether the filter chips are shown. Hidden by default to keep the chat
  /// list uncluttered; toggled from the Chats overflow menu.
  static final ValueNotifier<bool> filtersVisible = ValueNotifier<bool>(false);

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  ChatFilter _filter = ChatFilter.all;

  /// The selected folder tab, or null when a built-in filter is active. The
  /// two are exclusive: picking a folder is picking a different list, not an
  /// extra condition on the current one.
  String? _folder;
  Future<void> _openChat(Chat chat) async {
    // Asked here rather than inside the chat screen, so the messages are
    // never built and never painted for a frame behind a dialog.
    if (!ChatLock.instance.isOpen(chat.id)) {
      final ok = await askForChatPassword(context, chat.id,
          chatName: chat.contact.name);
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  void _showChatActions(Chat chat) {
    Haptics.press();
    final store = ChatStore.instance;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        void act(void Function() action) {
          action();
          Navigator.of(sheetContext).pop();
        }

        // Scrollable, because the list grew past the height of a short phone
        // once locking joined it — a bottom sheet that overflows drops its
        // last rows off the screen with no way to reach them.
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                      chat.isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(chat.isPinned ? 'Unpin chat' : 'Pin chat'),
                  onTap: () => act(() => store.togglePin(chat.id)),
                ),
                ListTile(
                  leading: Icon(
                      chat.isFavorite ? Icons.star : Icons.star_border_outlined),
                  title: Text(chat.isFavorite
                      ? 'Remove from favourites'
                      : 'Add to favourites'),
                  onTap: () => act(() => store.toggleFavorite(chat.id)),
                ),
                ListTile(
                  leading:
                      Icon(chat.isMuted ? Icons.volume_up : Icons.volume_off),
                  title: Text(chat.isMuted ? 'Unmute' : 'Mute notifications'),
                  onTap: () => act(() => store.toggleMute(chat.id)),
                ),
                ListTile(
                  leading: Icon(chat.unreadCount > 0
                      ? Icons.mark_chat_read
                      : Icons.mark_chat_unread),
                  title: Text(
                      chat.unreadCount > 0 ? 'Mark as read' : 'Mark as unread'),
                  onTap: () => act(() => chat.unreadCount > 0
                      ? store.markRead(chat.id)
                      : store.markUnread(chat.id)),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Add to folder'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showChatFolderPicker(context, chat.id);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.low_priority_outlined),
                  title: const Text('Inbox tier'),
                  subtitle: Text(InboxTiers.instance.tierFor(chat).label),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showTierPicker(chat);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('Archive chat'),
                  onTap: () => act(() => store.setArchived(chat.id, true)),
                ),
                if (ChatLock.instance.isLocked(chat.id) &&
                    ChatLock.instance.isOpen(chat.id))
                  ListTile(
                    leading: Icon(ChatLock.instance.isHidden(chat.id)
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    title: Text(ChatLock.instance.isHidden(chat.id)
                        ? 'Show in chat list'
                        : 'Hide from chat list'),
                    subtitle: ChatLock.instance.isHidden(chat.id)
                        ? null
                        : const Text('Only its password brings it back'),
                    onTap: () => act(() => ChatLock.instance
                        .setHidden(chat.id, !ChatLock.instance.isHidden(chat.id))),
                  ),
                ListTile(
                  leading: Icon(ChatLock.instance.isLocked(chat.id)
                      ? Icons.lock_open_outlined
                      : Icons.lock_outline),
                  title: Text(ChatLock.instance.isLocked(chat.id)
                      ? 'Remove lock'
                      : 'Lock chat'),
                  subtitle: ChatLock.instance.isLocked(chat.id)
                      ? null
                      : const Text('Its own password, and optionally hidden'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    if (!mounted) return;
                    final locked = ChatLock.instance.isLocked(chat.id);
                    if (locked) {
                      await askForChatPassword(context, chat.id,
                          chatName: chat.contact.name, remove: true);
                    } else {
                      await askToLockChat(context, chat.id,
                          chatName: chat.contact.name);
                    }
                    if (mounted) setState(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Delete chat',
                      style: TextStyle(color: Colors.red)),
                  onTap: () => act(() {
                    store.deleteChat(chat.id);
                    // Otherwise the lock outlives the conversation, and a chat
                    // recreated with the same id would arrive already locked
                    // with a password nobody remembers setting.
                    ChatLock.instance.forget(chat.id);
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A plain ListTile + manual checkmark, not RadioListTile — its group API
  /// is deprecated in this Flutter (see `form_fill_screen.dart`'s choice
  /// chips for the same call).
  void _showTierPicker(Chat chat) {
    final auto = InboxTiering.autoTierFor(chat);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final current = InboxTiers.instance.overrideFor(chat.id);
        Widget tile(String label, String subtitle, InboxTier? tier) =>
            ListTile(
              title: Text(label),
              subtitle: Text(subtitle),
              trailing: current == tier
                  ? Icon(Icons.check, color: AppColors.accentOn(context))
                  : null,
              onTap: () {
                InboxTiers.instance.setOverride(chat.id, tier);
                Navigator.of(sheetContext).pop();
              },
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile('Auto (${auto.label})',
                  'Follows the rule for this chat', null),
              for (final t in InboxTier.values) tile(t.label, t.description, t),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return ListenableBuilder(
      // The streak store is in here because each row wears a streak flame:
      // a streak reconciled off the relay changes no chat, so nothing else
      // would redraw the list.
      listenable: Listenable.merge([
        store,
        OnboardingStore.instance,
        StreakStore.instance,
        // The folder tabs live in this list's filter strip, so creating or
        // renaming one has to redraw it.
        ChatFolders.instance,
      ]),
      builder: (context, _) {
        final content = _content(context, store);
        // A sanction has to be *said*. Silently losing the directory, push,
        // and the ability to send reads as a broken app, not a decision.
        return Column(
          children: [
            const SanctionNotice(),
            if (!OnboardingStore.instance.done)
              _GetStartedCard(onDismiss: OnboardingStore.instance.complete),
            // Only exists while there is something waiting: a permanent empty
            // folder would advertise a feature; a row with a count is news.
            if (store.requestCount > 0)
              _RequestsRow(count: store.requestCount),
            // Same rule as requests: the folder exists only while there is
            // something in it, so a fresh account never sees an empty shelf.
            if (store.marketplaceChats.isNotEmpty)
              _MarketplaceRow(
                  count: store.marketplaceChats.length,
                  unread: store.marketplaceUnread),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _content(BuildContext context, ChatStore store) {
    return Builder(
      builder: (context) {
        final allChats = store.chats;
        if (allChats.isEmpty) {
          return RefreshIndicator(
            onRefresh: PullToRefresh.refreshApp,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                _EmptyChats(),
              ],
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: ChatsTab.filtersVisible,
          builder: (context, showFilters, _) {
            final folderNamesRaw = ChatFolders.instance.folders;

            // When the filter bar is hidden the list is unfiltered, so
            // nothing is silently scoped away behind a collapsed bar — but
            // FOLDERS still get a strip, or somebody who made folders would
            // have nowhere to see the tabs they just created. It carries All
            // plus their folders and nothing else: hiding the bar was a
            // decision about Unread/Favourites/Groups, not about these.
            if (!showFilters && folderNamesRaw.isEmpty) {
              return _buildList(store, allChats);
            }

            // Favourites only appears as a filter once something is
            // favourited, so the row stays uncluttered on a fresh account.
            // The three Smart Inbox tiers ride the same strip — one more set
            // of chips, not a second bar to toggle.
            final filters = showFilters
                ? <ChatFilter>[
                    ChatFilter.all,
                    ChatFilter.unread,
                    if (store.hasFavorites) ChatFilter.favorites,
                    ChatFilter.groups,
                    ChatFilter.priority,
                    ChatFilter.general,
                    ChatFilter.occasional,
                  ]
                : <ChatFilter>[ChatFilter.all];
            // A previously-selected filter (e.g. Favourites) can disappear
            // from the row; fall back to All so the list never hides
            // everything.
            final active =
                filters.contains(_filter) ? _filter : ChatFilter.all;
            // A folder deleted (or renamed) elsewhere must not leave the list
            // scoped to a tab that no longer exists — that reads as every
            // chat vanishing.
            final folderNames = folderNamesRaw;
            final folder =
                _folder != null && folderNames.contains(_folder) ? _folder : null;
            final chats = folder != null
                ? allChats
                    .where((c) => ChatFolders.instance.contains(folder, c.id))
                    .toList()
                : allChats.where(active.matches).toList();
            return Column(
              children: [
                _FilterBar(
                  filters: filters,
                  active: active,
                  folders: folderNames,
                  activeFolder: folder,
                  onChanged: (f) => setState(() {
                    _filter = f;
                    _folder = null;
                  }),
                  onFolder: (f) => setState(() => _folder = f),
                  onManage: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ChatFoldersScreen())),
                ),
                Expanded(
                  child: chats.isEmpty
                      ? (folder != null
                          ? _EmptyFolder(folder: folder)
                          : _EmptyFilter(filter: active))
                      : _buildList(store, chats),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildList(ChatStore store, List<Chat> chats) {
    return RefreshIndicator(
      onRefresh: PullToRefresh.refreshApp,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating glass bar, measured rather than guessed.
        // The old constant 96 was SHORT of it on a home-indicator
        // iPhone, so the last row sat under the glass.
        padding: EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
        itemCount: chats.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          indent: 84,
          thickness: 0.4,
        ),
        itemBuilder: (context, index) {
            final chat = chats[index];
            return Dismissible(
              key: ValueKey('chatrow_${chat.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: AppColors.accentOn(context),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.archive, color: Colors.white),
              ),
              onDismissed: (_) {
                final messenger = ScaffoldMessenger.of(context);
                store.setArchived(chat.id, true);
                messenger.showSnackBar(SnackBar(
                  content: const Text('Chat archived'),
                  action: SnackBarAction(
                    label: 'Undo',
                    onPressed: () => store.setArchived(chat.id, false),
                  ),
                ));
              },
              child: ChatListTile(
                chat: chat,
                onTap: () => _openChat(chat),
                onLongPress: () => _showChatActions(chat),
              ),
            );
            },
          ),
        );
  }
}

/// The "Message requests (N)" row pinned above the chat list while any
/// stranger's first message is waiting on a decision.
class _RequestsRow extends StatelessWidget {
  final int count;
  const _RequestsRow({required this.count});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: accent.withValues(alpha: 0.14),
        child: Icon(Icons.mark_email_unread_outlined, color: accent),
      ),
      title: const Text('Message requests',
          style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          '$count ${count == 1 ? 'person' : 'people'} you haven\'t talked to',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$count',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const MessageRequestsScreen())),
    );
  }
}

/// The Marketplace folder row: buyer and seller conversations live behind
/// it instead of between friends. Only drawn while it holds something.
class _MarketplaceRow extends StatelessWidget {
  final int count;
  final int unread;
  const _MarketplaceRow({required this.count, required this.unread});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: accent.withValues(alpha: 0.14),
        child: Icon(Icons.storefront_outlined, color: accent),
      ),
      title: const Text('Marketplace',
          style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          '$count ${count == 1 ? 'conversation' : 'conversations'} about '
          'things for sale',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: unread == 0
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$unread',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const MarketplaceChatsScreen())),
    );
  }
}

/// A horizontal row of filter chips above the chat list.
class _FilterBar extends StatelessWidget {
  final List<ChatFilter> filters;
  final ChatFilter active;

  /// The user's own folder tabs, drawn after the built-in filters — Telegram's
  /// shape, and the reason this strip exists rather than a separate one.
  final List<String> folders;
  final String? activeFolder;

  final ValueChanged<ChatFilter> onChanged;
  final ValueChanged<String> onFolder;
  final VoidCallback onManage;

  const _FilterBar({
    required this.filters,
    required this.active,
    required this.folders,
    required this.activeFolder,
    required this.onChanged,
    required this.onFolder,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    // One folder chip per folder, then the manage affordance. It is an icon
    // chip rather than a row hidden in a menu, because a folder feature with
    // no visible way to make the first folder is a feature nobody finds.
    final total = filters.length + folders.length + 1;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: total,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i < filters.length) {
            final f = filters[i];
            return ChoiceChip(
              label: Text(f.label),
              // A built-in filter reads as selected only while no folder is,
              // or two chips would look active at once.
              selected: activeFolder == null && f == active,
              showCheckmark: false,
              onSelected: (_) => onChanged(f),
            );
          }
          if (i < filters.length + folders.length) {
            final name = folders[i - filters.length];
            return ChoiceChip(
              label: Text(name),
              selected: name == activeFolder,
              showCheckmark: false,
              onSelected: (_) => onFolder(name),
            );
          }
          return ActionChip(
            avatar: const Icon(Icons.folder_outlined, size: 18),
            label: Text(folders.isEmpty ? 'Folders' : 'Edit'),
            onPressed: onManage,
          );
        },
      ),
    );
  }
}

/// Shown when a folder tab is selected but holds nothing yet.
class _EmptyFolder extends StatelessWidget {
  final String folder;
  const _EmptyFolder({required this.folder});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(Icons.folder_outlined,
            size: 44, color: AppColors.subtle(context)),
        const SizedBox(height: 14),
        Text('Nothing in $folder yet',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          'Hold a chat and choose "Add to folder".',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, color: AppColors.subtle(context)),
        ),
      ],
    );
  }
}

/// Shown when the active filter matches no conversations.
class _EmptyFilter extends StatelessWidget {
  final ChatFilter filter;
  const _EmptyFilter({required this.filter});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text) = switch (filter) {
      ChatFilter.unread => (Icons.mark_chat_read_outlined, 'No unread chats'),
      ChatFilter.favorites => (
          Icons.star_border,
          'No favourite chats yet'
        ),
      ChatFilter.groups => (Icons.groups_outlined, 'No group chats'),
      ChatFilter.all => (Icons.chat_bubble_outline, 'No chats'),
      ChatFilter.priority => (Icons.star_border, 'Nothing in Priority yet'),
      ChatFilter.general => (Icons.chat_bubble_outline, 'Nothing in General'),
      ChatFilter.occasional => (
          Icons.label_outline,
          'Nothing in Occasional'
        ),
    };
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 90),
        EmptyState(
          icon: icon,
          title: text,
          caption: 'Chats matching this filter will show up here.',
        ),
      ],
    );
  }
}

/// One-time "get started" nudge shown to new users above the chat list,
/// guiding them to set up a profile and find people. Dismissible; never
/// reappears once dismissed.
class _GetStartedCard extends StatelessWidget {
  final VoidCallback onDismiss;
  const _GetStartedCard({required this.onDismiss});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Welcome to OkayMessenger 👋',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Text('Get set up in a few taps.',
                style: TextStyle(
                    fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
          ),
          ValueListenableBuilder<AppUser>(
            valueListenable: AppState.profile,
            builder: (context, me, _) => _StepRow(
              icon: Icons.person_outline,
              title: 'Set up your profile',
              subtitle: 'Name, avatar emoji, username',
              // Done once they've picked a username or an avatar emoji.
              done: me.username.isNotEmpty || me.emoji.isNotEmpty,
              onTap: () => _push(context, const EditProfileScreen()),
            ),
          ),
          _StepRow(
            icon: Icons.alternate_email,
            title: 'Find people by username',
            subtitle: 'Search and start chatting',
            onTap: () => _push(context, const FindPeopleScreen()),
          ),
          if (ContactsSync.instance.supported)
            _StepRow(
              icon: Icons.contacts_outlined,
              title: 'Find your contacts',
              subtitle: 'See who already uses OkayMessenger',
              onTap: () => _push(context, const ContactsOnAppScreen()),
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool done;
  final VoidCallback onTap;
  const _StepRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.done = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context))),
                ],
              ),
            ),
            done
                ? const Icon(Icons.check_circle, size: 20, color: Colors.green)
                : const Icon(Icons.chevron_right,
                    size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

/// Friendly empty state for the chats list.
class _EmptyChats extends StatelessWidget {
  const _EmptyChats();

  @override
  Widget build(BuildContext context) {
    // It used to say "tap the compose button" and point at an icon in the
    // corner. A blank screen that names an action should carry it.
    return EmptyState(
      icon: Icons.chat_bubble_outline,
      title: 'No chats yet',
      caption: 'Start a private, end-to-end encrypted conversation.',
      actionLabel: 'Start a chat',
      onAction: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NewChatScreen()),
      ),
    );
  }
}
