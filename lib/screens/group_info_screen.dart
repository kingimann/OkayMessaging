import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';

/// A modern group detail screen: clean header, tonal actions, and a grouped
/// members list.
class GroupInfoScreen extends StatelessWidget {
  final AppUser group;

  const GroupInfoScreen({super.key, required this.group});

  List<AppUser> get _members => [MockData.me, ...MockData.contacts()];

  @override
  Widget build(BuildContext context) {
    final members = _members;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit group')),
              PopupMenuItem(value: 'share', child: Text('Share')),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Center(
            child: UserAvatar(
              user: group,
              radius: 56,
              heroTag: 'chatHeaderAvatar',
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              group.name,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'Group · ${members.length} members',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
            ),
          ),
          const SizedBox(height: 22),
          const _GroupActions(),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 16, 8),
            child: Text(
              '${members.length} members',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Colors.grey),
            ),
          ),
          InfoSection(
            children: [
              for (var i = 0; i < members.length; i++)
                _MemberTile(user: members[i], isAdmin: i == 1),
            ],
          ),
          const InfoSection(
            children: [
              InfoTile(
                leading: Icon(Icons.logout, color: Colors.red),
                title: 'Exit group',
                titleColor: Colors.red,
              ),
              InfoTile(
                leading: Icon(Icons.thumb_down_outlined, color: Colors.red),
                title: 'Report group',
                titleColor: Colors.red,
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final AppUser user;
  final bool isAdmin;

  const _MemberTile({required this.user, required this.isAdmin});

  @override
  Widget build(BuildContext context) {
    final isMe = user.id == MockData.me.id;
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
  const _GroupActions();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(child: _TonalAction(icon: Icons.call, label: 'Audio')),
          SizedBox(width: 10),
          Expanded(child: _TonalAction(icon: Icons.videocam, label: 'Video')),
          SizedBox(width: 10),
          Expanded(child: _TonalAction(icon: Icons.person_add, label: 'Add')),
        ],
      ),
    );
  }
}

class _TonalAction extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TonalAction({required this.icon, required this.label});

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
        onTap: () {},
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
