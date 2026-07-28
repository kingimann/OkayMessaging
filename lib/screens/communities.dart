import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/community_store.dart';
import '../state/channel_typing_store.dart';
import '../state/voice_presence_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../state/feed_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/poll_widgets.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/user_avatar.dart';
import 'community_settings_screen.dart';
import 'feed_screen.dart';
import 'forum_screen.dart';
import 'forward_screen.dart';

Color _hex(String s) =>
    Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

IconData _channelIcon(ChannelType type) => switch (type) {
      ChannelType.voice => Icons.volume_up_rounded,
      ChannelType.announcement => Icons.campaign_rounded,
      ChannelType.forum => Icons.forum_rounded,
      ChannelType.text => Icons.tag,
    };

/// Prompts for a name, creates a community and opens it. Called from the
/// home screen's compose button when the Communities tab is active.
Future<void> createCommunityFlow(BuildContext context) async {
  final name = await _promptName(context, 'New community', 'Community name');
  if (name == null || name.isEmpty) return;
  final community = CommunityStore.instance.createCommunity(name);
  if (context.mounted) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CommunityScreen(communityId: community.id)));
  }
}

/// The "Communities" tab: Discord-style servers you can create and open,
/// shown as tappable cards.
/// Case-insensitive server search over name and description. Pure.
List<Community> filterCommunities(List<Community> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return [
    for (final c in all)
      if (c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q))
        c
  ];
}

/// A member name as a single-word mention token, since a mention has to be one
/// word to be recognised: "Ada Lovelace" → "AdaLovelace". Pure.
String mentionToken(String name) => name.replaceAll(RegExp(r'[^\w]'), '');

/// The partial mention being typed right before [caret], or null when the
/// caret isn't inside one. Returns the text after the "@". Pure.
String? mentionPrefix(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final upTo = text.substring(0, caret);
  final at = upTo.lastIndexOf('@');
  if (at == -1) return null;
  // Must start a word, and hold no whitespace between "@" and the caret.
  if (at > 0 && !RegExp(r'\s').hasMatch(upTo[at - 1])) return null;
  final frag = upTo.substring(at + 1);
  if (frag.contains(RegExp(r'\s'))) return null;
  return frag;
}

/// Case-insensitive filter over channel messages, matching text, poll
/// questions, and sender names. Pure enough to test.
List<Message> filterMessages(List<Message> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return [
    for (final m in all)
      if (m.text.toLowerCase().contains(q) ||
          m.pollQuestion.toLowerCase().contains(q) ||
          m.senderName.toLowerCase().contains(q))
        m
  ];
}

class CommunitiesTab extends StatefulWidget {
  const CommunitiesTab({super.key});

  @override
  State<CommunitiesTab> createState() => _CommunitiesTabState();
}

class _CommunitiesTabState extends State<CommunitiesTab> {
  final TextEditingController _search = TextEditingController();

  /// Pulls the server's copy of the communities back down, then rebuilds.
  Future<void> _refresh() => PullToRefresh.refreshApp(
      extra: () async => CommunityStore.instance.touch());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [CommunityStore.instance, VoicePresenceStore.instance]),
      builder: (context, _) {
        final all = CommunityStore.instance.communities;
        final communities = filterCommunities(all, _search.text);
        return RefreshIndicator(
          onRefresh: _refresh,
          child: all.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [SizedBox(height: 100), _Empty()],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search servers',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: 'Clear server search',
                                  onPressed: () =>
                                      setState(() => _search.clear()),
                                ),
                          isDense: true,
                          filled: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    if (communities.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text('No servers match your search.',
                              style:
                                  TextStyle(color: Colors.grey.shade600)),
                        ),
                      ),
                    for (final c in communities) _CommunityCard(community: c),
                  ],
                ),
        );
      },
    );
  }
}

/// The rounded unread-count pill used on channel rows and server cards.
class _UnreadBadge extends StatelessWidget {
  final int count;

  /// A muted channel still counts what you missed, but in grey — it shouldn't
  /// compete for attention with the channels you actually follow.
  final bool muted;
  const _UnreadBadge({required this.count, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? scheme.surfaceContainerHighest : scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
            color: muted ? scheme.onSurfaceVariant : scheme.onPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// A single community rendered as a rounded card with a gradient badge.
/// An "@" badge for unread mentions. Distinct from [_UnreadBadge] on purpose:
/// a count of messages and a count of times someone said your name are not
/// the same news, and shouldn't look the same.
class _MentionBadge extends StatelessWidget {
  final int count;
  const _MentionBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFE0245E),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.alternate_email, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text('$count',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _CommunityCard extends StatelessWidget {
  final Community community;
  const _CommunityCard({required this.community});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = _hex(community.color);
    final online = community.members.where((m) => m.online).length;
    final channels = community.channels.length;
    final members = community.members.length;
    final inVoice = VoicePresenceStore.instance.countInChannels([
      for (final c in community.channels)
        if (c.type == ChannelType.voice) c.id
    ]);
    final mentions =
        CommunityStore.instance.unreadMentionsInCommunity(community);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: isDark ? const Color(0xFF20232A) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        elevation: isDark ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CommunityScreen(communityId: community.id))),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        base,
                        Color.lerp(base, Colors.black, 0.28) ?? base,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    community.icon.isNotEmpty
                        ? community.icon
                        : (community.name.isEmpty
                            ? '?'
                            : community.name[0].toUpperCase()),
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: community.icon.isNotEmpty
                            ? FontWeight.w400
                            : FontWeight.w800,
                        fontSize: 24),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(community.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700)),
                          ),
                          if (CommunityStore.instance
                                  .unreadInCommunity(community) >
                              0) ...[
                            const SizedBox(width: 8),
                            _UnreadBadge(
                                count: CommunityStore.instance
                                    .unreadInCommunity(community)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _meta(Icons.tag, '$channels'),
                          const SizedBox(width: 14),
                          _meta(Icons.people_alt_outlined, '$members'),
                          if (online > 0) ...[
                            const SizedBox(width: 14),
                            const Icon(Icons.circle,
                                size: 8, color: Color(0xFF43B581)),
                            const SizedBox(width: 4),
                            Text('$online online',
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF43B581),
                                    fontWeight: FontWeight.w600)),
                          ],
                          // Live off the community bus, so this is the one
                          // number on the card that reflects real activity.
                          if (inVoice > 0) ...[
                            const SizedBox(width: 14),
                            Icon(Icons.volume_up_rounded,
                                size: 14, color: Colors.green.shade600),
                            const SizedBox(width: 4),
                            Text('$inVoice in voice',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.green.shade600,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ],
                      ),
                      if (community.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(community.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5, color: Colors.grey.shade600)),
                      ],
                    ],
                  ),
                ),
                if (mentions > 0) ...[
                  _MentionBadge(count: mentions),
                  const SizedBox(width: 4),
                ],
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
        ],
      );
}

/// A single community: its channels grouped by collapsible category, plus
/// actions to invite people, add a channel, or view members.
class CommunityScreen extends StatefulWidget {
  final String communityId;
  const CommunityScreen({super.key, required this.communityId});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  String get communityId => widget.communityId;

  /// Category headers the user has folded shut this visit.
  final Set<String> _collapsed = {};

  Future<void> _addChannel(BuildContext context) async {
    final result = await _promptNewChannel(context);
    if (result == null) return;
    CommunityStore.instance
        .addChannel(communityId, result.$1, type: result.$2);
  }

