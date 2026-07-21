import 'package:flutter/material.dart';

import '../models/user.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

/// Contact detail screen reachable by tapping a conversation's header.
class ContactInfoScreen extends StatelessWidget {
  final AppUser user;

  const ContactInfoScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(user.name),
              background: Container(
                color: AppColors.tealGreen,
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: UserAvatar(user: user, radius: 60),
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const SizedBox(height: 12),
              const _ActionRow(),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'About',
                value: user.about,
              ),
              if (user.phone.isNotEmpty)
                _InfoCard(
                  title: 'Phone',
                  value: user.phone,
                  trailing: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.call, color: AppColors.tealGreenDark),
                      SizedBox(width: 20),
                      Icon(Icons.videocam, color: AppColors.tealGreenDark),
                    ],
                  ),
                ),
              const _SettingTile(
                icon: Icons.notifications,
                label: 'Notifications',
                value: 'On',
              ),
              const _SettingTile(
                icon: Icons.lock,
                label: 'Encryption',
                value: 'Messages are end-to-end encrypted',
              ),
              const _SettingTile(
                icon: Icons.wallpaper,
                label: 'Wallpaper & sound',
              ),
              const SizedBox(height: 12),
              _DangerTile(
                icon: Icons.block,
                label: 'Block ${user.name}',
              ),
              _DangerTile(
                icon: Icons.thumb_down,
                label: 'Report ${user.name}',
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
          _CircleAction(icon: Icons.message, label: 'Message'),
          _CircleAction(icon: Icons.call, label: 'Audio'),
          _CircleAction(icon: Icons.videocam, label: 'Video'),
          _CircleAction(icon: Icons.search, label: 'Search'),
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

class _InfoCard extends StatelessWidget {
  final String title;
  final String value;
  final Widget? trailing;

  const _InfoCard({required this.title, required this.value, this.trailing});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title:
          Text(title, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(value, style: const TextStyle(fontSize: 16)),
      ),
      trailing: trailing,
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;

  const _SettingTile({required this.icon, required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.grey),
      title: Text(label),
      subtitle: value == null ? null : Text(value!),
    );
  }
}

class _DangerTile extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DangerTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.red),
      title: Text(label, style: const TextStyle(color: Colors.red)),
      onTap: () {},
    );
  }
}
