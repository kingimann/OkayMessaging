import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'edit_group_screen.dart';
import 'media_gallery_screen.dart';

/// A modern group detail screen: gradient header, tonal actions wired to the
/// chat, and a grouped members list with presence.
class GroupInfoScreen extends StatelessWidget {
  final AppUser group;

  /// The group's real members (empty falls back to sample members).
  final List<AppUser> members;

  /// The backing conversation id, when opened from a chat — lets actions like
  /// mute and media browse operate on the real chat.
  final String? chatId;

  const GroupInfoScreen({
    super.key,
    required this.group,
    this.members = const [],
    this.chatId,
  });

  List<AppUser> get _members => members.isNotEmpty
      ? members
      : [AppState.profile.value, ...MockData.contacts()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: ChatStore.instance,
        builder: (context, _) {
          final chat = chatId == null ? null : ChatStore.instance.chatById(chatId!);
          // Prefer the stored conversation so an edit (rename, new colour, a
          // member added) shows here the moment it's saved.
          final group = chat?.contact ?? this.group;
          final members = chat != null && chat.members.isNotEmpty
              ? chat.members
              : _members;
          final base = _avatarColor(group);
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 260,
                backgroundColor: base,
                foregroundColor: Colors.white,
                actions: [
                  PopupMenuButton<String>(
                    onSelected: (v) => _onMenu(context, v, chat),
                    itemBuilder: (context) => [
                      if (chat != null)
                        const PopupMenuItem(
                            value: 'edit', child: Text('Edit group')),
                      const PopupMenuItem(
                          value: 'share', child: Text('Share invite')),
                    ],
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: _Header(group: group, base: base, count: members.length),
                ),
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 16),
                  _GroupActions(
                    muted: chat?.isMuted ?? false,
                    onAudio: () => _startGroupCall(context, video: false),
                    onVideo: () => _startGroupCall(context, video: true),
                    onMute: chatId == null
                        ? null
                        : () => ChatStore.instance.toggleMute(chatId!),
                    onMedia: chatId == null
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => MediaGalleryScreen(
                                  chatId: chatId!, contactName: group.name),
                            )),
                  ),
                  if (group.about.trim().isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _AboutCard(text: group.about),
                  ],
                  const SizedBox(height: 8),
                  const _EncryptionNote(),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
                    child: Text('${members.length} members',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: Colors.grey)),
                  ),
                  // The group's creator leads the roster, so index 0 is the
                  // admin. "You" is decided by identity (on everyone else's
                  // device that first member is not them), and only the admin
                  // may remove members.
                  Builder(builder: (context) {
                    final me = AppState.profile.value;
                    bool isSelf(AppUser u) =>
                        u.id == me.id || u.id == MockData.me.id;
                    final iAmAdmin =
                        members.isNotEmpty && isSelf(members.first);
                    return InfoSection(
                      children: [
                        for (var i = 0; i < members.length; i++)
                          _MemberTile(
                            user: members[i],
                            isAdmin: i == 0,
                            isMe: isSelf(members[i]),
                            onRemove: (chat != null && iAmAdmin && i != 0)
                                ? () => _removeMember(context, chat, members[i])
                                : null,
                          ),
                      ],
                    );
                  }),
                  // Group management — the visible way to do what used to hide
                  // behind the app-bar ⋮, plus add/remove and disappearing.
                  if (chat != null)
                    InfoSection(
                      children: [
                        InfoTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: 'Group name & photo',
                          subtitle: 'Name, photo and description',
                          onTap: () => openGroupEditor(context, chat),
                        ),
                        InfoTile(
                          leading: const Icon(Icons.person_add_alt_1_outlined),
                          title: 'Add members',
                          onTap: () => openGroupEditor(context, chat),
                        ),
                        InfoTile(
                          leading: const Icon(Icons.timer_outlined),
                          title: 'Disappearing messages',
                          subtitle: _disappearingLabel(chat.disappearingSeconds),
                          onTap: () => _pickDisappearing(context, chat),
                        ),
                      ],
                    ),
                  if (chatId != null)
                    InfoSection(
                      children: [
                        SwitchListTile(
                          secondary: Icon(chat?.confirmBeforeSend ?? false
                              ? Icons.verified_user
                              : Icons.shield_outlined),
                          title: const Text('Confirm before sending'),
                          subtitle: Text(chat?.confirmBeforeSend ?? false
                              ? 'You\'ll confirm before each message sends'
                              : 'Ask me to confirm before sending to this group'),
                          value: chat?.confirmBeforeSend ?? false,
                          onChanged: (v) => ChatStore.instance
                              .setConfirmBeforeSend(chatId!, v),
                        ),
                      ],
                    ),
                  InfoSection(
                    children: [
                      InfoTile(
                        leading: const Icon(Icons.logout, color: Colors.red),
                        title: 'Exit group',
                        titleColor: Colors.red,
                        onTap: () => _confirmExit(context),
                      ),
                      InfoTile(
                        leading: const Icon(Icons.thumb_down_outlined,
                            color: Colors.red),
                        title: 'Report group',
                        titleColor: Colors.red,
                        onTap: () => _report(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }

  Color _avatarColor(AppUser group) {
    try {
      return Color(int.parse(
          group.avatarColor.replaceFirst('#', 'ff'),
          radix: 16));
    } catch (_) {
      // A fixed fallback, not a theme colour: this paints an avatar
      // circle with initials on it, whose contrast is against the circle
      // rather than against whatever is behind it.
      return AppColors.tealGreenDark;
    }
  }

  void _onMenu(BuildContext context, String value, Chat? chat) {
    if (value == 'edit' && chat != null) {
      openGroupEditor(context, chat);
      return;
    }
    final name = chat?.contact.name ?? group.name;
    Clipboard.setData(ClipboardData(
        text: 'Join "$name" on OkayMessenger — https://okaymessaging.com'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite copied')),
    );
  }

  Future<void> _confirmExit(BuildContext context) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.logout,
      title: 'Exit "${group.name}"?',
      message:
          'You\'ll stop receiving messages from this group on this device.',
      confirmLabel: 'Exit group',
      destructive: true,
    );
    if (ok && context.mounted) {
      if (chatId != null) ChatStore.instance.deleteChat(chatId!);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _report(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thanks — this group has been reported')),
    );
  }

  static String _disappearingLabel(int seconds) {
    if (seconds == Chat.afterViewing) return 'After viewing';
    if (seconds <= 0) return 'Off';
    if (seconds % 86400 == 0) {
      final d = seconds ~/ 86400;
      return d == 1 ? '1 day' : '$d days';
    }
    if (seconds % 3600 == 0) {
      final h = seconds ~/ 3600;
      return h == 1 ? '1 hour' : '$h hours';
    }
    return '$seconds seconds';
  }

  Future<void> _pickDisappearing(BuildContext context, Chat chat) async {
    const options = <(String, int)>[
      ('Off', 0),
      ('1 day', 86400),
      ('1 week', 604800),
      ('90 days', 7776000),
    ];
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Disappearing messages',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.$1),
                trailing: chat.disappearingSeconds == o.$2
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, o.$2),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) ChatStore.instance.setDisappearing(chat.id, chosen);
  }

  Future<void> _removeMember(
      BuildContext context, Chat chat, AppUser member) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.person_remove_outlined,
      title: 'Remove ${member.name}?',
      message: 'They will be removed from "${chat.contact.name}".',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final next = [for (final m in chat.members) if (m.id != member.id) m];
    ChatStore.instance.updateGroup(chat.id, members: next);
    // Tell the other members the roster changed, so every copy converges.
    if (RelayConfig.isEnabled) {
      final updated = ChatStore.instance.chatById(chat.id);
      if (updated != null) RelayService.instance.sendGroupUpdate(updated);
    }
  }

  /// Rings the group. The call overlay takes over the screen, so we pop the
  /// info page first to land back on the conversation when the call ends.
  void _startGroupCall(BuildContext context, {required bool video}) {
    Navigator.of(context).pop();
    final chat = chatId == null ? null : ChatStore.instance.chatById(chatId!);
    if (chat != null) {
      CallService.instance.startGroupCall(chat, video: video);
    }
  }
}

