import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

/// Details screen for a group conversation: header, members, and actions.
class GroupInfoScreen extends StatelessWidget {
  final AppUser group;

  const GroupInfoScreen({super.key, required this.group});

  List<AppUser> get _members => [MockData.me, ...MockData.contacts()];

  @override
  Widget build(BuildContext context) {
    final members = _members;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(group.name),
              background: Container(
                color: AppColors.tealGreen,
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: UserAvatar(user: group, radius: 54),
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Group · ${members.length} members',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(height: 8),
              const _ActionRow(),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '${members.length} members',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.grey),
                ),
              ),
              ...members.asMap().entries.map((e) {
                final index = e.key;
                final m = e.value;
                final isMe = m.id == MockData.me.id;
                return ListTile(
                  leading: UserAvatar(user: m, radius: 22),
                  title: Text(isMe ? 'You' : m.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(m.about,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: index == 1
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                AppColors.tealGreenDark.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('Group admin',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.tealGreenDark)),
                        )
                      : null,
                );
              }),
              const Divider(height: 8),
              const ListTile(
                leading: Icon(Icons.logout, color: Colors.red),
                title: Text('Exit group', style: TextStyle(color: Colors.red)),
              ),
              const ListTile(
                leading: Icon(Icons.thumb_down, color: Colors.red),
                title:
                    Text('Report group', style: TextStyle(color: Colors.red)),
              ),
              const SizedBox(height: 24),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _CircleAction(icon: Icons.call, label: 'Audio'),
          _CircleAction(icon: Icons.videocam, label: 'Video'),
          _CircleAction(icon: Icons.search, label: 'Search'),
          _CircleAction(icon: Icons.person_add, label: 'Add'),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CircleAction({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.tealGreenDark.withValues(alpha: 0.15),
          child: Icon(icon, color: AppColors.tealGreenDark),
        ),
        const SizedBox(height: 6),
        Text(label,
            style:
                const TextStyle(fontSize: 12, color: AppColors.tealGreenDark)),
      ],
    );
  }
}
