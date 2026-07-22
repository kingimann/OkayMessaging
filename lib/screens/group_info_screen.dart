import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
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

  List<AppUser> get _members =>
      members.isNotEmpty ? members : [MockData.me, ...MockData.contacts()];

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final base = _avatarColor(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: ChatStore.instance,
        builder: (context, _) {
          final chat = chatId == null ? null : ChatStore.instance.chatById(chatId!);
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 260,
                backgroundColor: base,
                foregroundColor: Colors.white,
                actions: [
                  PopupMenuButton<String>(
                    onSelected: (v) => _onMenu(context, v),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit group')),
                      PopupMenuItem(value: 'share', child: Text('Share invite')),
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
                  InfoSection(
                    children: [
                      for (var i = 0; i < members.length; i++)
                        _MemberTile(
                          user: members[i],
                          isAdmin: i == 0,
                          isMe: i == 0 ||
                              members[i].id == AppState.profile.value.id ||
                              members[i].id == MockData.me.id,
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

  Color _avatarColor(BuildContext context) {
    try {
      return Color(int.parse(
          group.avatarColor.replaceFirst('#', 'ff'),
          radix: 16));
    } catch (_) {
      return AppColors.tealGreenDark;
    }
  }

  void _onMenu(BuildContext context, String value) {
    final msg = value == 'edit' ? 'Group editing coming soon' : 'Invite copied';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirmExit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Exit "${group.name}"?'),
        content: const Text(
            'You\'ll stop receiving messages from this group on this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Exit', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      if (chatId != null) ChatStore.instance.deleteChat(chatId!);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _report(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thanks — this group has been reported')),
    );
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
                      color: Colors.grey.shade500)),
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
          Icon(Icons.lock_outline, size: 16, color: Colors.grey.shade500),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Messages are end-to-end encrypted and stay on members\' devices.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
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

  const _MemberTile({
    required this.user,
    required this.isAdmin,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: UserAvatar(user: user, radius: 22),
      title: Text(isMe ? 'You' : user.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(user.about, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: isAdmin
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.tealGreenDark.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Group admin',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.tealGreenDark)),
            )
          : null,
    );
  }
}

class _GroupActions extends StatelessWidget {
  final bool muted;
  final VoidCallback? onMute;
  final VoidCallback? onMedia;

  const _GroupActions({required this.muted, this.onMute, this.onMedia});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const Expanded(child: _TonalAction(icon: Icons.call, label: 'Audio')),
          const SizedBox(width: 10),
          const Expanded(
              child: _TonalAction(icon: Icons.videocam, label: 'Video')),
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
          ? AppColors.tealGreenDark.withValues(alpha: 0.22)
          : AppColors.tealGreenDark.withValues(alpha: 0.12),
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
              Icon(icon, color: AppColors.tealGreenDark, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.tealGreenDark,
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