class _Header extends StatelessWidget {
  final AppUser group;
  final Color base;
  final int count;
  const _Header({required this.group, required this.base, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(base, Colors.black, 0.15) ?? base,
            Color.lerp(base, Colors.black, 0.45) ?? base,
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 30),
            UserAvatar(user: group, radius: 50, heroTag: 'chatHeaderAvatar'),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                group.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            Text('Group · $count members',
                style: const TextStyle(color: Colors.white70, fontSize: 14.5)),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  final String text;
  const _AboutCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return InfoSection(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('About',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.subtle(context))),
              const SizedBox(height: 6),
              Text(text, style: const TextStyle(fontSize: 15, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

class _EncryptionNote extends StatelessWidget {
  const _EncryptionNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: AppColors.subtle(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Messages are end-to-end encrypted and stay on members\' devices.',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final AppUser user;
  final bool isAdmin;
  final bool isMe;

  /// Set when the viewer is the group's admin and this is a removable member;
  /// tapping the tile removes them.
  final VoidCallback? onRemove;

  const _MemberTile({
    required this.user,
    required this.isAdmin,
    required this.isMe,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: UserAvatar(user: user, radius: 22),
      title: Text(isMe ? 'You' : user.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(user.about, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onRemove,
      trailing: isAdmin
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentOn(context).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('Group admin',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.accentOn(context))),
            )
          : (onRemove != null
              ? Icon(Icons.remove_circle_outline,
                  color: Colors.red.shade400, size: 20)
              : null),
    );
  }
}

class _GroupActions extends StatelessWidget {
  final bool muted;
  final VoidCallback? onAudio;
  final VoidCallback? onVideo;
  final VoidCallback? onMute;
  final VoidCallback? onMedia;

  const _GroupActions({
    required this.muted,
    this.onAudio,
    this.onVideo,
    this.onMute,
    this.onMedia,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
              child: _TonalAction(
                  icon: Icons.call, label: 'Audio', onTap: onAudio)),
          const SizedBox(width: 10),
          Expanded(
              child: _TonalAction(
                  icon: Icons.videocam, label: 'Video', onTap: onVideo)),
          const SizedBox(width: 10),
          Expanded(
            child: _TonalAction(
              icon: muted ? Icons.notifications_off : Icons.notifications_active,
              label: muted ? 'Unmute' : 'Mute',
              onTap: onMute,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TonalAction(
                icon: Icons.photo_library_outlined,
                label: 'Media',
                onTap: onMedia),
          ),
        ],
      ),
    );
  }
}

class _TonalAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _TonalAction({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark
          ? AppColors.accentOn(context).withValues(alpha: 0.22)
          : AppColors.accentOn(context).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap ??
            () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$label coming soon')),
                ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, color: AppColors.accentOn(context), size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: AppColors.accentOn(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