  void _openMembers(BuildContext context, Community community) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _MembersSheet(community: community),
    );
  }

  void _invite(BuildContext context, Community community) {
    final link = CommunityStore.inviteLink(community);
    final code = CommunityStore.inviteCode(community);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Invite to ${community.name}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Anyone with this link can join the server.',
                  style:
                      TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(link,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'Copy invite link',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: link));
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite link copied')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text('Or share the code  $code',
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              const SizedBox(height: 12),
              // The invite that actually works end-to-end: a card in a chat
              // the other person can join with one tap.
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: const Text('Send invite to a chat'),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _sendInviteToChat(context, community);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendInviteToChat(BuildContext context, Community community) {
    final me = AppState.profile.value;
    final snapshot = CommunityStore.instance.exportInvite(
      community.id,
      myDigits: me.phone.replaceAll(RegExp(r'\D'), ''),
      myName: me.name,
    );
    if (snapshot == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ForwardScreen(
        text: 'Join my server "${community.name}"',
        invite: jsonEncode(snapshot),
      ),
    ));
  }

  Future<void> _channelActions(
      BuildContext context, Channel ch) async {
    final store = CommunityStore.instance;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_channelIcon(ch.type)),
              title: Text(ch.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: ch.topic.isEmpty ? null : Text(ch.topic),
            ),
            const Divider(height: 1),
            // Muting is personal and needs no permission, so it leads.
            ListTile(
                leading: Icon(store.isChannelMuted(ch.id)
                    ? Icons.notifications_off
                    : Icons.notifications_none),
                title: Text(store.isChannelMuted(ch.id)
                    ? 'Unmute channel'
                    : 'Mute channel'),
                subtitle: store.isChannelMuted(ch.id)
                    ? null
                    : const Text('Stop it badging this server'),
                onTap: () => Navigator.pop(context, 'mute')),
            ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename channel'),
                onTap: () => Navigator.pop(context, 'rename')),
            ListTile(
                leading: const Icon(Icons.notes_rounded),
                title: const Text('Edit topic'),
                onTap: () => Navigator.pop(context, 'topic')),
            ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('Move to category'),
                onTap: () => Navigator.pop(context, 'move')),
            ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete channel',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(context, 'delete')),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'mute':
        store.toggleChannelMute(ch.id);
        return;
      case 'rename':
        final name = await _promptName(context, 'Rename channel', ch.name);
        if (name != null && name.isNotEmpty) {
          store.renameChannel(communityId, ch.id, name);
        }
        break;
      case 'topic':
        final topic = await _promptName(
            context, 'Channel topic', ch.topic.isEmpty ? 'Topic' : ch.topic);
        if (topic != null) store.setChannelTopic(communityId, ch.id, topic);
        break;
      case 'move':
        await _moveToCategory(context, ch);
        break;
      case 'delete':
        store.deleteChannel(communityId, ch.id);
        break;
    }
  }

  /// Picks an existing category (or names a new one) and moves [ch] there.
  Future<void> _moveToCategory(BuildContext context, Channel ch) async {
    final community = CommunityStore.instance.byId(communityId);
    if (community == null) return;
    final categories = community.categories;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final cat in categories)
              ListTile(
                leading: Icon(
                    cat == ch.category
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: cat == ch.category
                        ? Theme.of(sheetContext).colorScheme.primary
                        : Colors.grey),
                title: Text(cat),
                onTap: () => Navigator.pop(sheetContext, cat),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New category…'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    var target = picked;
    if (target.isEmpty) {
      final name = await showAppTextPrompt(
        context,
        icon: Icons.drive_file_move_outlined,
        title: 'New category',
        hint: 'Category name',
        confirmLabel: 'Move',
        capitalization: TextCapitalization.words,
      );
      if (name == null || name.trim().isEmpty) return;
      target = name.trim();
    }
    CommunityStore.instance.setChannelCategory(communityId, ch.id, target);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [CommunityStore.instance, VoicePresenceStore.instance]),
      builder: (context, _) {
        final community = CommunityStore.instance.byId(communityId);
        if (community == null) {
          return const Scaffold(body: Center(child: Text('Community not found')));
        }
        final onlineCount = community.members.where((m) => m.online).length;
        final voiceHere = VoicePresenceStore.instance.countInChannels([
          for (final c in community.channels)
            if (c.type == ChannelType.voice) c.id
        ]);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: _hex(community.color),
                  child: Text(
                      community.icon.isNotEmpty
                          ? community.icon
                          : community.name[0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(community.name,
                        overflow: TextOverflow.ellipsis)),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.people_alt_outlined),
                tooltip: 'Members',
                onPressed: () => _openMembers(context, community),
              ),
              if (CommunityStore.instance.canCreateChannels(communityId))
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add channel',
                  onPressed: () => _addChannel(context),
                ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Server settings',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        CommunitySettingsScreen(communityId: communityId))),
              ),
            ],
          ),
          body: ListView(
            children: [
              // A colour-washed banner gives each server its own identity.
              Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _hex(community.color),
                      _hex(community.color).withValues(alpha: 0.55),
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.white.withValues(alpha: 0.25),
                      child: Text(
                        community.icon.isNotEmpty
                            ? community.icon
                            : (community.name.isEmpty
                                ? '?'
                                : community.name[0].toUpperCase()),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        community.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                    // Growing the server is the banner's one call to action.
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.22),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.person_add_alt_1, size: 17),
                      label: const Text('Invite',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      onPressed: () => _invite(context, community),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.circle, size: 9, color: Color(0xFF43B581)),
                    const SizedBox(width: 6),
                    Text('$onlineCount online · ${community.members.length} members',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade600)),
                    if (voiceHere > 0) ...[
                      const SizedBox(width: 10),
                      Icon(Icons.volume_up_rounded,
                          size: 14, color: Colors.green.shade600),
                      const SizedBox(width: 4),
                      Text('$voiceHere in voice',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade600)),
                    ],
                  ],
                ),
              ),
              // A face wall of members makes the server feel inhabited.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                child: SizedBox(
                  height: 34,
                  child: Stack(
                    children: [
                      for (var i = 0;
                          i < community.members.length && i < 9;
                          i++)
                        Positioned(
                          left: i * 24.0,
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor:
                                Theme.of(context).colorScheme.surface,
                            child: CircleAvatar(
                              radius: 14,
                              backgroundColor: Colors.primaries[
                                      community.members[i].name.hashCode %
                                          Colors.primaries.length]
                                  .shade600,
                              child: Text(
                                community.members[i].name.isEmpty
                                    ? '?'
                                    : community.members[i].name[0]
                                        .toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (community.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  child: Text(community.description,
                      style: TextStyle(
                          fontSize: 13.5, color: Colors.grey.shade700)),
                ),
              // The server's X-style feed lives above the channel list.
              ListenableBuilder(
                listenable: FeedStore.instance,
                builder: (context, _) {
                  final latest = FeedStore.instance.postsFor(communityId);
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.dynamic_feed,
                        color: Theme.of(context).colorScheme.primary,
                        size: 22),
                    title: const Text('Feed',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      latest.isEmpty
                          ? 'Posts from members'
                          : '${latest.first.authorName}: '
                              '${latest.first.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => FeedScreen(
                        communityId: communityId,
                        communityName: community.name,
                      ),
                    )),
                  );
                },
              ),
              for (final category in community.categories) ...[
                // Tappable header folds its channels away, Discord-style.
                InkWell(
                  onTap: () => setState(() {
                    if (!_collapsed.remove(category)) {
                      _collapsed.add(category);
                    }
                  }),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: _collapsed.contains(category) ? -0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: const Icon(Icons.expand_more,
                              size: 16, color: Colors.grey),
                        ),
                        const SizedBox(width: 4),
                        Text(category.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: Colors.grey)),
                        if (_collapsed.contains(category)) ...[
                          const SizedBox(width: 6),
                          Text('${community.channelsIn(category).length}',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500)),
                        ],
                      ],
                    ),
                  ),
                ),
                if (!_collapsed.contains(category))
                for (final ch in community.channelsIn(category))
                  Builder(builder: (context) {
                  final muted = CommunityStore.instance.isChannelMuted(ch.id);
                  final unread = CommunityStore.instance.unreadInChannel(ch);
                  final mentions =
                      CommunityStore.instance.unreadMentionsIn(ch);
                  final voice = ch.type == ChannelType.voice
                      ? VoicePresenceStore.instance.occupantsIn(ch.id)
                      : const <VoiceOccupant>[];
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  ListTile(
                    dense: true,
                    leading: Icon(_channelIcon(ch.type),
                        // A muted channel never highlights, however busy it is
                        // — unless someone actually said your name.
                        color: mentions > 0
                            ? const Color(0xFFE0245E)
                            : (unread > 0 && !muted
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey),
                        size: 22),
                    title: Row(
                      children: [
                        Flexible(child: Text(ch.name)),
                        if (muted) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.notifications_off,
                              size: 14, color: Colors.grey.shade500),
                        ],
                        if (mentions > 0) ...[
                          const SizedBox(width: 8),
                          // Being @mentioned is the one thing a mute doesn't
                          // quieten: it means someone is talking *to* you.
                          _MentionBadge(count: mentions),
                        ] else if (unread > 0) ...[
                          const SizedBox(width: 8),
                          // Still counted so you can see what you missed —
                          // just muted-grey rather than shouting.
                          _UnreadBadge(count: unread, muted: muted),
                        ],
                      ],
                    ),
                    subtitle: ch.type == ChannelType.voice
                        ? Text(voice.isEmpty
                            ? 'Voice channel'
                            : '${voice.length} '
                                '${voice.length == 1 ? 'person' : 'people'} '
                                'in voice')
                        : ch.type == ChannelType.forum
                            ? Text('Forum · ${ch.posts.length} '
                                '${ch.posts.length == 1 ? 'post' : 'posts'}')
                            : (ch.messages.isNotEmpty
                                ? Text(ch.messages.last.text,
                                    maxLines: 1, overflow: TextOverflow.ellipsis)
                                : (ch.topic.isEmpty ? null : Text(ch.topic))),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert, size: 20),
                      tooltip: 'Channel options',
                      onPressed: () => _channelActions(context, ch),
                    ),
                    onLongPress: () => _channelActions(context, ch),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => switch (ch.type) {
                        ChannelType.voice => VoiceChannelScreen(
                            communityId: communityId, channelId: ch.id),
                        ChannelType.forum => ForumChannelScreen(
                            communityId: communityId, channelId: ch.id),
                        _ => ChannelScreen(
                            communityId: communityId, channelId: ch.id),
                      },
                    )),
                  ),
                  // Who's in the room, listed under it the way Discord does —
                  // the whole point of a voice channel is seeing it's occupied
                  // without having to open it.
                  for (final o in voice)
                    Padding(
                      padding: const EdgeInsets.only(left: 56, bottom: 2),
                      child: Row(
                        children: [
                          Icon(
                            o.screen
                                ? Icons.screen_share
                                : o.video
                                    ? Icons.videocam
                                    : o.muted
                                        ? Icons.mic_off
                                        : Icons.mic,
                            size: 14,
                            color: o.muted
                                ? Colors.red.shade300
                                : Colors.grey.shade500,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              o.isMe ? '${o.name} (you)' : o.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade600,
                                  fontWeight: o.isMe
                                      ? FontWeight.w600
                                      : FontWeight.w400),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (voice.isNotEmpty) const SizedBox(height: 6),
                    ],
                  );
                  }),
              ],
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

