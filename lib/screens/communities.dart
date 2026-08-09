import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoView, RTCVideoViewObjectFit;
import '../state/parental_controls.dart';
import '../state/room_media.dart';
import '../widgets/parental_gate.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/platform_role.dart';
import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../mesh/mesh_service.dart';
import '../mesh/nearby_servers.dart';
import '../state/community_store.dart';
import '../state/platform_moderation.dart';
import '../state/channel_typing_store.dart';
import '../state/voice_media.dart';
import '../state/voice_presence_store.dart';
import '../util/haptics.dart';
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
import 'community_roles_screen.dart' show roleTierBlurb;
import '../widgets/poll_widgets.dart';
import '../payments/payment_service.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/spark_sheet.dart';
import '../widgets/user_avatar.dart';
import '../widgets/voice_note_bubble.dart';
import 'community_settings_screen.dart';
import 'create_server_screen.dart';
import 'feed_screen.dart';
import 'forum_screen.dart';
import 'add_server_members_screen.dart';
import 'forward_screen.dart';

Color _hex(String s) =>
    Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

IconData _channelIcon(ChannelType type) => switch (type) {
      ChannelType.voice => Icons.volume_up_rounded,
      ChannelType.announcement => Icons.campaign_rounded,
      ChannelType.forum => Icons.forum_rounded,
      ChannelType.text => Icons.tag,
    };

/// Opens the full create-server form (identity + privacy settings), which
/// creates the community and replaces itself with the new server's screen.
/// Called from the home screen's compose button on the Communities tab.
Future<void> createCommunityFlow(BuildContext context) async {
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const CreateServerScreen()));
}

