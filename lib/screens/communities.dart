import 'package:flutter/material.dart';

import '../models/community.dart';
import '../models/message.dart';
import '../state/community_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';

Color _hex(String s) =>
    Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

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

/// The "Communities" tab: Discord-style servers you can create and open.
class CommunitiesTab extends StatelessWidget {
  const CommunitiesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final communities = CommunityStore.instance.communities;
        if (communities.isEmpty) {
          return const _Empty();
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final c in communities)
              ListTile(
                leading: CircleAvatar(
                  radius: 26,
                  backgroundColor: _hex(c.color),
                  child: Text(
                    c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 20),
                  ),
                ),
                title: Text(c.name,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${c.channels.length} channel${c.channels.length == 1 ? '' : 's'}'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CommunityScreen(communityId: c.id))),
              ),
          ],
        );
      },
    );
  }
}

/// A single community: its channels, plus an add-channel action.
class CommunityScreen extends StatelessWidget {
  final String communityId;
  const CommunityScreen({super.key, required this.communityId});

  Future<void> _addChannel(BuildContext context) async {
    final name = await _promptName(context, 'New channel', 'channel-name');
    if (name == null || name.isEmpty) return;
    CommunityStore.instance.addChannel(communityId, name);
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
                icon: const Icon(Icons.add),
                tooltip: 'Add channel',
                onPressed: () => _addChannel(context),
              ),
            ],
          ),
          body: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text('CHANNELS',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: Colors.grey)),
              ),
              for (final ch in community.channels)
                ListTile(
                  leading: const Icon(Icons.tag, color: Colors.grey),
                  title: Text(ch.name),
                  subtitle: ch.messages.isEmpty
                      ? null
                      : Text(ch.messages.last.text,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ChannelScreen(
                        communityId: communityId, channelId: ch.id),
                  )),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A channel's message view: a simple list plus a composer.
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
                const Icon(Icons.tag, size: 20),
                const SizedBox(width: 4),
                Text(channel.name),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: channel.messages.isEmpty
                    ? Center(
                        child: Text('This is the start of #${channel.name}',
                            style: TextStyle(color: Colors.grey.shade500)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: channel.messages.length,
                        itemBuilder: (context, i) =>
                            _ChannelBubble(message: channel.messages[i]),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
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

class _ChannelBubble extends StatelessWidget {
  final Message message;
  const _ChannelBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        padding: const EdgeInsets.fromLTRB(13, 8, 13, 7),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
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
            Text(
              message.text,
              style: TextStyle(
                color: message.isMe
                    ? (isDark ? Colors.black : Colors.white)
                    : (isDark ? Colors.white : Colors.black87),
                fontSize: 15.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              DateFormatter.messageTime(message.time),
              style: TextStyle(
                color: message.isMe
                    ? (isDark ? Colors.black54 : Colors.white70)
                    : Colors.grey,
                fontSize: 10.5,
              ),
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
          child: const Text('Create'),
        ),
      ],
    ),
  );
}