/// A voice channel "lobby": shows the members who could join and a local
/// join/leave toggle. Real group audio would ride the same WebRTC path as
/// 1:1 calls; here it's a presence lobby.
class VoiceChannelScreen extends StatefulWidget {
  final String communityId;
  final String channelId;
  const VoiceChannelScreen(
      {super.key, required this.communityId, required this.channelId});

  @override
  State<VoiceChannelScreen> createState() => _VoiceChannelScreenState();
}

class _VoiceChannelScreenState extends State<VoiceChannelScreen> {
  // Deafening is about what *this* device hears, so it stays local — everyone
  // else only needs to know it silences the mic. Mic/camera/screen state lives
  // in the presence store, which is what the rest of the server sees.
  bool _deafened = false;
  DateTime? _joinedAt;
  Timer? _tick;

  VoicePresenceStore get _voice => VoicePresenceStore.instance;
  bool get _joined => _voice.amIn(widget.channelId);

  VoiceOccupant? get _me {
    for (final o in _voice.occupantsIn(widget.channelId)) {
      if (o.isMe) return o;
    }
    return null;
  }

  bool get _muted => _me?.muted ?? false;
  bool get _video => _me?.video ?? false;
  bool get _screen => _me?.screen ?? false;

  @override
  void initState() {
    super.initState();
    // Rejoining a channel this device never left keeps the timer honest.
    if (_joined) _joinedAt = DateTime.now();
  }

  @override
  void dispose() {
    _tick?.cancel();
    // Leaving the screen leaves the room. Without this the rest of the server
    // would keep seeing you sitting in a channel you walked away from until
    // the heartbeat aged you out.
    if (_joined) _voice.leave();
    super.dispose();
  }