/// Opens a sheet to join a server by pasting an invite CODE. The code is a
/// self-contained snapshot (see [CommunityStore.inviteToken]) that carries the
/// server's identity, channels and E2E secret, so decoding it is all a device
/// needs to join — there is no server-side code registry to look up.
Future<void> joinByCodeFlow(BuildContext context) async {
  final controller = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      String? error;
      return StatefulBuilder(
        builder: (sheetContext, setSheet) {
          void submit() {
            final snapshot =
                CommunityStore.decodeInviteToken(controller.text);
            final id = snapshot?['id'] as String?;
            final name = snapshot?['name'] as String? ?? '';
            if (snapshot == null || id == null || name.isEmpty) {
              setSheet(() => error = 'That code doesn\'t look right.');
              return;
            }
            if (CommunityStore.instance.byId(id) != null) {
              Navigator.pop(sheetContext);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('You\'re already in "$name".')));
              return;
            }
            // A paid server's paywall is its invite card, which runs the
            // purchase before joining — a bare code would skip it.
            if (snapshot['paid'] == true) {
              setSheet(() => error =
                  'This is a paid server — open its invite card to subscribe.');
              return;
            }
            final me = AppState.profile.value;
            final digits = me.phone.replaceAll(RegExp(r'\D'), '');
            final community = CommunityStore.instance
                .joinFromInvite(snapshot, myDigits: digits, myName: me.name);
            if (community == null) {
              setSheet(() => error = 'That code doesn\'t look right.');
              return;
            }
            // Same convergence path a tapped invite card uses: announce the
            // join so the roster and sender keys line up (the #128 fix).
            if (RelayConfig.isEnabled) {
              RelayService.instance.sendServerJoin(
                community.id,
                Member(
                    id: CommunityStore.wireId(digits),
                    name: me.name.isEmpty ? 'Member' : me.name,
                    online: true),
              );
            }
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Joined "${community.name}"')));
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 0, 20, 16 + MediaQuery.of(sheetContext).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Join a server',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Paste an invite code someone shared with you.',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.subtle(sheetContext))),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'OKAY-…',
                      errorText: error,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (error != null) setSheet(() => error = null);
                    },
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: submit,
                      child: const Text('Join'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Joins a server from a decoded invite [snapshot] (from a code, a tapped
/// card, or a Discover row) through the one convergence path — join locally,
/// then announce it so the roster and sender keys line up (the #128 fix).
/// Returns the joined community, or null if the snapshot is unusable or refused
/// (already in it, or a paid server, which must go through its invite card).
/// [reason] is set to a short explanation when it returns null for a reason
/// worth showing.
Community? joinServerFromSnapshot(Map<String, dynamic> snapshot,
    {void Function(String message)? onRefused}) {
  final id = snapshot['id'] as String?;
  final name = snapshot['name'] as String? ?? '';
  if (id == null || name.isEmpty) {
    onRefused?.call('That invite doesn\'t look right.');
    return null;
  }
  if (CommunityStore.instance.byId(id) != null) {
    onRefused?.call('You\'re already in "$name".');
    return null;
  }
  if (snapshot['paid'] == true) {
    onRefused
        ?.call('This is a paid server — open its invite card to subscribe.');
    return null;
  }
  final me = AppState.profile.value;
  final digits = me.phone.replaceAll(RegExp(r'\D'), '');
  final community = CommunityStore.instance
      .joinFromInvite(snapshot, myDigits: digits, myName: me.name);
  if (community == null) {
    onRefused?.call('That invite doesn\'t look right.');
    return null;
  }
  if (RelayConfig.isEnabled) {
    RelayService.instance.sendServerJoin(
      community.id,
      Member(
          id: CommunityStore.wireId(digits),
          name: me.name.isEmpty ? 'Member' : me.name,
          online: true),
    );
  }
  return community;
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

  /// Pulls the server's copy of the communities back down, then rebuilds.
  Future<void> _refresh() => PullToRefresh.refreshApp(
      extra: () async => CommunityStore.instance.touch());

  @override
  void dispose() {
    super.dispose();
  }

  // NO phone gate here anymore, and that is a correction, not a loosening:
  // the gate's own reason ("no session to join one with") stopped being
  // true when the community bus became what it is — sealed broadcast,
  // the anon-key mailbox, and the sealed community_posts store, the exact
  // same transports numberless CHAT already rides. Keeping the gate meant
  // a numberless member could receive a server invite in chat, join the
  // roster, and then stare at a locked screen while their posts existed
  // for nobody. What still needs more than membership keeps its own gate:
  // selling (ID check), the wallet (session), the public feed (session).
  @override
  Widget build(BuildContext context) => ParentalGate(
        restriction: ParentalRestriction.servers,
        title: 'Servers',
        scaffold: false,
        child: Builder(builder: _guarded),
      );

  Widget _guarded(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        CommunityStore.instance,
        VoicePresenceStore.instance,
        NearbyServers.instance,
        MeshService.instance,
      ]),
      builder: (context, _) {
        final all = CommunityStore.instance.communities;
        // Unfiltered here. filterCommunities is still what the app bar's
        // search uses; this list shows everything.
        final communities = all;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: all.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    _NearbySection(),
                    SizedBox(height: 60),
                    _Empty(),
                  ],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    // The in-list search field is gone: the tab's app bar
                    // already has a search button, and two ways to search one
                    // list is one too many — the field also took a row of
                    // every screen, including the ones with two servers on
                    // them. The filter itself stays, driven from the app bar.
                    if (communities.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text('No servers match your search.',
                              style:
                                  TextStyle(color: AppColors.subtle(context))),
                        ),
                      ),
                    for (final c in communities) _CommunityCard(community: c),
                    const _NearbySection(),
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
                        community.hasGradient
                            ? _hex(community.color2)
                            : Color.lerp(base, Colors.black, 0.28) ?? base,
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
                      // A Wrap, not a Row: channels, members, online and in
                      // voice all at once ran 28 points past a 320-point
                      // phone. Metadata is exactly what wrapping is for — the
                      // fourth item drops to a second line instead of off the
                      // card.
                      Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _meta(context, Icons.tag, '$channels'),
                          _meta(context, Icons.people_alt_outlined, '$members'),
                          if (online > 0)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.circle,
                                    size: 8, color: Color(0xFF43B581)),
                                const SizedBox(width: 4),
                                Text('$online online',
                                    style: const TextStyle(
                                        fontSize: 12.5,
                                        color: Color(0xFF43B581),
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          // Live off the community bus, so this is the one
                          // number on the card that reflects real activity.
                          if (inVoice > 0)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.volume_up_rounded,
                                    size: 14, color: Colors.green.shade600),
                                const SizedBox(width: 4),
                                Text('$inVoice in voice',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: Colors.green.shade600,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                        ],
                      ),
                      if (community.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(community.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5, color: AppColors.subtle(context))),
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

  Widget _meta(BuildContext context, IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.subtle(context)),
          const SizedBox(width: 4),
          Text(label,
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
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
    final me = AppState.profile.value;
    // The REAL invite code: a self-contained snapshot the recipient pastes into
    // Servers → Join with a code. Carries the E2E secret, so it is as sensitive
    // as the invite card — share it privately.
    final code = CommunityStore.instance.inviteToken(
          community.id,
          myDigits: me.phone.replaceAll(RegExp(r'\D'), ''),
          myName: me.name,
        ) ??
        '';
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
              Text('Share this code — they paste it into '
                  'Servers → Join with a code.',
                  style:
                      TextStyle(fontSize: 13, color: AppColors.subtle(context))),
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
                      child: Text(code,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'Copy invite code',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite code copied')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Admins can skip the wait: add contacts straight into the server.
              if (CommunityStore.instance.canManageServer(community.id)) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.group_add_outlined, size: 18),
                    label: const Text('Add members'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            AddServerMembersScreen(community: community),
                      ));
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
              // The invite that actually works end-to-end: a card in a chat
              // the other person can join with one tap.
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
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
                      community.hasGradient
                          ? _hex(community.color2)
                          : _hex(community.color).withValues(alpha: 0.55),
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
                    // Growing the server is the banner's one call to action
                    // — for those the invite policy lets share it.
                    if (CommunityStore.instance.canInvite(communityId))
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
                            fontSize: 12.5, color: AppColors.subtle(context))),
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
                          fontSize: 13.5, color: AppColors.subtle(context))),
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
                                  color: AppColors.subtle(context))),
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
                              size: 14, color: AppColors.subtle(context)),
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
                                : AppColors.subtle(context),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              o.isMe ? '${o.name} (you)' : o.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.subtle(context),
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

  /// The channel whose room screen is currently mounted, or null. The
  /// return-to-voice pill reads this so it doesn't float over the very
  /// screen it would return to.
  static final ValueNotifier<String?> onScreenFor = ValueNotifier(null);

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
    VoiceChannelScreen.onScreenFor.value = widget.channelId;
    // A share that started and then produced no pictures stops itself —
    // this is where the room hears about it, and where everyone else's
    // "sharing" badge comes back off.
    RoomMedia.instance.shareFailure.addListener(_onShareFailure);
    // Walking back into a room you never left: the clock and its tick both
    // resume from the store's join time, not from zero.
    if (_joined) {
      _joinedAt = _voice.joinedAt ?? DateTime.now();
      _startTick();
    }
  }

  void _onShareFailure() {
    final reason = RoomMedia.instance.shareFailure.value;
    if (reason == null || !mounted) return;
    if (_joined) _voice.setLocalState(screen: false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(reason)));
  }

  @override
  void dispose() {
    _tick?.cancel();
    RoomMedia.instance.shareFailure.removeListener(_onShareFailure);
    // Deliberately NOT leaving the room: presence belongs to the store, so
    // you stay in voice while browsing the rest of the app (or leaving it —
    // a long suspension ages you out via the heartbeat, and coming back
    // re-announces). The return-to-voice pill is the way back; Leave is the
    // way out.
    if (VoiceChannelScreen.onScreenFor.value == widget.channelId) {
      VoiceChannelScreen.onScreenFor.value = null;
    }
    super.dispose();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _join() {
    // Full is full, before presence says otherwise: joining the roster of
    // a room the mesh cannot seat would show a member nobody can hear.
    if (!_voice.amIn(widget.channelId) &&
        _voice.countIn(widget.channelId) >= RoomMedia.maxRoomSize) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This room is full for voice — device-to-device '
              'audio holds ${RoomMedia.maxRoomSize} people. A spot opens '
              'when somebody leaves.')));
      return;
    }
    _voice.join(
      communityId: widget.communityId,
      channelId: widget.channelId,
      myName: AppState.profile.value.name,
    );
    // The room's actual sound: the mesh opens the mic and dials everyone
    // presence already shows. A refused microphone still leaves you IN the
    // room (visible, listening to nothing) with the reason on screen.
    unawaited(RoomMedia.instance
        .joinRoom(widget.communityId, widget.channelId)
        .then((problem) {
      if (problem != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(problem)));
      }
    }));
    setState(() => _joinedAt = _voice.joinedAt ?? DateTime.now());
    _startTick();
  }

  void _leave() {
    _tick?.cancel();
    _tick = null;
    unawaited(RoomMedia.instance.leaveRoom());
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
      listenable: Listenable.merge([
        CommunityStore.instance,
        VoicePresenceStore.instance,
        // Remote video arriving (or ending) redraws the tiles it fills.
        RoomMedia.instance,
      ]),
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
        // The room is a stage, so it is dark like the call screen is dark —
        // in both themes, because a voice room lit like a settings page
        // reads as a settings page.
        return Scaffold(
          backgroundColor: const Color(0xFF16181C),
          appBar: AppBar(
            backgroundColor: const Color(0xFF16181C),
            foregroundColor: Colors.white,
            elevation: 0,
            title: Row(
              children: [
                const Icon(Icons.volume_up_rounded,
                    size: 20, color: Colors.white70),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(channel.name,
                          style: const TextStyle(
                              fontSize: 17, color: Colors.white)),
                      if (_joined)
                        // The weakest leg of the mesh, said in words when
                        // it is worth saying — silence about a bad link
                        // reads as "the app is broken".
                        Text(
                            switch (RoomMedia.instance.roomQuality.value) {
                              1 => 'Connected · $_elapsed · poor connection',
                              2 => 'Connected · $_elapsed · weak connection',
                              _ => 'Connected · $_elapsed',
                            },
                            style: TextStyle(
                                fontSize: 12,
                                color: switch (
                                    RoomMedia.instance.roomQuality.value) {
                                  1 => const Color(0xFFFF6B6B),
                                  2 => const Color(0xFFF7931A),
                                  _ => const Color(0xFF1DB954),
                                }))
                      else if (occupants.isNotEmpty)
                        Text(
                            '${occupants.length} '
                            '${occupants.length == 1 ? 'person' : 'people'} in voice',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              if (channel.topic.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(channel.topic,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: Colors.white38)),
                ),
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
            Container(
              padding: const EdgeInsets.all(22),
              decoration: const BoxDecoration(
                color: Color(0xFF23262D),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.headset_mic_outlined,
                  size: 44, color: Colors.white38),
            ),
            const SizedBox(height: 16),
            Text('No one is in ${channel.name}',
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 4),
            const Text('Join to start the conversation',
                style: TextStyle(color: Colors.white38, fontSize: 12.5)),
          ],
        ),
      );
    }
    final me = AppState.profile.value;
    // Two columns of room-style tiles, like a call grid — the room LOOKS
    // like the thing it is.
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
      children: [
        for (final o in occupants)
          _memberTile(
            label: o.isMe ? 'You' : o.name,
            // A tile with live pictures shows them; everyone else stays an
            // avatar. Mine previews what I'm sending; theirs renders what
            // the mesh received.
            live: o.isMe
                ? ((RoomMedia.instance.cameraOn.value ||
                            RoomMedia.instance.screenSharing.value) &&
                        RoomMedia.instance.localRenderer != null
                    ? RTCVideoView(RoomMedia.instance.localRenderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: !RoomMedia.instance.screenSharing.value)
                    : null)
                : ((o.video || o.screen) &&
                        RoomMedia.instance.rendererFor(o.digits) != null
                    ? RTCVideoView(RoomMedia.instance.rendererFor(o.digits)!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                    : null),
            avatar: o.isMe
                ? UserAvatar(user: me, radius: 32)
                : CircleAvatar(
                    radius: 32,
                    backgroundColor: _hex(community.color),
                    child: Text(
                        o.name.isEmpty ? '?' : o.name[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w700)),
                  ),
            // With the mesh live the ring means what everyone assumes it
            // means: this person is audibly talking, read off the media
            // stats. Without media (mesh unsupported, mic refused) it falls
            // back to "not muted" — the most presence alone can claim.
            speaking: RoomMedia.instance.active
                ? (o.isMe
                    ? RoomMedia.instance.amSpeaking && !_muted
                    : RoomMedia.instance.isSpeaking(o.digits))
                : !o.muted && !(o.isMe && _deafened),
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
    Widget? live,
    bool speaking = false,
    bool muted = false,
    bool deafened = false,
    bool video = false,
    bool screen = false,
  }) {
    const green = Color(0xFF1DB954);
    // A 2.5px border on a dark tile was easy to miss, and "am I speaking?"
    // is a question the answer has to jump out at. Thicker ring plus a glow,
    // so it reads at a glance and from across a room.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: const Color(0xFF23262D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: speaking ? green : Colors.transparent,
          width: speaking ? 3.5 : 2.5,
        ),
        boxShadow: speaking
            ? [
                BoxShadow(
                  color: green.withValues(alpha: 0.45),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          if (live != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15.5),
                child: live,
              ),
            ),
          if (live != null)
            // The name moves onto the picture instead of vanishing under it.
            Positioned(
              left: 10,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (muted) ...[
                      const Icon(Icons.mic_off,
                          size: 12, color: Colors.redAccent),
                      const SizedBox(width: 4),
                    ],
                    Text(label,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ],
                ),
              ),
            ),
          if (live == null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatar,
                  const SizedBox(height: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (deafened) ...[
                        const Icon(Icons.headset_off,
                            size: 14, color: Colors.redAccent),
                        const SizedBox(width: 4),
                      ] else if (muted) ...[
                        const Icon(Icons.mic_off,
                            size: 14, color: Colors.redAccent),
                        const SizedBox(width: 4),
                      ] else if (speaking) ...[
                        // A ring alone left people asking "is that me?" — a
                        // lit mic beside the name answers it outright.
                        const Icon(Icons.mic, size: 14, color: green),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (video || screen)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (screen)
                      const Icon(Icons.screen_share,
                          size: 13, color: green),
                    if (screen && video) const SizedBox(width: 5),
                    if (video)
                      const Icon(Icons.videocam, size: 13, color: green),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controlBar() {
    // Fixed colors: the room is dark in both themes, so theme-derived
    // subtle greys would vanish into (or glare against) the stage.
    const idle = Color(0xFF2E323B);
    const active = Color(0xFF1DB954);
    return SafeArea(
      top: false,
      // The bottom inset alone leaves the button flush against the home
      // indicator, so add real space under it as well.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: _joined
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2129),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _voiceButton(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      label: _muted ? 'Unmute' : 'Mute',
                      color: _muted ? Colors.redAccent : idle,
                      onTap: () {
                        final nowMuted = !_muted;
                        if (!nowMuted) {
                          _deafened = false;
                          RoomMedia.instance.setDeafened(false);
                        }
                        RoomMedia.instance.setMuted(nowMuted);
                        _voice.setLocalState(muted: nowMuted);
                        setState(() {});
                      },
                    ),
                    _voiceButton(
                      icon: _deafened ? Icons.headset_off : Icons.headset_mic,
                      label: 'Deafen',
                      color: _deafened ? Colors.redAccent : idle,
                      onTap: () {
                        _deafened = !_deafened;
                        RoomMedia.instance.setDeafened(_deafened);
                        // Deafening also mutes you, à la Discord.
                        if (_deafened) {
                          RoomMedia.instance.setMuted(true);
                          _voice.setLocalState(muted: true);
                        }
                        setState(() {});
                      },
                    ),
                    _voiceButton(
                      icon: _video ? Icons.videocam : Icons.videocam_off,
                      label: 'Video',
                      color: _video ? active : idle,
                      onTap: () {
                        final on = !_video;
                        unawaited(RoomMedia.instance.enableCamera(on));
                        _voice.setLocalState(video: on);
                      },
                    ),
                    _voiceButton(
                      icon: _screen
                          ? Icons.stop_screen_share
                          : Icons.screen_share,
                      label: 'Screen',
                      color: _screen ? active : idle,
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final problem =
                            await RoomMedia.instance.toggleScreenShare();
                        if (problem != null) {
                          messenger.showSnackBar(
                              SnackBar(content: Text(problem)));
                          return;
                        }
                        _voice.setLocalState(
                            screen: RoomMedia.instance.screenSharing.value);
                      },
                    ),
                    _voiceButton(
                      icon: Icons.call_end,
                      label: 'Leave',
                      color: Colors.red,
                      onTap: _leave,
                    ),
                  ],
                ),
              )
            : SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.white,
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
                style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
          ],
        ],
      );
}

