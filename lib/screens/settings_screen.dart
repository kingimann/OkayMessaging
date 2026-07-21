import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config/backend_config.dart';
import '../services/supabase_service.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'edit_profile_screen.dart';
import 'wallpaper_screen.dart';

/// App settings, redesigned with grouped rounded cards (modern style).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 6),
          _ProfileCard(),
          InfoSection(
            children: [
              _buildThemeTile(),
              InfoTile(
                leading: const Icon(Icons.chat_outlined),
                title: 'Chats',
                subtitle: 'Wallpaper, theme, chat history',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WallpaperScreen()),
                ),
              ),
            ],
          ),
          const InfoSection(
            children: [
              InfoTile(
                leading: Icon(Icons.key_outlined),
                title: 'Account',
                subtitle: 'Security notifications, change number',
              ),
              InfoTile(
                leading: Icon(Icons.lock_outline),
                title: 'Privacy',
                subtitle: 'Block contacts, disappearing messages',
              ),
              InfoTile(
                leading: Icon(Icons.notifications_outlined),
                title: 'Notifications',
                subtitle: 'Message, group & call tones',
              ),
              InfoTile(
                leading: Icon(Icons.data_usage_outlined),
                title: 'Storage and data',
                subtitle: 'Network usage, auto-download',
              ),
            ],
          ),
          const InfoSection(
            children: [
              InfoTile(
                leading: Icon(Icons.help_outline),
                title: 'Help',
                subtitle: 'Help center, contact us, privacy policy',
              ),
              InfoTile(
                leading: Icon(Icons.group_outlined),
                title: 'Invite a friend',
              ),
            ],
          ),
          if (BackendConfig.isConfigured)
            InfoSection(
              children: [
                InfoTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: 'Sign out',
                  titleColor: Colors.red,
                  onTap: () => SupabaseService.instance.signOut(),
                ),
              ],
            ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              BackendConfig.isConfigured
                  ? 'Okay Messaging'
                  : 'Okay Messaging • demo mode',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildThemeTile() {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return SwitchListTile(
          secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
          title: const Text('Dark theme'),
          subtitle: Text(isDark ? 'On' : 'Off'),
          value: isDark,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          onChanged: (on) {
            AppState.themeMode.value = on ? ThemeMode.dark : ThemeMode.light;
          },
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.profile,
      builder: (context, me, _) => InfoSection(
        children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: UserAvatar(user: me, radius: 30),
            title: Text(me.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            subtitle: Text(me.about),
            trailing: const Icon(Icons.qr_code, color: Colors.grey),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