  void _join() {
    _voice.join(
      communityId: widget.communityId,
      channelId: widget.channelId,
      myName: AppState.profile.value.name,
    );
    setState(() => _joinedAt = DateTime.now());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _leave() {
    _tick?.cancel();
    _tick = null;
    _voice.leave();
    setState(() {
      _deafened = false;
      _joinedAt = null;
    });
  }

  String get _elapsed {
    final at = _joinedAt;
    if (at == null) return '';
    final d = DateTime.now().difference(at);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable:
          Listenable.merge([CommunityStore.instance, VoicePresenceStore.instance]),
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        if (channel == null) {
          return const Scaffold(body: Center(child: Text('Channel not found')));
        }
        // Who is actually here, live off the community bus — not a guess from
        // the roster's online flag.
        final occupants = _voice.occupantsIn(widget.channelId);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Icon(Icons.volume_up_rounded, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(channel.name, style: const TextStyle(fontSize: 17)),
                      if (_joined)
                        Text('Connected · $_elapsed',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.green)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(child: _grid(community!, channel, occupants)),
              _controlBar(),
            ],
          ),
        );
      },
    );
  }

  Widget _grid(
      Community community, Channel channel, List<VoiceOccupant> occupants) {
    if (occupants.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headset_mic_outlined,
                size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('No one is in ${channel.name}',
                style: TextStyle(color: Colors.grey.shade500)),
            const SizedBox(height: 4),
            Text('Join to start the conversation',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5)),
          ],
        ),
      );
    }
    final me = AppState.profile.value;
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.all(16),
      children: [
        for (final o in occupants)
          _memberTile(
            label: o.isMe ? 'You' : o.name,
            avatar: o.isMe
                ? UserAvatar(user: me, radius: 30)
                : CircleAvatar(
                    radius: 30,
                    backgroundColor: _hex(community.color),
                    child: Text(
                        o.name.isEmpty ? '?' : o.name[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700)),
                  ),
            // Nobody's mic is actually open yet — the ring means "not muted",
            // which is as much as presence can honestly claim.
            speaking: !o.muted && !(o.isMe && _deafened),
            muted: o.muted || (o.isMe && _deafened),
            deafened: o.isMe && _deafened,
            video: o.video,
            screen: o.screen,
          ),
      ],
    );
  }

  Widget _memberTile({
    required String label,
    required Widget avatar,
    bool speaking = false,
    bool muted = false,
    bool deafened = false,
    bool video = false,
    bool screen = false,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: speaking ? Colors.green : Colors.transparent,
              width: 3,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              if (muted || deafened || video || screen)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: deafened || muted ? Colors.red : Colors.black54,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Theme.of(context).canvasColor, width: 2),
                    ),
                    child: Icon(
                      deafened
                          ? Icons.headset_off
                          : muted
                              ? Icons.mic_off
                              : screen
                                  ? Icons.screen_share
                                  : Icons.videocam,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5)),
      ],
    );
  }

  Widget _controlBar() {
    return SafeArea(
      top: false,
      // The bottom inset alone leaves the button flush against the home
      // indicator, so add real space under it as well.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: _joined
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _voiceButton(
                    icon: _muted ? Icons.mic_off : Icons.mic,
                    label: _muted ? 'Unmute' : 'Mute',
                    color:
                        _muted ? Colors.grey.shade700 : AppColors.tealGreenDark,
                    onTap: () {
                      final nowMuted = !_muted;
                      if (!nowMuted) _deafened = false;
                      _voice.setLocalState(muted: nowMuted);
                      setState(() {});
                    },
                  ),
                  _voiceButton(
                    icon: _deafened ? Icons.headset_off : Icons.headset_mic,
                    label: 'Deafen',
                    color: _deafened ? Colors.red : Colors.grey.shade700,
                    onTap: () {
                      _deafened = !_deafened;
                      // Deafening also mutes you, à la Discord.
                      if (_deafened) _voice.setLocalState(muted: true);
                      setState(() {});
                    },
                  ),
                  _voiceButton(
                    icon: _video ? Icons.videocam : Icons.videocam_off,
                    label: 'Video',
                    color: _video ? AppColors.tealGreenDark : Colors.grey.shade700,
                    onTap: () => _voice.setLocalState(video: !_video),
                  ),
                  _voiceButton(
                    icon: _screen
                        ? Icons.stop_screen_share
                        : Icons.screen_share,
                    label: 'Screen',
                    color:
                        _screen ? AppColors.tealGreenDark : Colors.grey.shade700,
                    onTap: () => _voice.setLocalState(screen: !_screen),
                  ),
                  _voiceButton(
                    icon: Icons.call_end,
                    label: 'Leave',
                    color: Colors.red,
                    onTap: _leave,
                  ),
                ],
              )
            : SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentOn(context),
                    foregroundColor: AppColors.onAccent(context),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.headset_mic),
                  label: const Text('Join Voice'),
                  onPressed: _join,
                ),
              ),
      ),
    );
  }

  Widget _voiceButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    String? label,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          ],
        ],
      );
}

/// A channel's message view: a simple list plus a composer. Announcement
/// channels look the same but read as broadcast posts.
class ChannelScreen extends StatefulWidget {
  final String communityId;
  final String channelId;
  const ChannelScreen(
      {super.key, required this.communityId, required this.channelId});

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  final _controller = TextEditingController();
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// The message the next send replies to, shown in a bar over the composer.
  Message? _replyTo;
  bool _searching = false;

  /// When the local user last sent here — what slow mode counts from.
  DateTime? _lastSentAt;

  /// The first message that was unread when this screen opened. Captured once,
  /// so the "new messages" divider stays put instead of jumping as the screen
  /// marks the channel read.
  String? _firstUnreadId;

  /// True while the list is scrolled away from the newest message.
  bool _showJumpToLatest = false;

  @override
  void initState() {
    super.initState();
    final channel = CommunityStore.instance
        .byId(widget.communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
    if (channel != null) {
      _firstUnreadId = CommunityStore.instance.firstUnreadIdIn(channel);
    }
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // "Near the bottom" is within a screenful of the newest message.
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 240;
    if (atBottom == _showJumpToLatest) {
      setState(() => _showJumpToLatest = !atBottom);
    }
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Members whose name matches what's being typed after "@".
  List<Member> _mentionMatches(Community comm) {
    final caret = _controller.selection.baseOffset;
    final prefix = mentionPrefix(_controller.text,
        caret < 0 ? _controller.text.length : caret);
    if (prefix == null) return const [];
    final p = prefix.toLowerCase();
    return [
      for (final m in comm.members)
        if (m.id != 'me' &&
            mentionToken(m.name).isNotEmpty &&
            (p.isEmpty || mentionToken(m.name).toLowerCase().startsWith(p)))
          m
    ].take(5).toList();
  }

  /// Replaces the partial mention at the caret with [member]'s token.
  void _applyMention(Member member) {
    final text = _controller.text;
    final caret = _controller.selection.baseOffset < 0
        ? text.length
        : _controller.selection.baseOffset;
    final at = text.substring(0, caret).lastIndexOf('@');
    if (at == -1) return;
    final inserted = '@${mentionToken(member.name)} ';
    final next = text.replaceRange(at, caret, inserted);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// The moderation gate every send goes through: the server's word filter
  /// (when [text] is given) and slow mode. Explains itself in a snackbar.
  bool _sendAllowed({String? text}) {
    final store = CommunityStore.instance;
    final community = store.byId(widget.communityId);
    if (community == null) return false;
    if (text != null) {
      final hit = store.filterHit(widget.communityId, text);
      if (hit != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('"$hit" is blocked by this server\'s word filter')));
        return false;
      }
    }
    final slow = community.slowModeSeconds;
    if (slow > 0 && !store.canModerate(widget.communityId)) {
      final last = _lastSentAt;
      if (last != null) {
        final wait = slow - DateTime.now().difference(last).inSeconds;
        if (wait > 0) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Slow mode — you can send again in ${wait}s')));
          return false;
        }
      }
    }
    return true;
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (!_sendAllowed(text: text)) return;
    _lastSentAt = DateTime.now();
    final reply = _replyTo;
    _post(Message(
      id: 'ch_${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      time: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
      replyTo: reply == null
          ? null
          : ReplyInfo(
              senderName: reply.isMe
                  ? 'You'
                  : (reply.senderName.isEmpty ? 'Member' : reply.senderName),
              text: reply.isImage ? 'Photo' : reply.text,
              isMe: reply.isMe,
              messageId: reply.id,
            ),
    ));
    _controller.clear();
    // Sending ends this burst, so typing again announces straight away rather
    // than waiting out the throttle.
    ChannelTypingStore.instance.clearLocal(widget.channelId);
    setState(() => _replyTo = null);
  }

  void _post(Message message) {
    CommunityStore.instance
        .postMessage(widget.communityId, widget.channelId, message);
    // Members see it live: sealed with the server secret on the relay bus.
    if (RelayConfig.isEnabled) {
      RelayService.instance.sendChannelMessage(
        widget.communityId,
        widget.channelId,
        message,
        senderName: AppState.profile.value.name,
      );
    }
  }

  /// Whether the inline attach panel is showing.
  bool _attachOpen = false;

