import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../theme/app_theme.dart';

import '../models/chat.dart';
import '../models/feed_notification.dart';
import '../state/call_log.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/feed_store.dart';
import '../screens/chat_screen.dart';
import '../screens/communities.dart';
import '../screens/feed_screen.dart';
import '../screens/public_feed_screen.dart';
import '../utils/date_formatter.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';

/// The Notifications tab: everything that happened while you were away —
/// unread messages, missed calls, and new server posts — built purely from
/// real local state (no invented activity). Mark-all-read and
/// swipe-to-clear.
///
/// **No All / Messages / Calls / Servers chips** (removed 2026-08-14, the
/// owner's call). The list is already sectioned by exactly those headings,
/// and it is short — this is what has happened since you last looked, not an
/// archive — so the chips cost a row of chrome to filter something you can
/// see all of anyway. "All" was also selected essentially always, which is
/// the shape of a control nobody needs.
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key});

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  void _openChat(BuildContext context, Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  // Open to numberless accounts: unread messages and missed calls are local
  // state and chat/calls both work without a session, so locking the tab hid
  // real activity. What a numberless account never gets is feed mentions —
  // the feeds themselves stay gated — and an empty section is the honest
  // shape of that.
  @override
  Widget build(BuildContext context) => Builder(builder: _guarded);

  Widget _guarded(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ChatStore.instance, CallLog.instance, FeedStore.instance]),
      builder: (context, _) {
        final unread =
            ChatStore.instance.chats.where((c) => c.unreadCount > 0).toList()
              ..sort((a, b) {
                final at =
                    a.messages.isEmpty ? DateTime(2000) : a.messages.last.time;
                final bt =
                    b.messages.isEmpty ? DateTime(2000) : b.messages.last.time;
                return bt.compareTo(at);
              });
        final missed = CallLog.instance.missedAlerts.take(10).toList();
        final posts = FeedStore.instance.recentPosts(limit: 5);
        // Interactions that name you come first — they're the most personal.
        final mentions = FeedStore.instance.notifications.take(15).toList();

        final somethingVisible = unread.isNotEmpty ||
            missed.isNotEmpty ||
            mentions.isNotEmpty ||
            posts.isNotEmpty;

        return !somethingVisible
            ? PullToRefresh.emptyState(child: _empty(context))
            : PullToRefresh(
                child: ListView(
                  // Clear the floating glass bar, measured rather
                  // than guessed. The old constant 96 was SHORT of it
                  // on a home-indicator iPhone, so the last row sat
                  // under the glass.
                  padding:
                      EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
                  children: [
                    if (unread.isNotEmpty) ...[
                      _sectionLabel(context, 'NEW MESSAGES'),
                      for (final chat in unread)
                        Dismissible(
                          key: ValueKey('unread_${chat.id}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBg(),
                          // Swiping away = mark read (the chat stays).
                          onDismissed: (_) =>
                              ChatStore.instance.markRead(chat.id),
                          child: ListTile(
                            leading: UserAvatar(user: chat.contact, radius: 22),
                            title: Text(chat.contact.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              // The real last line — and for a photo,
                              // voice note, poll, etc. its type rather
                              // than a flat "New message". This list is
                              // on-device, so the decrypted text is fair
                              // to show here.
                              chat.messages.isEmpty
                                  ? 'New messages'
                                  : chat.messages.last.previewLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              // onPrimary, not white. In the dark theme
                              // the accent flips to near-white, so a
                              // white numeral on it was an unread count
                              // you could not read.
                              child: Text(
                                '${chat.unreadCount}',
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.onPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            onTap: () => _openChat(context, chat),
                          ),
                        ),
                    ],
                    if (missed.isNotEmpty) ...[
                      _sectionLabel(context, 'MISSED CALLS'),
                      for (final r in missed)
                        // Deletes the ALERT, never the call: the row in
                        // call history stays, because a swipe on a
                        // notification must not quietly erase history.
                        Dismissible(
                          key: ValueKey('missed_${r.id}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBg(icon: Icons.delete_outline),
                          onDismissed: (_) =>
                              CallLog.instance.dismissMissedAlert(r.id),
                          child: ListTile(
                            leading: UserAvatar(user: r.user, radius: 22),
                            title: Text(r.user.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text('Missed ${r.type.name} call · '
                                '${DateFormatter.callLabel(r.time)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.call_missed,
                                    color: Colors.red),
                                IconButton(
                                  icon: const Icon(Icons.call),
                                  tooltip: 'Call back',
                                  onPressed: () => CallService.instance
                                      .startOutgoing(r.user, video: false),
                                ),
                              ],
                            ),
                            onTap: () {
                              final chat =
                                  ChatStore.instance.chatWithContact(r.user.id);
                              if (chat != null) {
                                _openChat(context, chat);
                              }
                            },
                          ),
                        ),
                    ],
                    if (mentions.isNotEmpty) ...[
                      _sectionLabel(context, 'MENTIONS & REPLIES'),
                      for (final n in mentions)
                        // Swipe it away, like an unread chat above —
                        // except this one really is deleted: an alert
                        // is this device's note that something
                        // happened, not a thing anybody else can see.
                        Dismissible(
                          key: ValueKey('notif_${n.id}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBg(icon: Icons.delete_outline),
                          onDismissed: (_) =>
                              FeedStore.instance.dismissNotification(n.id),
                          child: ListTile(
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  child: Text(n.actorName.isEmpty
                                      ? '?'
                                      : n.actorName[0].toUpperCase()),
                                ),
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .scaffoldBackgroundColor,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(_notifIcon(n.type),
                                        size: 14,
                                        color: switch (n.type) {
                                          FeedNotificationType.like =>
                                            const Color(0xFFF91880),
                                          FeedNotificationType.spark =>
                                            const Color(0xFFF7931A),
                                          _ => Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        }),
                                  ),
                                ),
                              ],
                            ),
                            title: Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: n.actorName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              TextSpan(text: ' ${_notifVerb(n.type)}'),
                              if (n.isChannel)
                                TextSpan(
                                    text: ' in #${n.channelName}',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                            ])),
                            subtitle: n.preview.isEmpty
                                ? null
                                : Text(n.preview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!n.seen)
                                  Container(
                                    width: 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                Text(DateFormatter.callLabel(n.time),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.subtle(context))),
                                // A swipe is quick and undiscoverable;
                                // this is the same two actions where
                                // somebody can find them.
                                IconButton(
                                  icon: const Icon(Icons.more_horiz, size: 18),
                                  tooltip: 'Alert options',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _alertActions(context, n),
                                ),
                              ],
                            ),
                            onLongPress: () => _alertActions(context, n),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                // A channel mention opens the channel; a
                                // feed one opens the thread — and which
                                // thread screen depends on which feed it
                                // came from, since the public timeline and a
                                // server's own feed are different stores.
                                builder: (_) => n.isChannel
                                    ? ChannelScreen(
                                        communityId: n.communityId,
                                        channelId: n.channelId)
                                    // A follow names a PERSON, not a post,
                                    // so it is the only one that opens a
                                    // profile — and the only one whose
                                    // threadPostId is empty.
                                    : n.type == FeedNotificationType.follow
                                        ? PublicProfileScreen(
                                            username: n.actorUsername,
                                            name: n.actorName)
                                        : n.publicFeed
                                            ? PublicThreadScreen(
                                                postId: n.threadPostId)
                                            : FeedPostScreen(
                                                postId: n.threadPostId),
                              ),
                            ),
                          ),
                        ),
                    ],
                    if (posts.isNotEmpty) ...[
                      _sectionLabel(context, 'NEW IN YOUR SERVERS'),
                      for (final p in posts)
                        // Dismisses the alert only — the post stays in
                        // its server's feed. Hiding it everywhere from
                        // a swipe here would be the bigger action under
                        // the smaller gesture.
                        Dismissible(
                          key: ValueKey('srvpost_${p.id}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBg(icon: Icons.delete_outline),
                          onDismissed: (_) =>
                              FeedStore.instance.dismissAlertPost(p.id),
                          child: ListTile(
                            leading: CircleAvatar(
                              radius: 22,
                              child: Text(p.authorName.isEmpty
                                  ? '?'
                                  : p.authorName[0].toUpperCase()),
                            ),
                            title: Text(p.authorName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(p.text,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: Text(DateFormatter.callLabel(p.time),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.subtle(context))),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => FeedPostScreen(postId: p.id)),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              );
      },
    );
  }

  Widget _empty(BuildContext context) {
    return const EmptyState(
      icon: Icons.notifications_none,
      title: "You're all caught up",
      caption: 'New messages, missed calls and server posts land here.',
    );
  }

  /// The colour behind a swipe says which of the two things it does: green
  /// and a read-mark for "mark read", red and a bin for "delete". Same
  /// gesture, different outcome, and only the background says so.
  Widget _dismissBg({IconData icon = Icons.mark_chat_read}) => Container(
        color: icon == Icons.delete_outline ? Colors.red : Colors.green,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(icon, color: Colors.white),
      );

  /// Delete this alert, or stop getting them from this person.
  ///
  /// Muting is deliberately about ALERTS and not about the person: their
  /// replies still appear when the thread is opened. Muting somebody
  /// wholesale is a different control, on the newsfeed, and doing the larger
  /// thing from a row labelled "Mute notifications" would be a lie.
  Future<void> _alertActions(BuildContext context, FeedNotification n) async {
    final store = FeedStore.instance;
    final muted = store.notificationsMuted(n.actorUsername);
    final who = n.actorName.isEmpty ? 'them' : n.actorName;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete this alert'),
              onTap: () => Navigator.of(sheet).pop('delete'),
            ),
            if (n.actorUsername.isNotEmpty)
              ListTile(
                leading: Icon(muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined),
                title: Text(muted
                    ? 'Unmute notifications from $who'
                    : 'Mute notifications from $who'),
                subtitle: Text(muted
                    ? 'You will hear about their replies again'
                    : 'Their replies still show in the thread'),
                onTap: () => Navigator.of(sheet).pop('mute'),
              ),
            ListTile(
              leading: const Icon(Icons.clear_all),
              title: const Text('Clear all alerts'),
              subtitle:
                  const Text('Mentions, missed-call alerts and server posts. '
                      'Call history and the posts themselves stay.'),
              onTap: () => Navigator.of(sheet).pop('clear'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'delete':
        store.dismissNotification(n.id);
      case 'mute':
        final nowMuted = store.toggleNotificationMute(n.actorUsername);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(nowMuted
              ? 'Muted notifications from $who'
              : 'Unmuted notifications from $who'),
        ));
      case 'clear':
        // All three alert kinds, not just mentions — a row named "Clear all
        // alerts" that left two sections standing would be mislabelled.
        store.clearNotifications();
        CallLog.instance.dismissAllMissedAlerts();
        store.dismissAlertPosts(store.recentPosts().map((p) => p.id).toList());
    }
  }

  Widget _sectionLabel(BuildContext context, String text) =>
      SectionHeader(text);

  IconData _notifIcon(FeedNotificationType t) => switch (t) {
        FeedNotificationType.reply => Icons.reply,
        FeedNotificationType.mention => Icons.alternate_email,
        FeedNotificationType.repost => Icons.repeat,
        FeedNotificationType.like => Icons.favorite,
        FeedNotificationType.spark => Icons.bolt,
        FeedNotificationType.review => Icons.star,
        FeedNotificationType.follow => Icons.person_add_alt_1,
        FeedNotificationType.channelMention => Icons.tag,
      };

  String _notifVerb(FeedNotificationType t) => switch (t) {
        FeedNotificationType.reply => 'replied to you',
        FeedNotificationType.mention => 'mentioned you',
        FeedNotificationType.repost => 'reposted you',
        FeedNotificationType.like => 'liked your post',
        FeedNotificationType.spark => 'sparked your post',
        FeedNotificationType.review => 'reviewed your listing',
        FeedNotificationType.follow => 'followed you',
        FeedNotificationType.channelMention => 'mentioned you',
      };
}
