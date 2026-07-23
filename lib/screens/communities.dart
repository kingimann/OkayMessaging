import 'package:flutter/material.dart';

import '../models/community.dart';
import '../models/message.dart';
import '../state/community_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/poll_widgets.dart';
import 'community_settings_screen.dart';
import 'forum_screen.dart';

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
class CommunitiesTab extends StatelessWidget {
  const CommunitiesTab({super.key});

  Future<void> _refresh() async {
    // Local-first: just give the list a beat to refresh from the store.
    CommunityStore.instance.touch();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final communities = CommunityStore.instance.communities;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: communities.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [SizedBox(height: 100), _Empty()],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    for (final c in communities) _CommunityCard(community: c),
                  ],
                ),
        );
      },
    );
  }
}

/// A single community rendered as a rounded card with a gradient badge.
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
                    community.name.isEmpty
                        ? '?'
                        : community.name[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 24),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(community.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
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
                        ],
                      ),
                    ],
                  ),
                ),
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

/// A single community: its channels grouped by category, plus actions to add
/// a channel or view members.
class CommunityScreen extends StatelessWidget {
  final String communityId;
  const CommunityScreen({super.key, required this.communityId});

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
            ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename channel'),
                onTap: () => Navigator.pop(context, 'rename')),
            ListTile(
                leading: const Icon(Icons.notes_rounded),
                title: const Text('Edit topic'),
                onTap: () => Navigator.pop(context, 'topic')),
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
      case 'delete':
        store.deleteChannel(communityId, ch.id);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(communityId);
        if (community == null) {
          return const Scaffold(body: Center(child: Text('Community not found')));
        }
        final onlineCount = community.members.where((m) => m.online).length;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: _hex(community.color),
                  child: Text(community.name[0].toUpperCase(),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.circle, size: 9, color: Color(0xFF43B581)),
                    const SizedBox(width: 6),
                    Text('$onlineCount online · ${community.members.length} members',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              for (final category in community.categories) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(category.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Colors.grey)),
                ),
                for (final ch in community.channelsIn(category))
                  ListTile(
                    dense: true,
                    leading:
                        Icon(_channelIcon(ch.type), color: Colors.grey, size: 22),
                    title: Text(ch.name),
                    subtitle: ch.type == ChannelType.voice
                        ? const Text('Voice channel')
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
  bool _joined = false;
  bool _muted = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        if (channel == null) {
          return const Scaffold(body: Center(child: Text('Channel not found')));
        }
        final present = _joined
            ? community!.members.where((m) => m.online).toList()
            : <Member>[];
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Icon(Icons.volume_up_rounded, size: 20),
                const SizedBox(width: 6),
                Text(channel.name),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: present.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.headset_mic_outlined,
                                size: 56, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text('No one is in ${channel.name}',
                                style:
                                    TextStyle(color: Colors.grey.shade500)),
                            const SizedBox(height: 4),
                            Text('Join to start the conversation',
                                style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 12.5)),
                          ],
                        ),
                      )
                    : GridView.count(
                        crossAxisCount: 3,
                        padding: const EdgeInsets.all(16),
                        children: [
                          for (final m in present)
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircleAvatar(
                                  radius: 30,
                                  backgroundColor: _hex(community!.color),
                                  child: Text(
                                    m.name.isEmpty
                                        ? '?'
                                        : m.name[0].toUpperCase(),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(m.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5)),
                              ],
                            ),
                        ],
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_joined) ...[
                        _voiceButton(
                          icon: _muted ? Icons.mic_off : Icons.mic,
                          color: _muted ? Colors.grey : AppColors.tealGreenDark,
                          onTap: () => setState(() => _muted = !_muted),
                        ),
                        const SizedBox(width: 16),
                        _voiceButton(
                          icon: Icons.call_end,
                          color: Colors.red,
                          onTap: () => setState(() {
                            _joined = false;
                            _muted = false;
                          }),
                        ),
                      ] else
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.tealGreenDark,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 28, vertical: 14),
                          ),
                          icon: const Icon(Icons.headset_mic),
                          label: const Text('Join Voice'),
                          onPressed: () => setState(() => _joined = true),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _voiceButton(
          {required IconData icon,
          required Color color,
          required VoidCallback onTap}) =>
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    CommunityStore.instance.postMessage(
      widget.communityId,
      widget.channelId,
      Message(
        id: 'ch_${DateTime.now().microsecondsSinceEpoch}',
        text: text,
        time: DateTime.now(),
        isMe: true,
        status: MessageStatus.sent,
      ),
    );
    _controller.clear();
  }

  Future<void> _createPoll() async {
    final result =
        await showModalBottomSheet<({String question, List<String> options})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PollComposerSheet(),
    );
    if (result == null || !mounted) return;
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        if (channel == null) {
          return const Scaffold(body: Center(child: Text('Channel not found')));
        }
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                Icon(_channelIcon(channel.type), size: 20),
                const SizedBox(width: 4),
                Text(channel.name),
              ],
            ),
          ),
          body: Column(
            children: [
              if (channel.topic.isNotEmpty)
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
              Expanded(
                child: channel.messages.isEmpty
                    ? Center(
                        child: Text('This is the start of #${channel.name}',
                            style: TextStyle(color: Colors.grey.shade500)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: channel.messages.length,
                        itemBuilder: (context, i) {
                          final m = channel.messages[i];
                          return _ChannelBubble(
                            message: m,
                            onVote: m.isPoll ? (opt) => _votePoll(m, opt) : null,
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.poll_outlined),
                        color: Colors.grey,
                        tooltip: 'Create poll',
                        onPressed: _createPoll,
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
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        icon: const Icon(Icons.send),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.tealGreenDark,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _send,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MembersSheet extends StatelessWidget {
  final Community community;
  const _MembersSheet({required this.community});

  @override
  Widget build(BuildContext context) {
    // Owner/admins first, then everyone; online before offline within a role.
    final members = [...community.members]..sort((a, b) {
        final r = a.role.index.compareTo(b.role.index);
        if (r != 0) return r;
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text('Members — ${community.members.length}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
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
              subtitle: Text(m.online ? 'Online' : 'Offline',
                  style: TextStyle(
                      color: m.online
                          ? const Color(0xFF43B581)
                          : Colors.grey.shade500,
                      fontSize: 12.5)),
              trailing: m.role == MemberRole.member
                  ? null
                  : _RoleBadge(role: m.role),
              onTap: _canManage(m)
                  ? () => _manageMember(context, m)
                  : null,
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
            if (m.role == MemberRole.member)
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Make admin'),
                onTap: () => Navigator.pop(context, 'promote'),
              )
            else
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Remove admin'),
                onTap: () => Navigator.pop(context, 'demote'),
              ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined,
                  color: Colors.red),
              title: const Text('Remove from server',
                  style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'promote':
        store.setMemberRole(community.id, m.id, MemberRole.admin);
        break;
      case 'demote':
        store.setMemberRole(community.id, m.id, MemberRole.member);
        break;
      case 'remove':
        store.removeMember(community.id, m.id);
        break;
    }
  }
}

class _RoleBadge extends StatelessWidget {
  final MemberRole role;
  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final color =
        role == MemberRole.owner ? const Color(0xFFF1C40F) : AppColors.tealGreenDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
              role == MemberRole.owner
                  ? Icons.star_rounded
                  : Icons.shield_rounded,
              size: 14,
              color: color),
          const SizedBox(width: 4),
          Text(roleName(role),
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ChannelBubble extends StatelessWidget {
  final Message message;
  final ValueChanged<int>? onVote;
  const _ChannelBubble({required this.message, this.onVote});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onBubble = message.isMe
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white : Colors.black87);
    final metaColor = message.isMe
        ? (isDark ? Colors.black54 : Colors.white70)
        : Colors.grey;
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        padding: const EdgeInsets.fromLTRB(13, 8, 13, 7),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: message.isMe
              ? (isDark ? AppColors.outgoingBubbleDark : AppColors.tealGreenDark)
              : (isDark
                  ? AppColors.incomingBubbleDark
                  : AppColors.incomingBubbleLight),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isPoll)
              PollBubble(
                message: message,
                textColor: onBubble,
                metaColor: metaColor,
                onVote: (i) => onVote?.call(i),
              )
            else
              Text(
                message.text,
                style: TextStyle(color: onBubble, fontSize: 15.5),
              ),
            const SizedBox(height: 2),
            Text(
              DateFormatter.messageTime(message.time),
              style: TextStyle(color: metaColor, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    final grey = Colors.grey.shade500;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 64, color: grey),
            const SizedBox(height: 16),
            Text('No communities yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
            const SizedBox(height: 6),
            Text('Create a community to organise channels\nwith friends or a team.',
                textAlign: TextAlign.center,
                style: TextStyle(color: grey, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

Future<String?> _promptName(
    BuildContext context, String title, String hint) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Dialog to create a channel: pick a type, then name it.
Future<(String, ChannelType)?> _promptNewChannel(BuildContext context) {
  final controller = TextEditingController();
  var type = ChannelType.text;
  return showDialog<(String, ChannelType)>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text('New channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final t in const [
                  (ChannelType.text, Icons.tag, 'Text'),
                  (ChannelType.voice, Icons.volume_up_rounded, 'Voice'),
                  (ChannelType.announcement, Icons.campaign_rounded, 'News'),
                  (ChannelType.forum, Icons.forum_rounded, 'Forum'),
                ])
                  ChoiceChip(
                    avatar: Icon(t.$2,
                        size: 18,
                        color: type == t.$1
                            ? Theme.of(dialogContext).colorScheme.onSecondaryContainer
                            : null),
                    label: Text(t.$3),
                    selected: type == t.$1,
                    onSelected: (_) => setState(() => type = t.$1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (type == ChannelType.forum)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('A Reddit-style board of posts you can vote on.',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                  hintText:
                      type == ChannelType.voice ? 'Channel name' : 'channel-name'),
              onSubmitted: (v) =>
                  Navigator.of(dialogContext).pop((v.trim(), type)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop((controller.text.trim(), type)),
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
}