  Widget _attachOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) =>
      Expanded(
        child: Material(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color)),
                ],
              ),
            ),
          ),
        ),
      );

  /// Sends a real photo into the channel. Same path as a 1:1 chat: picked
  /// from the device, moderated, shrunk to fit the relay, and carried inline
  /// — there is no bucket in the middle for channel media either.
  Future<void> _sendPhoto() async {
    if (!_sendAllowed()) return;
    String? dataUri;
    try {
      dataUri = await PhotoPrep.pickPhoto();
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
      return;
    }
    // Null is either a cancel (say nothing) or an unusable image.
    if (dataUri == null || !mounted) return;
    _lastSentAt = DateTime.now();
    final now = DateTime.now();
    _post(Message(
      id: 'ch_img_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isImage: true,
      imageUrl: dataUri,
      imageSeed: now.microsecondsSinceEpoch % 6,
      replyTo: _replyTo == null
          ? null
          : ReplyInfo(
              senderName: _replyTo!.isMe
                  ? 'You'
                  : (_replyTo!.senderName.isEmpty
                      ? 'Member'
                      : _replyTo!.senderName),
              text: _replyTo!.isImage ? 'Photo' : _replyTo!.text,
              isMe: _replyTo!.isMe,
              messageId: _replyTo!.id,
            ),
    ));
    setState(() => _replyTo = null);
  }

  /// Emoji go into the message being typed; a GIF posts straight away.
  Future<void> _pickEmojiOrGif() async {
    final picked = await showEmojiGifSheet(context);
    if (picked == null || !mounted) return;
    final gif = picked.gif;
    if (gif != null) {
      if (!_sendAllowed()) return;
      _lastSentAt = DateTime.now();
      _post(Message(
        id: 'ch_${DateTime.now().microsecondsSinceEpoch}',
        text: '',
        time: DateTime.now(),
        isMe: true,
        status: MessageStatus.sent,
        isImage: true,
        imageUrl: gif.url,
      ));
      return;
    }
    final emoji = picked.emoji;
    if (emoji == null) return;
    final sel = _controller.selection;
    final text = _controller.text;
    if (sel.start < 0) {
      _controller.text = text + emoji;
      return;
    }
    _controller.value = _controller.value.copyWith(
      text: text.replaceRange(sel.start, sel.end, emoji),
      selection: TextSelection.collapsed(offset: sel.start + emoji.length),
    );
  }

  Future<void> _createPoll() async {
    final result =
        await showModalBottomSheet<({String question, List<String> options})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PollComposerSheet(),
    );
    if (result == null || !mounted) return;
    if (!_sendAllowed(text: result.question)) return;
    _lastSentAt = DateTime.now();
    CommunityStore.instance.postMessage(
      widget.communityId,
      widget.channelId,
      Message(
        id: 'ch_${DateTime.now().microsecondsSinceEpoch}',
        text: '',
        time: DateTime.now(),
        isMe: true,
        status: MessageStatus.sent,
        isPoll: true,
        pollQuestion: result.question,
        pollOptions: result.options,
        pollVotes: List<int>.filled(result.options.length, 0),
      ),
    );
  }

  void _votePoll(Message message, int option) {
    CommunityStore.instance.votePollInChannel(
        widget.communityId, widget.channelId, message.id, option);
  }

  /// Whether the local user may post in [channel]: everyone in text channels;
  /// only the owner/admins in announcement (news) channels.
  bool _canPost(Community community, Channel channel) {
    if (channel.type != ChannelType.announcement) return true;
    final me = community.members.where((m) => m.id == 'me').toList();
    if (me.isEmpty) return false;
    return me.first.role == MemberRole.owner ||
        me.first.role == MemberRole.admin;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [CommunityStore.instance, ChannelTypingStore.instance]),
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        if (channel == null) {
          return const Scaffold(body: Center(child: Text('Channel not found')));
        }
        // A found channel implies its community exists.
        final comm = community!;
        // Being in the channel reads it; after the frame so the store never
        // mutates mid-build (markChannelSeen no-ops when already current).
        final seenCount = channel.messages.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            CommunityStore.instance.markChannelSeen(channel.id, seenCount);
          }
        });
        // What muted members said stays out of your view.
        final mutedNames = {
          for (final m in comm.members)
            if (comm.mutedIds.contains(m.id)) m.name
        };
        final messages = [
          for (final m in channel.messages)
            if (m.isMe || !mutedNames.contains(m.senderName)) m
        ];
        // While searching, narrow to messages whose text or poll question
        // matches; otherwise the full (mute-filtered) list.
        final visible =
            _searching ? filterMessages(messages, _search.text) : messages;
        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _search,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Search #${channel.name}',
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  )
                : Row(
                    children: [
                      Icon(_channelIcon(channel.type), size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 18)),
                            // The topic is what the channel is *for*; hiding
                            // it once you're inside is where it's least
                            // useful.
                            if (channel.topic.isNotEmpty)
                              Text(channel.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w400,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color
                                          ?.withValues(alpha: 0.75))),
                          ],
                        ),
                      ),
                    ],
                  ),
            actions: [
              IconButton(
                icon: Icon(_searching ? Icons.close : Icons.search),
                tooltip: _searching ? 'Close search' : 'Search messages',
                onPressed: () => setState(() {
                  if (_searching) _search.clear();
                  _searching = !_searching;
                }),
              ),
              if (!_searching)
                Builder(builder: (context) {
                  final muted =
                      CommunityStore.instance.isChannelMuted(channel.id);
                  return IconButton(
                    icon: Icon(muted
                        ? Icons.notifications_off
                        : Icons.notifications_none),
                    tooltip: muted ? 'Unmute channel' : 'Mute channel',
                    onPressed: () {
                      final nowMuted = CommunityStore.instance
                          .toggleChannelMute(channel.id);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(nowMuted
                            ? '#${channel.name} muted — it won\'t badge the '
                                'server.'
                            : '#${channel.name} unmuted.'),
                      ));
                    },
                  );
                }),
            ],
          ),
          body: Column(
            children: [
              if (channel.topic.isNotEmpty && !_searching)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  child: Text(channel.topic,
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                ),
              if (channel.pinnedMessages.isNotEmpty && !_searching)
                _PinnedBar(
                  count: channel.pinnedMessages.length,
                  onTap: () => _showPinned(channel),
                ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: visible.isEmpty
                    ? Center(
                        child: Text(
                            _searching
                                ? 'No messages match "${_search.text.trim()}"'
                                : 'This is the start of #${channel.name}',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey.shade500)),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final m = visible[i];
                          final showDate = i == 0 ||
                              !_sameDay(visible[i - 1].time, m.time);
                          // Where the user left off last time they were here.
                          final unreadHere =
                              !_searching && m.id == _firstUnreadId;
                          // Group a run from the same sender: only the first
                          // shows the name, the rest tuck in tight — like chat.
                          final prev = i == 0 ? null : visible[i - 1];
                          final grouped = prev != null &&
                              !showDate &&
                              prev.isMe == m.isMe &&
                              prev.senderName == m.senderName &&
                              !prev.isCallEvent;
                          final bubble = _ChannelBubble(
                            message: m,
                            communityId: widget.communityId,
                            channelId: widget.channelId,
                            announcement:
                                channel.type == ChannelType.announcement,
                            pinned:
                                channel.pinnedMessageIds.contains(m.id),
                            grouped: grouped,
                            onReply: () => setState(() => _replyTo = m),
                            onQuickReact: () => CommunityStore.instance
                                .toggleChannelReaction(widget.communityId,
                                    widget.channelId, m.id, '❤️'),
                            onVote: m.isPoll
                                ? (opt) => _votePoll(m, opt)
                                : null,
                          );
                          // Swipe a message to the right to reply, exactly
                          // like the 1:1 chat.
                          final row = m.isPoll ||
                                  channel.type == ChannelType.announcement
                              ? bubble
                              : Dismissible(
                                  key: ValueKey('chmsg_${m.id}'),
                                  direction: DismissDirection.startToEnd,
                                  dismissThresholds: const {
                                    DismissDirection.startToEnd: 0.25
                                  },
                                  confirmDismiss: (_) async {
                                    setState(() => _replyTo = m);
                                    return false;
                                  },
                                  background: const Padding(
                                    padding: EdgeInsets.only(left: 24),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Icon(Icons.reply,
                                          color: Colors.grey),
                                    ),
                                  ),
                                  child: bubble,
                                );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showDate) _DateSeparator(time: m.time),
                              if (unreadHere) const _UnreadDivider(),
                              row,
                            ],
                          );
                        },
                      ),
                    ),
                    // Scrolled up through history? One tap back to the newest.
                    if (_showJumpToLatest && visible.isNotEmpty)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'ch_jump_latest',
                          onPressed: _jumpToLatest,
                          tooltip: 'Jump to latest',
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                  ],
                ),
              ),
              // Announcement channels are broadcast-only: members read, and
              // only the owner/admins can post — like every news channel.
              // The composer stays hidden while searching so results fill the
              // screen.
              if (_searching)
                const SizedBox.shrink()
              else if (!_canPost(comm, channel))
                SafeArea(
                  top: false,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.campaign_outlined,
                            size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text('Only admins can post in this channel',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 13.5)),
                      ],
                    ),
                  ),
                )
              else
                SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTo != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        padding:
                            const EdgeInsets.fromLTRB(12, 8, 4, 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.reply,
                                size: 17,
                                color:
                                    Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Replying to '
                                '${_replyTo!.isMe ? 'yourself' : (_replyTo!.senderName.isEmpty ? 'a member' : _replyTo!.senderName)}'
                                ' — ${_replyTo!.isImage ? 'Photo' : _replyTo!.text}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 17),
                              tooltip: 'Cancel reply',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  setState(() => _replyTo = null),
                            ),
                          ],
                        ),
                      ),
                    // Typing "@" offers the members of this server.
                    if (_mentionMatches(comm).isNotEmpty)
                      _MentionBar(
                        matches: _mentionMatches(comm),
                        onPick: _applyMention,
                      ),
                    Builder(builder: (context) {
                      final label = ChannelTypingStore.instance
                          .labelFor(widget.channelId);
                      if (label == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontStyle: FontStyle.italic,
                                      color: Colors.grey.shade600)),
                            ),
                          ],
                        ),
                      );
                    }),
                    // Opens in place rather than a modal sheet, so the
                    // channel stays visible while you choose.
                    if (_attachOpen)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: Row(
                          children: [
                            _attachOption(
                              icon: Icons.photo_outlined,
                              label: 'Photo',
                              color: const Color(0xFF7A5CFF),
                              onTap: () {
                                setState(() => _attachOpen = false);
                                _sendPhoto();
                              },
                            ),
                            const SizedBox(width: 10),
                            _attachOption(
                              icon: Icons.poll_outlined,
                              label: 'Poll',
                              color: const Color(0xFF2AA6A0),
                              onTap: () {
                                setState(() => _attachOpen = false);
                                _createPoll();
                              },
                            ),
                          ],
                        ),
                      ),
                    Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.emoji_emotions_outlined),
                        color: Colors.grey,
                        tooltip: 'Emoji & GIFs',
                        onPressed: _pickEmojiOrGif,
                      ),
                      // One attach button owns everything that isn't typing,
                      // so the bar stays two icons and a field — the same
                      // shape as the 1:1 composer.
                      IconButton(
                        icon: Icon(
                            _attachOpen ? Icons.close : Icons.attach_file),
                        color: Colors.grey,
                        tooltip: 'Attach',
                        onPressed: () {
                          setState(() => _attachOpen = !_attachOpen);
                          if (_attachOpen) {
                            FocusManager.instance.primaryFocus?.unfocus();
                          }
                        },
                      ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(
                            hintText: 'Message #${channel.name}',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24)),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                          ),
                          // Keeps the mention suggestions in step with typing.
                          onChanged: (v) {
                            if (v.isNotEmpty) {
                              ChannelTypingStore.instance.noteLocalTyping(
                                  widget.communityId, widget.channelId);
                            }
                            setState(() {});
                          },
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        icon: const Icon(Icons.send),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.accentOn(context),
                          foregroundColor: AppColors.onAccent(context),
                        ),
                        onPressed: _send,
                      ),
                    ],
                  ),
                ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Bottom sheet listing the channel's pinned messages; each row can jump
  /// straight to unpinning.
  void _showPinned(Channel channel) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Pinned in #${channel.name}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final m in channel.pinnedMessages)
              ListTile(
                leading: const Icon(Icons.push_pin, size: 20),
                title: Text(
                  m.isImage ? 'Photo' : (m.isPoll ? m.pollQuestion : m.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                    '${m.isMe ? 'You' : (m.senderName.isEmpty ? 'Member' : m.senderName)}'
                    ' · ${DateFormatter.callLabel(m.time)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Unpin',
                  onPressed: () {
                    CommunityStore.instance.togglePinChannelMessage(
                        widget.communityId, widget.channelId, m.id);
                    Navigator.pop(sheetContext);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The thin "N pinned" strip under the channel topic.
class _PinnedBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _PinnedBar({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin,
                  size: 15, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text('$count pinned ${count == 1 ? 'message' : 'messages'}',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

/// Filters [members] by a free-text query against their name.
List<Member> filterMembers(List<Member> members, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return members;
  return [
    for (final m in members)
      if (m.name.toLowerCase().contains(q)) m
  ];
}

class _MembersSheet extends StatefulWidget {
  /// Snapshot from open time; [build] re-reads the store so mutes, bans and
  /// role changes show while the sheet is up.
  final Community community;
  const _MembersSheet({required this.community});

  @override
  State<_MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends State<_MembersSheet> {
  final TextEditingController _search = TextEditingController();

  Community get community => widget.community;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [CommunityStore.instance, VoicePresenceStore.instance]),
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.community.id) ??
            widget.community;
        return _build(context, community);
      },
    );
  }

  /// The voice channel [m] is sitting in, or null. Presence travels by phone
  /// digits; the roster stores those as a 'u_<digits>' wire id.
  String? _voiceChannelOf(Community community, Member m) {
    final digits = m.id == 'me'
        ? null
        : CommunityStore.digitsOfWireId(m.id);
    for (final ch in community.channels) {
      if (ch.type != ChannelType.voice) continue;
      for (final o in VoicePresenceStore.instance.occupantsIn(ch.id)) {
        if (m.id == 'me' ? o.isMe : (digits != null && o.digits == digits)) {
          return ch.name;
        }
      }
    }
    return null;
  }

  Widget _build(BuildContext context, Community community) {
    // Owner/admins first, then everyone; online before offline within a role.
    final members = filterMembers(
        [...community.members]..sort((a, b) {
          final r = a.role.index.compareTo(b.role.index);
          if (r != 0) return r;
          if (a.online != b.online) return a.online ? -1 : 1;
          return a.name.compareTo(b.name);
        }),
        _search.text);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text('Members — ${community.members.length}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          // Scrolling to find one person stops working somewhere around the
          // second screenful.
          if (community.members.length > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Search members',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(_search.clear),
                        ),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('No members match "${_search.text.trim()}"',
                    style: TextStyle(color: Colors.grey.shade500)),
              ),
            ),
          for (final m in members)
            ListTile(
              leading: Stack(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: _hex(community.color),
                    child: Text(
                      m.name.isEmpty ? '?' : m.name[0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (m.online)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF43B581),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Theme.of(context).canvasColor, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              title: Text(m.name),
              // Where someone actually is beats a stale online flag, so the
              // voice channel wins the subtitle when they're in one.
              subtitle: Builder(builder: (context) {
                final inVoice = _voiceChannelOf(community, m);
                if (community.mutedIds.contains(m.id)) {
                  return Text('Muted',
                      style: TextStyle(
                          color: Colors.orange.shade700, fontSize: 12.5));
                }
                if (inVoice != null) {
                  return Row(
                    children: [
                      Icon(Icons.volume_up_rounded,
                          size: 13, color: Colors.green.shade600),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text('In $inVoice',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.green.shade600,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5)),
                      ),
                    ],
                  );
                }
                return Text(m.online ? 'Online' : 'Offline',
                    style: TextStyle(
                        color: m.online
                            ? const Color(0xFF43B581)
                            : Colors.grey.shade500,
                        fontSize: 12.5));
              }),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (community.mutedIds.contains(m.id))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.volume_off,
                          size: 17, color: Colors.orange.shade700),
                    ),
                  if (m.role != MemberRole.member) _RoleBadge(role: m.role),
                ],
              ),
              onTap:
                  m.id == 'me' ? null : () => _manageMember(context, m),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// The current user's role in this community ('me' is the local user).
  MemberRole get _myRole => community.members
      .firstWhere((m) => m.id == 'me',
          orElse: () => const Member(id: 'me', name: 'You'))
      .role;

  /// Owners and admins can manage other non-owner members (not themselves).
  bool _canManage(Member m) =>
      (_myRole == MemberRole.owner || _myRole == MemberRole.admin) &&
      m.id != 'me' &&
      m.role != MemberRole.owner;

  Future<void> _manageMember(BuildContext context, Member m) async {
    final store = CommunityStore.instance;
    final muted =
        store.byId(community.id)?.mutedIds.contains(m.id) ?? false;
    final manage = _canManage(m);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(m.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(roleName(m.role)),
            ),
            const Divider(height: 1),
            // Muting is personal — anyone can quiet anyone for themselves.
            ListTile(
              leading: Icon(muted ? Icons.volume_up : Icons.volume_off),
              title: Text(muted ? 'Unmute' : 'Mute'),
              subtitle: muted
                  ? null
                  : const Text('Hides their messages and posts for you'),
              onTap: () => Navigator.pop(context, 'mute'),
            ),
            if (manage) ...[
              // Assign any role below owner. The current role is disabled.
              for (final r in const [
                MemberRole.admin,
                MemberRole.moderator,
                MemberRole.member,
              ])
                ListTile(
                  leading: Icon(_roleIcon(r)),
                  title: Text(m.role == r
                      ? '${roleName(r)} (current)'
                      : 'Make ${roleName(r).toLowerCase()}'),
                  enabled: m.role != r,
                  onTap: () => Navigator.pop(context, 'role:${r.name}'),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.person_remove_outlined,
                    color: Colors.red),
                title: const Text('Remove from server',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.red),
                title: const Text('Ban from server',
                    style: TextStyle(color: Colors.red)),
                subtitle: const Text("Removes them and blocks rejoining"),
                onTap: () => Navigator.pop(context, 'ban'),
              ),
            ],
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action.startsWith('role:')) {
      final r = MemberRole.values
          .firstWhere((v) => v.name == action.substring(5));
      store.setMemberRole(community.id, m.id, r);
      return;
    }
    switch (action) {
      case 'mute':
        store.toggleMuteMember(community.id, m.id);
        break;
      case 'remove':
        store.removeMember(community.id, m.id);
        break;
      case 'ban':
        store.banMember(community.id, m.id);
        break;
    }
  }

  IconData _roleIcon(MemberRole r) => switch (r) {
        MemberRole.owner => Icons.star_rounded,
        MemberRole.admin => Icons.shield_rounded,
        MemberRole.moderator => Icons.gpp_good_outlined,
        MemberRole.member => Icons.person_outline,
      };
}