/// A channel's message view: a simple list plus a composer. Announcement
/// channels look the same but read as broadcast posts.
class ChannelScreen extends StatefulWidget {
  /// Test seam: when set, a voice-note recording skips the real microphone and
  /// this supplies the captured clip's raw bytes. Mirrors
  /// [ChatInputBar.debugCaptureOverride] — there is no mic in a test.
  @visibleForTesting
  static Future<Uint8List?> Function()? debugCaptureOverride;

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

  // Voice notes — the same recorder the 1:1/group composer uses, so a channel
  // clip records, rides the relay and plays back identically.
  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  final AudioRecorder _recorder = AudioRecorder();

  /// The composer auto-stops here, the same ceiling the chat composer uses so
  /// a clip always fits the bucket (and a short one the relay envelope).
  static const int _maxVoiceSeconds = 300;

  Future<Uint8List?> Function()? get _debugCaptureOverride =>
      ChannelScreen.debugCaptureOverride;

  String get _recordLabel {
    final m = _recordSeconds ~/ 60;
    final s = _recordSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

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
    _recordTimer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    _search.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// The moderation gate every send goes through: an app-wide sanction, the
  /// server's word filter (when [text] is given), and slow mode. Explains
  /// itself in a snackbar.
  bool _sendAllowed({String? text}) {
    final store = CommunityStore.instance;
    final community = store.byId(widget.communityId);
    if (community == null) return false;
    // An app-wide sanction outranks any one server's rules.
    if (PlatformModeration.instance.isSilenced) {
      final s = PlatformModeration.instance.sanction!;
      final left = sanctionRemaining(s.until, DateTime.now().toUtc());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(left.isEmpty
              ? '${sanctionKindLabel(s.kind)} — you can\'t send right now'
              : '${sanctionKindLabel(s.kind)} — you can send again in '
                  '$left')));
      return false;
    }
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

