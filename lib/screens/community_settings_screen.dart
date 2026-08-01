import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../models/community.dart';
import '../state/community_store.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

const serverPalette = [
  '#7A5CFF', '#12B76A', '#F1C40F', '#EF5DA8', '#009DE2',
  '#F97052', '#8B5CF6', '#0F1419',
];

/// Emoji a server can wear instead of its first letter.
const serverEmojis = [
  '🎮', '🎨', '🎵', '📚', '💼', '⚽', '🍕', '🚀',
  '🌟', '🔥', '💬', '🛠️', '🏠', '🎬', '📷', '🌈',
];

/// The slow-mode choices offered, in seconds (0 = off).
const slowModeChoices = [0, 5, 10, 30, 60, 300];

/// Label for a slow-mode value, e.g. "Off", "30s", "5m".
String slowModeLabel(int seconds) {
  if (seconds <= 0) return 'Off';
  if (seconds < 60) return '${seconds}s';
  return '${seconds ~/ 60}m';
}

/// Human label for an invite policy value.
String invitePolicyLabel(String policy) => switch (policy) {
      invitePolicyModerators => 'Moderators',
      invitePolicyAdmins => 'Admins only',
      _ => 'Everyone',
    };

/// Owner/admin controls for a community: identity (name, icon, color,
/// description), invites, and the moderation switchboard. Members without
/// manage rights get a read-only view of what the server is, plus the one
/// action that is theirs: leaving.
class CommunitySettingsScreen extends StatelessWidget {
  final String communityId;
  const CommunitySettingsScreen({super.key, required this.communityId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(communityId);
        if (community == null) {
          return const Scaffold(body: Center(child: Text('Not found')));
        }
        final store = CommunityStore.instance;
        if (!store.canManageServer(communityId)) {
          return _memberView(context, community);
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Server settings')),
          body: ListView(
            children: [
              const SizedBox(height: 8),
              Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: _hex(community.color),
                  child: Text(
                      community.icon.isNotEmpty
                          ? community.icon
                          : community.name[0].toUpperCase(),
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: community.icon.isNotEmpty
                              ? FontWeight.w400
                              : FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 16),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: 'Server name',
                  subtitle: community.name,
                  onTap: () => _rename(context, community),
                ),
                InfoTile(
                  leading: const Icon(Icons.notes_outlined),
                  title: 'Description',
                  subtitle: community.description.isEmpty
                      ? 'Add a description'
                      : community.description,
                  onTap: () => _editDescription(context, community),
                ),
              ]),
              _label(context, 'ICON'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // "Abc" returns to the plain letter avatar.
                    _iconChoice(
                      context,
                      selected: community.icon.isEmpty,
                      onTap: () => store.setCommunityIcon(communityId, ''),
                      child: Text(community.name[0].toUpperCase(),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    for (final e in serverEmojis)
                      _iconChoice(
                        context,
                        selected: community.icon == e,
                        onTap: () => store.setCommunityIcon(communityId, e),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                  ],
                ),
              ),
              _label(context, 'COLOR'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final c in serverPalette)
                      GestureDetector(
                        onTap: () => store.setCommunityColor(communityId, c),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _hex(c),
                            shape: BoxShape.circle,
                            border: community.color == c
                                ? Border.all(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    width: 3)
                                : null,
                          ),
                          child: community.color == c
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.link),
                  title: 'Invite link',
                  subtitle: CommunityStore.inviteLink(community),
                  trailing: const Icon(Icons.copy, size: 20),
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                        text: CommunityStore.inviteLink(community)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite link copied')),
                    );
                  },
                ),
              ]),
              _label(context, 'MODERATION'),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: 'Slow mode',
                  subtitle: community.slowModeSeconds == 0
                      ? 'Off'
                      : 'One message every '
                          '${slowModeLabel(community.slowModeSeconds)}',
                  onTap: () => _pickSlowMode(context, community),
                ),
                InfoTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: 'Who can invite people',
                  subtitle: invitePolicyLabel(community.invitePolicy),
                  onTap: () => _pickInvitePolicy(context, community),
                ),
                InfoTile(
                  leading: Icon(community.discoverableNearby
                      ? Icons.bluetooth_searching
                      : Icons.bluetooth_disabled),
                  title: 'Findable over Bluetooth',
                  subtitle: community.discoverableNearby
                      ? 'Anyone nearby can see this server\'s name and ask to '
                          'join. Whoever answers hands over the key that '
                          'decrypts it.'
                      : 'Off. People nearby cannot see this server exists.',
                  trailing: Switch(
                    value: community.discoverableNearby,
                    onChanged: (v) =>
                        store.setDiscoverableNearby(communityId, v),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: 'Members can send messages',
                  subtitle: community.membersCanMessage
                      ? null
                      : 'Broadcast-only: moderators speak, everyone reads',
                  trailing: Switch(
                    value: community.membersCanMessage,
                    onChanged: (v) =>
                        store.setMembersCanMessage(communityId, v),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.tag),
                  title: 'Members can create channels',
                  trailing: Switch(
                    value: community.membersCanCreateChannels,
                    onChanged: (v) =>
                        store.setMembersCanCreateChannels(communityId, v),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: 'Members can create forum posts',
                  trailing: Switch(
                    value: community.membersCanPost,
                    onChanged: (v) => store.setMembersCanPost(communityId, v),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.filter_alt_outlined),
                  title: 'Word filter',
                  subtitle: community.bannedWords.isEmpty
                      ? 'No filtered words'
                      : '${community.bannedWords.length} filtered '
                          '${community.bannedWords.length == 1 ? 'word' : 'words'}',
                  onTap: () => _editWordFilter(context),
                ),
                InfoTile(
                  leading: const Icon(Icons.block_outlined),
                  title: 'Banned members',
                  subtitle: community.bannedMembers.isEmpty
                      ? 'Nobody is banned'
                      : '${community.bannedMembers.length} banned',
                  onTap: () => _showBanned(context),
                ),
              ]),
              InfoSection(children: [
                if (store.myRole(communityId) == MemberRole.owner)
                  InfoTile(
                    leading:
                        const Icon(Icons.delete_outline, color: Colors.red),
                    title: 'Delete server',
                    titleColor: Colors.red,
                    onTap: () => _confirmDelete(context, community),
                  )
                else
                  InfoTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: 'Leave server',
                    titleColor: Colors.red,
                    onTap: () => _confirmLeave(context, community),
                  ),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  /// What a plain member sees: the server's identity, its rules as facts
  /// rather than switches, the invite link when the policy allows sharing,
  /// and the way out.
  Widget _memberView(BuildContext context, Community community) {
    final store = CommunityStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('About this server')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Center(
            child: CircleAvatar(
              radius: 40,
              backgroundColor: _hex(community.color),
              child: Text(
                  community.icon.isNotEmpty
                      ? community.icon
                      : community.name[0].toUpperCase(),
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: community.icon.isNotEmpty
                          ? FontWeight.w400
                          : FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(community.name,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          if (community.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 6, 32, 0),
              child: Text(community.description,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.subtle(context), fontSize: 13.5)),
            ),
          const SizedBox(height: 16),
          InfoSection(children: [
            InfoTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: 'Who can invite people',
              subtitle: invitePolicyLabel(community.invitePolicy),
            ),
            if (!community.membersCanMessage)
              const InfoTile(
                leading: Icon(Icons.lock_outline),
                title: 'Read-only server',
                subtitle: 'Only moderators can send messages',
              ),
            if (community.slowModeSeconds > 0)
              InfoTile(
                leading: const Icon(Icons.timer_outlined),
                title: 'Slow mode',
                subtitle: 'One message every '
                    '${slowModeLabel(community.slowModeSeconds)}',
              ),
          ]),
          if (store.canInvite(community.id))
            InfoSection(children: [
              InfoTile(
                leading: const Icon(Icons.link),
                title: 'Invite link',
                subtitle: CommunityStore.inviteLink(community),
                trailing: const Icon(Icons.copy, size: 20),
                onTap: () {
                  Clipboard.setData(ClipboardData(
                      text: CommunityStore.inviteLink(community)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invite link copied')),
                  );
                },
              ),
            ]),
          InfoSection(children: [
            InfoTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: 'Leave server',
              titleColor: Colors.red,
              onTap: () => _confirmLeave(context, community),
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppColors.subtle(context))),
      );

  Widget _iconChoice(BuildContext context,
      {required bool selected,
      required VoidCallback onTap,
      required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: selected ? Border.all(color: scheme.primary, width: 2) : null,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }

  Future<void> _pickSlowMode(BuildContext context, Community community) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Slow mode',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Limits how often members can send channel messages. '
                    'Admins are exempt.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ),
            ),
            for (final s in slowModeChoices)
              ListTile(
                leading: Icon(
                    community.slowModeSeconds == s
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: community.slowModeSeconds == s
                        ? Theme.of(sheetContext).colorScheme.primary
                        : Colors.grey),
                title: Text(s == 0
                    ? 'Off'
                    : 'One message every ${slowModeLabel(s)}'),
                onTap: () => Navigator.pop(sheetContext, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      CommunityStore.instance.setSlowMode(communityId, picked);
    }
  }

  Future<void> _pickInvitePolicy(
      BuildContext context, Community community) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Who can invite people',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Controls who may share this server\'s invite. People '
                    'already here stay either way.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ),
            ),
            for (final (policy, label, detail) in const [
              (invitePolicyEveryone, 'Everyone',
                  'Any member can share the invite'),
              (invitePolicyModerators, 'Moderators',
                  'Moderators, admins, and the owner'),
              (invitePolicyAdmins, 'Admins only',
                  'Only admins and the owner'),
            ])
              ListTile(
                leading: Icon(
                    community.invitePolicy == policy
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: community.invitePolicy == policy
                        ? Theme.of(sheetContext).colorScheme.primary
                        : Colors.grey),
                title: Text(label),
                subtitle: Text(detail),
                onTap: () => Navigator.pop(sheetContext, policy),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      CommunityStore.instance.setInvitePolicy(communityId, picked);
    }
  }

  Future<void> _confirmLeave(BuildContext context, Community community) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.logout,
      title: 'Leave "${community.name}"?',
      message: 'The server and its channels are removed from this device. '
          'An invite can bring you back.',
      confirmLabel: 'Leave server',
      destructive: true,
    );
    if (ok && context.mounted) {
      CommunityStore.instance.deleteCommunity(communityId);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _editWordFilter(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _WordFilterSheet(communityId: communityId),
    );
  }

  void _showBanned(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: CommunityStore.instance,
          builder: (context, _) {
            final banned =
                CommunityStore.instance.byId(communityId)?.bannedMembers ??
                    const <Member>[];
            return ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Banned members',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                if (banned.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('Nobody is banned from this server.',
                          style: TextStyle(color: AppColors.subtle(context))),
                    ),
                  ),
                for (final m in banned)
                  ListTile(
                    leading: const Icon(Icons.block, color: Colors.red),
                    title: Text(m.name),
                    trailing: TextButton(
                      child: const Text('Unban'),
                      onPressed: () => CommunityStore.instance
                          .unbanMember(communityId, m.id),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, Community community) async {
    final name = await showAppTextPrompt(
      context,
      icon: Icons.drive_file_rename_outline,
      title: 'Rename server',
      initial: community.name,
      capitalization: TextCapitalization.words,
    );
    if (name != null && name.isNotEmpty) {
      CommunityStore.instance.renameCommunity(communityId, name);
    }
  }

  Future<void> _editDescription(
      BuildContext context, Community community) async {
    final desc = await showAppTextPrompt(
      context,
      icon: Icons.notes,
      title: 'Server description',
      hint: 'What is this server about?',
      initial: community.description,
      maxLines: 3,
      allowEmpty: true,
      capitalization: TextCapitalization.sentences,
    );
    if (desc != null) {
      CommunityStore.instance.setCommunityDescription(communityId, desc);
    }
  }

  Future<void> _confirmDelete(BuildContext context, Community community) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Delete "${community.name}"?',
      message:
          'This permanently removes the server and all its channels for you.',
      confirmLabel: 'Delete server',
      destructive: true,
    );
    if (ok && context.mounted) {
      CommunityStore.instance.deleteCommunity(communityId);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }
}

