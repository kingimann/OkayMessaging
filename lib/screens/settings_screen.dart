import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../widgets/user_avatar.dart';

/// App settings, including the light/dark theme switch.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const me = MockData.me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const UserAvatar(user: me, radius: 32),
            title: Text(me.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
            subtitle: Text(me.about),
            trailing: const Icon(Icons.qr_code, color: Colors.grey),
            onTap: () {},
          ),
          const Divider(),
          _buildThemeTile(context),
          const _SettingsItem(
            icon: Icons.key,
            title: 'Account',
            subtitle: 'Security notifications, change number',
          ),
          const _SettingsItem(
            icon: Icons.lock,
            title: 'Privacy',
            subtitle: 'Block contacts, disappearing messages',
          ),
          const _SettingsItem(
            icon: Icons.chat,
            title: 'Chats',
            subtitle: 'Theme, wallpapers, chat history',
          ),
          const _SettingsItem(
            icon: Icons.notifications,
            title: 'Notifications',
            subtitle: 'Message, group & call tones',
          ),
          const _SettingsItem(
            icon: Icons.data_usage,
            title: 'Storage and data',
            subtitle: 'Network usage, auto-download',
          ),
          const _SettingsItem(
            icon: Icons.help_outline,
            title: 'Help',
            subtitle: 'Help center, contact us, privacy policy',
          ),
          const _SettingsItem(
            icon: Icons.group,
            title: 'Invite a friend',
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Okay Messaging • UI demo',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildThemeTile(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return SwitchListTile(
          secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
          title: const Text('Dark theme'),
          subtitle: Text(isDark ? 'On' : 'Off'),
          value: isDark,
          onChanged: (on) {
            AppState.themeMode.value =
                on ? ThemeMode.dark : ThemeMode.light;
          },
        );
      },
    );
  }
}

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.grey.shade600),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      onTap: () {},
    );
  }
}