  Future<void> _startRecording() async {
    if (!_sendAllowed()) return;
    // No permission, no recording — and no fake bubble either. Skipped under
    // the test seam, which has no mic to ask.
    if (_debugCaptureOverride == null && !await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Microphone access is needed for voice notes.')));
      }
      return;
    }
    Haptics.press();
    setState(() {
      _recording = true;
      _recordSeconds = 0;
    });
    if (_debugCaptureOverride == null) {
      try {
        final path = kIsWeb
            ? ''
            : '${(await getTemporaryDirectory()).path}/'
                'vn_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await _recorder.start(
          const RecordConfig(
              encoder: AudioEncoder.aacLc,
              bitRate: 20000,
              sampleRate: 22050,
              numChannels: 1),
          path: path,
        );
      } catch (_) {
        _recordTimer?.cancel();
        if (mounted) setState(() => _recording = false);
        return;
      }
    }
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
      if (_recordSeconds >= _maxVoiceSeconds) _finishRecording();
    });
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    if (_debugCaptureOverride == null) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _finishRecording() async {
    _recordTimer?.cancel();
    Haptics.tap();
    final seconds = _recordSeconds < 1 ? 1 : _recordSeconds;
    if (mounted) setState(() => _recording = false);

    Uint8List? bytes;
    if (_debugCaptureOverride != null) {
      bytes = await _debugCaptureOverride!();
    } else {
      String? path;
      try {
        path = await _recorder.stop();
      } catch (_) {}
      bytes = path == null ? null : await _readAudio(path);
    }
    if (bytes == null || bytes.isEmpty) {
      _voiceError('Couldn\'t save that voice note — try again.');
      return;
    }
    _handleSendVoice(seconds, bytes);
  }

  /// Posts a captured clip into the channel. Short enough to ride the relay
  /// inline → a `data:` URI; longer → sealed into the voice-notes bucket, only
  /// the path + key on the wire — the exact split the 1:1 composer makes.
  Future<void> _handleSendVoice(int seconds, Uint8List bytes) async {
    _lastSentAt = DateTime.now();
    final b64 = base64Encode(bytes);
    if (b64.length <= PhotoPrep.maxBase64Length) {
      _postVoice(seconds, audioUrl: 'data:audio/mp4;base64,$b64');
      return;
    }
    try {
      final up = await VoiceMedia.instance.upload(bytes);
      _postVoice(seconds, audioPath: up.path, audioKey: up.key);
    } on VoiceMediaError catch (e) {
      _voiceError(e.reason);
    } catch (_) {
      _voiceError('Couldn\'t upload that voice note — check your connection.');
    }
  }

  void _postVoice(int seconds,
      {String? audioUrl, String? audioPath, String? audioKey}) {
    final reply = _replyTo;
    final now = DateTime.now();
    _post(Message(
      id: 'ch_vn_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isVoice: true,
      voiceSeconds: seconds,
      audioUrl: audioUrl,
      audioPath: audioPath,
      audioKey: audioKey,
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
    if (mounted) setState(() => _replyTo = null);
  }

  void _voiceError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// The recorded clip's raw bytes. On the web `stop()` hands back a `blob:`
  /// URL whose bytes are fetched; elsewhere it is a file path.
  Future<Uint8List?> _readAudio(String path) async {
    try {
      return kIsWeb
          ? (await http.get(Uri.parse(path))).bodyBytes
          : await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// The red "Recording…" bar shown in place of the composer while a channel
  /// voice note is being captured — the same shape as the chat composer's.
  Widget _buildChannelRecordingBar(Color fieldColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: fieldColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _cancelRecording,
                    tooltip: 'Cancel',
                  ),
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 14),
                  const SizedBox(width: 8),
                  Text(_recordLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('Recording…', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _finishRecording,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.accentOn(context),
              child: Icon(Icons.send, color: AppColors.onAccent(context)),
            ),
          ),
        ],
      ),
    );
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
  Future<void> _pickEmojiOrGif({int initialTab = 0}) async {
    final picked = await showEmojiGifSheet(context, initialTab: initialTab);
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

  /// Why the composer is locked here, or null when the user may type:
  /// announcement channels are admin-only, and a broadcast-only server
  /// silences plain members everywhere.
  (IconData, String)? _composerLock(Community community, Channel channel) {
    if (!_canPost(community, channel)) {
      return (Icons.campaign_outlined, 'Only admins can post in this channel');
    }
    if (!CommunityStore.instance.canSendMessages(community.id)) {
      return (
        Icons.lock_outline,
        'This server is read-only — only moderators can send messages'
      );
    }
    return null;
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
                          fontSize: 13, color: AppColors.subtle(context))),
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
                            style: TextStyle(color: AppColors.subtle(context))),
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
                            onQuickReact: () => channelReact(
                                widget.communityId,
                                widget.channelId,
                                m.id,
                                '❤️'),
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
              // A locked composer explains itself instead of vanishing:
              // announcement channels are admin-only, and a broadcast-only
              // server silences plain members everywhere. The composer stays
              // hidden while searching so results fill the screen.
              if (_searching)
                const SizedBox.shrink()
              else if (_composerLock(comm, channel) != null)
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
                        Icon(_composerLock(comm, channel)!.$1,
                            size: 18, color: AppColors.subtle(context)),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(_composerLock(comm, channel)!.$2,
                              style: TextStyle(
                                  color: AppColors.subtle(context),
                                  fontSize: 13.5)),
                        ),
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
                                      color: AppColors.subtle(context))),
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
                              color: AppColors.accentOn(context),
                              onTap: () {
                                setState(() => _attachOpen = false);
                                _sendPhoto();
                              },
                            ),
                            const SizedBox(width: 10),
                            _attachOption(
                              icon: Icons.poll_outlined,
                              label: 'Poll',
                              color: AppColors.accentOn(context),
                              onTap: () {
                                setState(() => _attachOpen = false);
                                _createPoll();
                              },
                            ),
                          ],
                        ),
                      ),
                    Builder(builder: (context) {
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      // The exact pill-card the 1:1 chat composer wears: soft
                      // grey fill, a faint edge and low shadow for lift, the
                      // message across the top and the controls along the
                      // bottom — no boxed field.
                      final fieldColor = isDark
                          ? AppColors.darkAppBar
                          : const Color(0xFFEFF1F3);
                      final cardBorder = isDark
                          ? const Color(0xFF2C2F34)
                          : const Color(0xFFEAECEF);
                      final iconTint =
                          isDark ? Colors.white70 : const Color(0xFF6B7280);
                      // Recording swaps the whole card for the same red
                      // "Recording…" bar the chat composer shows.
                      if (_recording) {
                        return _buildChannelRecordingBar(fieldColor);
                      }
                      final hasText = _controller.text.trim().isNotEmpty;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: fieldColor,
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(color: cardBorder, width: 1),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? 0.22 : 0.05),
                                blurRadius: 12,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.fromLTRB(18, 6, 8, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _controller,
                                minLines: 1,
                                maxLines: 6,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: InputDecoration(
                                  hintText: 'Message #${channel.name}',
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  isCollapsed: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(vertical: 11),
                                ),
                                onChanged: (v) {
                                  if (v.isNotEmpty) {
                                    ChannelTypingStore.instance.noteLocalTyping(
                                        widget.communityId, widget.channelId);
                                  }
                                  setState(() {});
                                },
                                onSubmitted: (_) => _send(),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  IconButton(
                                    icon: Icon(_attachOpen
                                        ? Icons.close
                                        : Icons.add_circle_outline),
                                    color: iconTint,
                                    tooltip: 'Attach',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      setState(
                                          () => _attachOpen = !_attachOpen);
                                      if (_attachOpen) {
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.emoji_emotions_outlined),
                                    color: iconTint,
                                    tooltip: 'Emoji',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _pickEmojiOrGif,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.gif_box_outlined),
                                    color: iconTint,
                                    tooltip: 'GIF',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _pickEmojiOrGif(initialTab: 1),
                                  ),
                                  const Spacer(),
                                  // Text → filled send circle; empty → a mic
                                  // that starts recording, exactly like chat.
                                  GestureDetector(
                                    onTap:
                                        hasText ? _send : _startRecording,
                                    child: hasText
                                        ? Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color:
                                                  AppColors.accentOn(context),
                                            ),
                                            child: Icon(Icons.send,
                                                size: 19,
                                                color: AppColors.onAccent(
                                                    context)),
                                          )
                                        : Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: Icon(Icons.mic,
                                                size: 22, color: iconTint),
                                          ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
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
                    channelPin(widget.communityId, widget.channelId, m.id);
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
                    style: TextStyle(color: AppColors.subtle(context))),
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
                            : AppColors.subtle(context),
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
                  if (community.roleById(m.roleId) case final r?)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _CustomRoleChip(role: r),
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
              // Custom roles the server has defined — a coloured badge that can
              // also grant powers, assigned on top of the built-in role.
              if ((store.byId(community.id)?.roles ?? const []).isNotEmpty) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: const Text('Assign a role'),
                  subtitle: Text(
                      store.byId(community.id)?.roleById(m.roleId)?.name ??
                          'None'),
                  onTap: () => Navigator.pop(context, 'crole'),
                ),
              ],
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
      case 'crole':
        if (context.mounted) await _pickCustomRole(context, m);
        break;
      case 'remove':
        store.removeMember(community.id, m.id);
        break;
      case 'ban':
        store.banMember(community.id, m.id);
        break;
    }
  }

  /// Picks (or clears) the custom role a member wears, from the roles the
  /// server has defined.
  Future<void> _pickCustomRole(BuildContext context, Member m) async {
    final store = CommunityStore.instance;
    final roles = store.byId(community.id)?.roles ?? const [];
    final current = m.roleId;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Role for ${m.name}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(current.isEmpty
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: const Text('No role'),
              onTap: () => Navigator.pop(context, '__none__'),
            ),
            for (final r in roles)
              ListTile(
                onTap: () => Navigator.pop(context, r.id),
                leading: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                      color: Color(int.parse(
                          r.color.replaceFirst('#', 'ff'),
                          radix: 16)),
                      shape: BoxShape.circle),
                  child: current == r.id
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
                title: Text(r.name),
                subtitle: Text(roleTierBlurb(r.tier),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    // A sentinel stands in for the empty string, which the sheet can't return
    // as a distinct "clear" without colliding with "dismissed".
    store.assignRole(community.id, m.id, picked == '__none__' ? '' : picked);
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
      MemberRole.admin => AppColors.accentOn(context),
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

/// A member's custom-role badge: the role's colour and name, shown beside them
/// in the roster.
class _CustomRoleChip extends StatelessWidget {
  final CustomRole role;
  const _CustomRoleChip({required this.role});

  @override
  Widget build(BuildContext context) {
    final color =
        Color(int.parse(role.color.replaceFirst('#', 'ff'), radix: 16));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (role.badge.isNotEmpty)
            Text(role.badge, style: const TextStyle(fontSize: 12))
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 5),
          Text(role.name,
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
                  color: AppColors.subtle(context))),
        ),
      ),
    );
  }
}