class _RoleBadge extends StatelessWidget {
  final MemberRole role;
  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = switch (role) {
      MemberRole.owner => const Color(0xFFF1C40F), // gold
      MemberRole.admin => AppColors.tealGreenDark,
      MemberRole.moderator => const Color(0xFF3F7FBF), // blue
      MemberRole.member => Colors.grey,
    };
    final icon = switch (role) {
      MemberRole.owner => Icons.star_rounded,
      MemberRole.admin => Icons.shield_rounded,
      MemberRole.moderator => Icons.gpp_good_outlined,
      MemberRole.member => Icons.person_outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(roleName(role),
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Whether two timestamps fall on the same calendar day.
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// A centered "Today / Yesterday / date" divider between days of messages.
/// The row of member suggestions shown while an "@" mention is being typed.
class _MentionBar extends StatelessWidget {
  final List<Member> matches;
  final ValueChanged<Member> onPick;
  const _MentionBar({required this.matches, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        itemCount: matches.length,
        itemBuilder: (context, i) {
          final m = matches[i];
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ActionChip(
                avatar: CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primary.withValues(alpha: 0.18),
                  child: Text(
                    m.name.isEmpty ? '?' : m.name.characters.first,
                    style: TextStyle(fontSize: 11, color: scheme.primary),
                  ),
                ),
                label: Text(m.name, style: const TextStyle(fontSize: 13)),
                onPressed: () => onPick(m),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The "new messages" line marking where the reader left off. Sits above the
/// first message they hadn't seen when the channel opened.
class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withValues(alpha: 0.5))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('New messages',
                style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3)),
          ),
          Expanded(child: Divider(color: color.withValues(alpha: 0.5))),
        ],
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  final DateTime time;
  const _DateSeparator({required this.time});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(DateFormatter.messageDayHeader(time),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600)),
        ),
      ),
    );
  }
}

