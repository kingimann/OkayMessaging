import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../models/community.dart';
import '../models/user.dart';
import '../state/community_store.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/emoji_data.dart';
import '../widgets/info_section.dart';
import 'community_roles_screen.dart';

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

const serverPalette = [
  '#7A5CFF', '#5865F2', '#009DE2', '#12B76A', '#2DD4BF',
  '#F1C40F', '#F97052', '#EF4444', '#EF5DA8', '#EC4899',
  '#8B5CF6', '#A855F7', '#64748B', '#0F1419',
];

/// Emoji a server can wear instead of its first letter — the quick picks;
/// "More…" opens the full emoji catalog for anything else.
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
              // A live preview of the look being edited — the header updates as
              // the icon, colour and gradient are changed below.
              _AppearancePreview(community: community),
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
                    // Any emoji, not just the quick picks.
                    _iconChoice(
                      context,
                      selected: community.icon.isNotEmpty &&
                          !serverEmojis.contains(community.icon),
                      onTap: () => _pickAnyEmoji(context, communityId),
                      child: const Icon(Icons.add, size: 20),
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
              _label(context, 'GRADIENT'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  'A second colour for the icon and header. Off for a solid look.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    // "None" clears the second colour.
                    GestureDetector(
                      onTap: () => store.setCommunityColor2(communityId, ''),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: community.color2.isEmpty
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outlineVariant,
                              width: community.color2.isEmpty ? 3 : 1),
                        ),
                        child: Icon(Icons.block,
                            color: AppColors.subtle(context), size: 20),
                      ),
                    ),
                    for (final c in serverPalette)
                      GestureDetector(
                        onTap: () => store.setCommunityColor2(communityId, c),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [_hex(community.color), _hex(c)],
                            ),
                            shape: BoxShape.circle,
                            border: community.color2 == c
                                ? Border.all(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    width: 3)
                                : null,
                          ),
                          child: community.color2 == c
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              // The old single "MODERATION" card held ten unrelated rows; it's
              // split into scannable groups so a person can find the one they
              // want without reading the whole wall.
              _label(context, 'MEMBERS & ROLES'),
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
                InfoTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: 'Who can invite people',
                  subtitle: invitePolicyLabel(community.invitePolicy),
                  onTap: () => _pickInvitePolicy(context, community),
                ),
                InfoTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: 'Roles',
                  subtitle: community.roles.isEmpty
                      ? 'Create named, coloured roles to badge members and '
                          'grant powers'
                      : '${community.roles.length} '
                          '${community.roles.length == 1 ? 'role' : 'roles'}',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          CommunityRolesScreen(communityId: communityId))),
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
              _label(context, 'WHAT MEMBERS CAN DO'),
              InfoSection(children: [
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
                  leading: const Icon(Icons.timer_outlined),
                  title: 'Slow mode',
                  subtitle: community.slowModeSeconds == 0
                      ? 'Off'
                      : 'One message every '
                          '${slowModeLabel(community.slowModeSeconds)}',
                  onTap: () => _pickSlowMode(context, community),
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
              ]),
              _label(context, 'MEMBERSHIP & DISCOVERY'),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.paid_outlined),
                  title: 'Paid membership',
                  subtitle: community.paid
                      ? 'Members pay '
                          '\$${(community.priceCents / 100).toStringAsFixed(2)}/mo to join'
                      : 'Off — anyone with an invite can join for free',
                  onTap: () => _editPaidMembership(context, community),
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
              ]),
              _label(context, 'DANGER ZONE'),
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

  /// Turns paid membership on or off and sets the monthly price, from the same
  /// fixed tiers a creator subscription uses. A price of nothing is "off".
  Future<void> _editPaidMembership(
      BuildContext context, Community community) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Paid membership',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'People pay a monthly pass to join. The server\'s traffic '
                    'is end-to-end encrypted either way — this gates the join, '
                    'not the reading.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(sheetContext))),
              ),
            ),
            ListTile(
              leading: Icon(
                  !community.paid
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: !community.paid
                      ? Theme.of(sheetContext).colorScheme.primary
                      : Colors.grey),
              title: const Text('Free to join'),
              onTap: () {
                CommunityStore.instance
                    .setPaidMembership(communityId, paid: false);
                Navigator.pop(sheetContext);
              },
            ),
            for (final cents in AppUser.subscriptionTiersCents)
              ListTile(
                leading: Icon(
                    community.paid && community.priceCents == cents
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: community.paid && community.priceCents == cents
                        ? Theme.of(sheetContext).colorScheme.primary
                        : Colors.grey),
                title: Text('\$${(cents / 100).toStringAsFixed(2)} / month'),
                onTap: () {
                  CommunityStore.instance.setPaidMembership(communityId,
                      paid: true,
                      priceCents: cents,
                      pitch: community.subPitch);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
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

  /// A searchable full-emoji picker for the server icon — any emoji, not just
  /// the quick picks. Sets the icon on tap.
  Future<void> _pickAnyEmoji(BuildContext context, String communityId) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => const _EmojiIconPicker(),
    );
    if (chosen != null && chosen.isNotEmpty) {
      CommunityStore.instance.setCommunityIcon(communityId, chosen);
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

/// A live preview of the server's look — a gradient banner with the icon and
/// name, updating as the icon/colour/gradient are edited below it. This is the
/// "improved UI": you see what you're building, not just swatches.
class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({required this.community});
  final Community community;

  @override
  Widget build(BuildContext context) {
    final base = _hex(community.color);
    final end = community.hasGradient
        ? _hex(community.color2)
        : Color.lerp(base, Colors.black, 0.28) ?? base;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 116,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base, end],
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 18),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
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
                      fontSize: 30,
                      fontWeight: community.icon.isNotEmpty
                          ? FontWeight.w400
                          : FontWeight.w800),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  community.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// A searchable emoji grid that pops the chosen emoji — for the server icon.
class _EmojiIconPicker extends StatefulWidget {
  const _EmojiIconPicker();

  @override
  State<_EmojiIconPicker> createState() => _EmojiIconPickerState();
}

class _EmojiIconPickerState extends State<_EmojiIconPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final List<String> emoji =
        searching ? EmojiData.search(_query) : EmojiData.all;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search emoji',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: emoji.isEmpty
                  ? Center(
                      child: Text('No emoji matches "${_query.trim()}".',
                          style: TextStyle(color: AppColors.subtle(context))))
                  : GridView.count(
                      crossAxisCount: 7,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final e in emoji)
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => Navigator.of(context).pop(e),
                            child: Center(
                                child: Text(e,
                                    style: const TextStyle(fontSize: 26))),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
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