// Changing a channel message, locally and for everyone else.
//
// All four of these used to stop at this device: you deleted your message and
// every other member kept reading it, you edited it and only you saw the new
// words, you reacted and nobody knew, a moderator pinned and the banner moved
// on one phone. Posting was the only channel action that ever left the device.
//
// Each sends the *result* rather than "toggle" — a toggle applied on two
// devices cancels itself out, which is how a pin ends up on for half a server.

void channelReact(String communityId, String channelId, String messageId,
    String emoji) {
  final on = CommunityStore.instance
      .toggleChannelReaction(communityId, channelId, messageId, emoji);
  if (RelayConfig.isEnabled) {
    RelayService.instance
        .sendChannelReaction(communityId, channelId, messageId, emoji, add: on);
  }
}

void channelEdit(String communityId, String channelId, String messageId,
    String text) {
  CommunityStore.instance
      .editChannelMessage(communityId, channelId, messageId, text);
  if (RelayConfig.isEnabled) {
    RelayService.instance
        .sendChannelMessageEdited(communityId, channelId, messageId, text);
  }
}

void channelPin(String communityId, String channelId, String messageId) {
  final pinned = CommunityStore.instance
      .togglePinChannelMessage(communityId, channelId, messageId);
  if (RelayConfig.isEnabled) {
    RelayService.instance.sendChannelPin(communityId, channelId, messageId,
        pinned: pinned);
  }
}