/// Editor for the server's banned-word list: current words as removable
/// chips plus a field to add more.
class _WordFilterSheet extends StatefulWidget {
  final String communityId;
  const _WordFilterSheet({required this.communityId});

  @override
  State<_WordFilterSheet> createState() => _WordFilterSheetState();
}

class _WordFilterSheetState extends State<_WordFilterSheet> {
  final _word = TextEditingController();

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  void _add() {
    final w = _word.text.trim();
    if (w.isEmpty) return;
    CommunityStore.instance.addBannedWord(widget.communityId, w);
    _word.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // Keep the field above the keyboard.
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListenableBuilder(
          listenable: CommunityStore.instance,
          builder: (context, _) {
            final words =
                CommunityStore.instance.byId(widget.communityId)?.bannedWords ??
                    const <String>[];
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Word filter',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      'Messages and posts containing a filtered word are '
                      'blocked before they send. Admins are exempt.',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context))),
                  const SizedBox(height: 14),
                  if (words.isEmpty)
                    Text('No filtered words yet.',
                        style: TextStyle(color: AppColors.subtle(context)))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final w in words)
                          Chip(
                            label: Text(w),
                            deleteIcon: const Icon(Icons.close, size: 16),
                            onDeleted: () => CommunityStore.instance
                                .removeBannedWord(widget.communityId, w),
                          ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _word,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: 'Add a word to filter',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _add(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _add, child: const Text('Add')),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