class _ChannelBubble extends StatelessWidget {
  final Message message;
  final String communityId;
  final String channelId;
  final bool announcement;
  final bool pinned;

  /// True when the previous message was from the same sender — the name is
  /// dropped and the spacing tightens so a run reads as one turn.
  final bool grouped;
  final VoidCallback? onReply;

  /// Double-tap quick reaction (a heart), like the 1:1 chat.
  final VoidCallback? onQuickReact;
  final ValueChanged<int>? onVote;
  const _ChannelBubble({
    required this.message,
    required this.communityId,
    required this.channelId,
    this.announcement = false,
    this.pinned = false,
    this.grouped = false,
    this.onReply,
    this.onQuickReact,
    this.onVote,
  });

  static const _quickEmojis = ['👍', '❤️', '😂', '🎉', '🔥', '👏'];

  void _react(String emoji) => CommunityStore.instance
      .toggleChannelReaction(communityId, channelId, message.id, emoji);

  Future<void> _edit(BuildContext context) async {
    final text = await showAppTextPrompt(
      context,
      icon: Icons.edit_outlined,
      title: 'Edit message',
      initial: message.text,
      maxLines: 4,
      capitalization: TextCapitalization.sentences,
    );
    if (text == null || text.trim().isEmpty) return;
    CommunityStore.instance
        .editChannelMessage(communityId, channelId, message.id, text);
  }