void channelDelete(String communityId, String channelId, String messageId) {
  CommunityStore.instance
      .deleteChannelMessage(communityId, channelId, messageId);
  if (RelayConfig.isEnabled) {
    RelayService.instance
        .sendChannelMessageDeleted(communityId, channelId, messageId);
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

  void _react(String emoji) =>
      channelReact(communityId, channelId, message.id, emoji);

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
    channelEdit(communityId, channelId, message.id, text);
  }

  Future<void> _showActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scrollable and free of the half-height default: react, reply, pin,
      // edit, forward, copy and delete do not fit a short screen, and the
      // ones that fall off the bottom are the ones you came for.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
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
              // Spark: real money to whoever said this, the same transfer
              // the feeds' bolt makes. Offered only when the sender's
              // digits rode on the message — an older message carries none
              // and shows no bolt, same rule as legacy feed posts.
              if (!message.isMe &&
                  message.senderPhone.isNotEmpty &&
                  PaymentService.instance.isConfigured)
                ListTile(
                  leading: const Icon(Icons.bolt, color: Color(0xFFF7931A)),
                  title: const Text('Spark'),
                  subtitle: Text('Send money to '
                      '${message.senderName.isEmpty ? 'the sender' : message.senderName}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    offerSparkTo(context,
                        toPhone: message.senderPhone,
                        toName: message.senderName.isEmpty
                            ? 'the sender'
                            : message.senderName);
                  },
                ),
              // A channel pin is on a banner every member sees, so it is a
              // moderator's call. It used to be offered to everyone, and the
              // store took it — one member could pin over another's pin.
              if (CommunityStore.instance.canModerate(communityId))
                ListTile(
                  leading: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(pinned ? 'Unpin' : 'Pin'),
                  onTap: () {
                    channelPin(communityId, channelId, message.id);
                    Navigator.pop(sheetContext);
                  },
                ),
              if (message.isMe &&
                  !message.isPoll &&
                  !message.isImage &&
                  !message.isVoice)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _edit(context);
                  },
                ),
              // A message you cannot move is a message trapped in the channel
              // it was posted to. A 1:1 chat has had this the whole time; a
              // channel had reply, react, pin, edit, copy, delete — and no way
              // to pass anything on. A poll is the one thing left behind:
              // forwarding it as text would lose the vote it exists for.
              if (!message.isPoll &&
                  (message.isImage || message.text.trim().isNotEmpty))
                ListTile(
                  leading: const Icon(Icons.forward),
                  title: const Text('Forward'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ForwardScreen(
                            text: message.text,
                            imageUrl:
                                message.isImage ? message.imageUrl : null)));
                  },
                ),
              if (message.text.trim().isNotEmpty)
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
              // Moderators are told they can "delete/pin messages, mute, kick,
              // ban" — but the only delete wired up was your own, so the one
              // thing moderation is actually for could not be done from the
              // message itself.
              if (message.isMe ||
                  CommunityStore.instance.canModerate(communityId))
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: Text(message.isMe ? 'Delete' : 'Remove message',
                      style: const TextStyle(color: Colors.red)),
                  subtitle: message.isMe
                      ? null
                      : const Text('Deletes it for everyone in the channel'),
                  onTap: () {
                    channelDelete(communityId, channelId, message.id);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Announcement messages render as full-width news cards, not chat bubbles.
  Widget _newsCard(BuildContext context) {
    final accent = AppColors.accentOn(context);
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
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.campaign, size: 15, color: accent),
                const SizedBox(width: 5),
                Text('ANNOUNCEMENT',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: accent)),
                const Spacer(),
                Text(DateFormatter.messageTime(message.time),
                    style:
                        TextStyle(fontSize: 11, color: AppColors.subtle(context))),
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
                        : AppColors.accentOn(context))
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
                  if (message.isVoice)
                    VoiceNoteBubble(
                      seconds: message.voiceSeconds,
                      audioUrl: message.audioUrl,
                      audioPath: message.audioPath,
                      audioKey: message.audioKey,
                      textColor: onBubble,
                      metaColor: metaColor,
                    )
                  else if (message.isPoll)
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
                          : AppColors.accentOn(context),
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

/// Servers somebody in the room is in, heard over Bluetooth.
///
/// Only ever servers whose owner turned discovery on — a beacon puts a name in
/// the air for every stranger nearby, so it is never a side effect of being a
/// member. Nothing shows here at all when nothing has been heard, which on
/// almost every screen is the case.
class _NearbySection extends StatelessWidget {
  const _NearbySection();

  @override
  Widget build(BuildContext context) {
    final nearby = NearbyServers.instance.servers;
    if (nearby.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
          child: Row(
            children: [
              Icon(Icons.bluetooth_searching,
                  size: 15, color: AppColors.subtle(context)),
              const SizedBox(width: 6),
              Text('NEARBY',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppColors.subtle(context))),
            ],
          ),
        ),
        for (final server in nearby) _NearbyCard(server: server),
      ],
    );
  }
}

class _NearbyCard extends StatefulWidget {
  final NearbyServer server;
  const _NearbyCard({required this.server});

  @override
  State<_NearbyCard> createState() => _NearbyCardState();
}

class _NearbyCardState extends State<_NearbyCard> {
  bool _asking = false;

  /// Asks whoever is near for the way in, then joins when it arrives.
  ///
  /// Two steps rather than one because the answer comes off a radio from
  /// somebody else's phone: it may take a moment, and it may never come at
  /// all — the person who could answer may have walked out of range between
  /// their beacon and this tap.
  Future<void> _join() async {
    setState(() => _asking = true);
    final mesh = MeshService.instance;
    await mesh.requestInvite(widget.server.id);
    // A handful of seconds: long enough for a neighbour to hear, answer, and
    // for the reply to make its way back.
    for (var i = 0; i < 20 && mounted; i++) {
      if (mesh.hasInviteFor(widget.server.id)) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    final joined = mesh.joinNearby(widget.server.id);
    setState(() => _asking = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(joined
          ? 'Joined ${widget.server.name}.'
          : 'No one nearby answered. They may have moved out of range.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
              server.icon.isNotEmpty
                  ? server.icon
                  : (server.name.isEmpty ? '?' : server.name[0].toUpperCase()),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        title: Text(server.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        // Their claim, said as theirs — the number came off the air from a
        // phone nobody here has any reason to believe.
        subtitle: Text('Nearby · ${server.members} '
            '${server.members == 1 ? 'member' : 'members'}'),
        trailing: _asking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : FilledButton(onPressed: _join, child: const Text('Join')),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    // EmptyState has always taken a button; this screen told people to create
    // a server and left them to find the small + in the corner themselves.
    // Joining with a code is the quieter second way in, under the primary one.
    return EmptyState(
      icon: Icons.groups_outlined,
      title: 'No servers yet',
      caption:
          'Create a server to organise channels with friends or a team — '
          'or join one with a code someone shared.',
      actionLabel: 'Create a server',
      onAction: () => createCommunityFlow(context),
      secondaryLabel: 'Join with a code',
      onSecondary: () => joinByCodeFlow(context),
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
                    color: AppColors.subtle(context),
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
                    color: AppColors.subtle(context),
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
                  style: TextStyle(fontSize: 12, color: AppColors.subtle(context)),
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
                    color: selected ? scheme.primary : AppColors.subtle(context)),
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
                              fontSize: 12.5, color: AppColors.subtle(context))),
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