  Future<void> _showActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quick reactions row.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final e in _quickEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        _react(e);
                        Navigator.pop(sheetContext);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                  // Any emoji, like the 1:1 chat's reaction picker.
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      final picked = await showEmojiGifSheet(context);
                      final emoji = picked?.emoji;
                      if (emoji != null) _react(emoji);
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.add_reaction_outlined, size: 26),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onReply!();
                },
              ),
            ListTile(
              leading: Icon(
                  pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? 'Unpin' : 'Pin'),
              onTap: () {
                CommunityStore.instance.togglePinChannelMessage(
                    communityId, channelId, message.id);
                Navigator.pop(sheetContext);
              },
            ),
            if (message.isMe && !message.isPoll && !message.isImage)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _edit(context);
                },
              ),
            if (!message.isPoll && !message.isImage)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy text'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              ),
            if (message.isMe)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  CommunityStore.instance.deleteChannelMessage(
                      communityId, channelId, message.id);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Announcement messages render as full-width news cards, not chat bubbles.
  Widget _newsCard(BuildContext context) {
    const accent = Color(0xFF7A5CFF);
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 5, 12, 3),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
          border: const Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.campaign, size: 15, color: accent),
                const SizedBox(width: 5),
                const Text('ANNOUNCEMENT',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: accent)),
                const Spacer(),
                Text(DateFormatter.messageTime(message.time),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
            const SizedBox(height: 8),
            RichMessageText(
              text: message.text,
              textColor:
                  Theme.of(context).colorScheme.onSurface,
              linkColor: accent,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (announcement && !message.isPoll) return _newsCard(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onBubble = message.isMe
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white : Colors.black87);
    final metaColor = message.isMe
        ? (isDark ? Colors.black54 : Colors.white70)
        : Colors.grey;
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            message.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showActions(context),
            onDoubleTap: onQuickReact,
            child: Container(
              margin: EdgeInsets.fromLTRB(10, grouped ? 1 : 4, 10, 1),
              padding: const EdgeInsets.fromLTRB(13, 8, 13, 7),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78),
              decoration: BoxDecoration(
                color: message.isMe
                    ? (isDark
                        ? AppColors.outgoingBubbleDark
                        : AppColors.tealGreenDark)
                    : (isDark
                        ? AppColors.incomingBubbleDark
                        : AppColors.incomingBubbleLight),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!grouped &&
                      !message.isMe &&
                      message.senderName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(message.senderName,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.primaries[
                                      message.senderName.hashCode %
                                          Colors.primaries.length]
                                  .shade400)),
                    ),
                  if (message.replyTo != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
                      decoration: BoxDecoration(
                        color: (message.isMe ? Colors.black : Colors.grey)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border(
                            left: BorderSide(
                                color: onBubble.withValues(alpha: 0.5),
                                width: 3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(message.replyTo!.senderName,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: onBubble.withValues(alpha: 0.8))),
                          Text(message.replyTo!.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: onBubble.withValues(alpha: 0.7))),
                        ],
                      ),
                    ),
                  if (message.isPoll)
                    PollBubble(
                      message: message,
                      textColor: onBubble,
                      metaColor: metaColor,
                      onVote: (i) => onVote?.call(i),
                    )
                  else if (message.isImage && message.imageUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: ChatPhoto(
                        url: message.imageUrl!,
                        width: 220,
                        errorBuilder: (_) => Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('📷 Photo unavailable',
                              style: TextStyle(color: metaColor)),
                        ),
                      ),
                    )
                  else
                    RichMessageText(
                      text: message.text,
                      textColor: onBubble,
                      linkColor: message.isMe
                          ? (isDark ? Colors.tealAccent : Colors.white)
                          : AppColors.tealGreenDark,
                    ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pinned) ...[
                        Icon(Icons.push_pin, size: 11, color: metaColor),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        '${DateFormatter.messageTime(message.time)}'
                        '${message.edited ? ' · edited' : ''}',
                        style: TextStyle(color: metaColor, fontSize: 10.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Reaction chips under the bubble; tap to remove yours.
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final e in _countReactions(message.reactions).entries)
                    GestureDetector(
                      onTap: () => _react(e.key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                            e.value > 1 ? '${e.key} ${e.value}' : e.key,
                            style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Map<String, int> _countReactions(List<String> reactions) {
    final counts = <String, int>{};
    for (final r in reactions) {
      counts[r] = (counts[r] ?? 0) + 1;
    }
    return counts;
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.groups_outlined,
      title: 'No communities yet',
      caption:
          'Create a community to organise channels with friends or a team.',
    );
  }
}

Future<String?> _promptName(
        BuildContext context, String title, String hint) =>
    showAppTextPrompt(
      context,
      icon: Icons.workspaces_outline,
      title: title,
      hint: hint,
      confirmLabel: 'Create',
      capitalization: TextCapitalization.words,
    );

/// What each channel type is for, shown next to its name so the choice isn't
/// four bare words.
const _channelTypes = <(ChannelType, IconData, String, String)>[
  (ChannelType.text, Icons.tag, 'Text', 'Send messages, photos and polls'),
  (ChannelType.voice, Icons.volume_up_rounded, 'Voice', 'Hang out and talk'),
  (
    ChannelType.announcement,
    Icons.campaign_rounded,
    'News',
    'Post updates everyone can follow'
  ),
  (
    ChannelType.forum,
    Icons.forum_rounded,
    'Forum',
    'A board of posts you can vote on'
  ),
];

/// Opens the new-channel dialog. Exposed so its behaviour can be tested
/// without driving the whole community screen to reach it.
@visibleForTesting
Future<(String, ChannelType)?> promptNewChannelForTest(BuildContext context) =>
    _promptNewChannel(context);

/// Dialog to create a channel: pick a type, then name it.
Future<(String, ChannelType)?> _promptNewChannel(BuildContext context) {
  final controller = TextEditingController();
  var type = ChannelType.text;
  return showDialog<(String, ChannelType)>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        final name = _cleanChannelPreview(controller.text, type);
        final valid = name.isNotEmpty;
        void submit() {
          if (valid) Navigator.of(dialogContext).pop((controller.text.trim(), type));
        }

        return AlertDialog(
          scrollable: true,
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          title: const Text('New channel'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CHANNEL TYPE',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 8),
                // One row per type, so each gets its description instead of
                // four chips wrapping onto two ragged lines.
                for (final t in _channelTypes)
                  _ChannelTypeOption(
                    icon: t.$2,
                    label: t.$3,
                    description: t.$4,
                    selected: type == t.$1,
                    onTap: () => setState(() => type = t.$1),
                  ),
                const SizedBox(height: 18),
                Text(
                  'CHANNEL NAME',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: type == ChannelType.voice
                      ? TextCapitalization.words
                      : TextCapitalization.none,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    filled: true,
                    isDense: true,
                    prefixIcon: Icon(_channelIcon(type), size: 20),
                    hintText: type == ChannelType.voice
                        ? 'General'
                        : 'new-channel',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 8),
                Text(
                  type == ChannelType.voice
                      ? 'Voice channels keep the name you type.'
                      : 'Spaces become dashes — it\'ll show up as '
                          '#${name.isEmpty ? 'new-channel' : name}.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentOn(dialogContext),
                foregroundColor: AppColors.onAccent(dialogContext),
              ),
              onPressed: valid ? submit : null,
              child: const Text('Create'),
            ),
          ],
        );
      },
    ),
  );
}

/// Mirrors the store's channel-name cleanup so the dialog can preview the
/// name the channel will actually get.
String _cleanChannelPreview(String raw, ChannelType type) {
  final trimmed = raw.trim();
  if (type == ChannelType.voice) return trimmed;
  return trimmed
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9\-_]'), '');
}

/// One selectable channel type: icon, name and what it's for.
class _ChannelTypeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelTypeOption({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: selected ? scheme.primary : Colors.grey.shade500),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600,
                          )),
                      Text(description,
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, size: 20, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
