import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/app_lock.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'edit_profile_screen.dart';
import 'my_qr_screen.dart';
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
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.key_outlined),
                title: 'Account',
                subtitle: 'Phone number, username',
                onTap: () => _showAccount(context),
              ),
              _buildLastSeenTile(),
              _buildReadReceiptsTile(),
              _buildNotificationsTile(),
              _buildAppLockTile(),
            ],
          ),
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.data_usage_outlined),
                title: 'Storage and data',
                subtitle: 'Clear all chats from this device',
                onTap: () => _confirmClearChats(context),
              ),
              InfoTile(
                leading: const Icon(Icons.help_outline),
                title: 'Help',
                subtitle: 'About Okay Messaging',
                onTap: () => _showHelp(context),
              ),
              InfoTile(
                leading: const Icon(Icons.group_outlined),
                title: 'Invite a friend',
                subtitle: 'Copy an invite message',
                onTap: () => _inviteFriend(context),
              ),
            ],
          ),
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: 'Sign out',
                titleColor: Colors.red,
                onTap: () => Session.instance.signOut(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Okay Messaging',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLastSeenTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.shareLastSeen,
      builder: (context, share, _) {
        return SwitchListTile(
          secondary: Icon(share ? Icons.visibility : Icons.visibility_off),
          title: const Text('Share online status'),
          subtitle: Text(share
              ? 'Contacts you chat with can see when you\'re online'
              : 'Your online status is hidden'),
          value: share,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          onChanged: (on) => AppState.shareLastSeen.value = on,
        );
      },
    );
  }

  Widget _buildReadReceiptsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.sendReadReceipts,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: Icon(on ? Icons.done_all : Icons.remove_done),
          title: const Text('Read receipts'),
          subtitle: Text(on
              ? 'Senders can see when you\'ve read their messages'
              : 'You won\'t send read receipts (you also won\'t see others\')'),
          value: on,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          onChanged: (v) => AppState.sendReadReceipts.value = v,
        );
      },
    );
  }

  Widget _buildNotificationsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.notificationsEnabled,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary:
              Icon(on ? Icons.notifications_active : Icons.notifications_off),
          title: const Text('Notifications'),
          subtitle: Text(on ? 'In-app alerts are on' : 'In-app alerts are off'),
          value: on,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          onChanged: (v) => AppState.notificationsEnabled.value = v,
        );
      },
    );
  }

  void _showAccount(BuildContext context) {
    final me = AppState.profile.value;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Phone number',
                style: TextStyle(fontWeight: FontWeight.w600)),
            Text(me.phone.isEmpty ? 'Not set' : me.phone),
            const SizedBox(height: 12),
            const Text('Username',
                style: TextStyle(fontWeight: FontWeight.w600)),
            Text(me.handle.isNotEmpty ? me.handle : 'Not set'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearChats(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all chats?'),
        content: const Text(
            'This permanently deletes every conversation from this device. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    ChatStore.instance.clearAll();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All chats cleared')),
    );
  }

  void _showHelp(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Okay Messaging',
      applicationVersion: '1.0.0',
      children: const [
        SizedBox(height: 12),
        Text(
          'A private, local-first messenger. Your messages live on your '
          'device — nothing is stored on a server. Messages are relayed '
          'directly to the people you chat with.',
        ),
      ],
    );
  }

  void _inviteFriend(BuildContext context) {
    final me = AppState.profile.value;
    final who = me.handle.isNotEmpty ? me.handle : me.name;
    final invite =
        'Message me on Okay Messaging! I\'m $who. Grab the app and say hi.';
    Clipboard.setData(ClipboardData(text: invite));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite copied to clipboard')),
    );
  }

  Widget _buildAppLockTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLock.instance.enabled,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: Icon(on ? Icons.lock : Icons.lock_open),
          title: const Text('App lock'),
          subtitle: Text(on
              ? 'A PIN is required to open the app'
              : 'Require a PIN to open the app'),
          value: on,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          onChanged: (v) {
            if (v) {
              _setPin(context);
            } else {
              AppLock.instance.disable();
            }
          },
        );
      },
    );
  }

  Future<void> _setPin(BuildContext context) async {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          Widget field(TextEditingController c, String label) => TextField(
                controller: c,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: label, counterText: ''),
              );
          return AlertDialog(
            title: const Text('Set a PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                field(pin, 'PIN (4-6 digits)'),
                field(confirm, 'Confirm PIN'),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!,
                        style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (pin.text.length < 4) {
                    setState(() => error = 'Use at least 4 digits');
                  } else if (pin.text != confirm.text) {
                    setState(() => error = 'PINs don\'t match');
                  } else {
                    Navigator.of(dialogContext).pop(true);
                  }
                },
                child: const Text('Set'),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      await AppLock.instance.setPin(pin.text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App lock enabled')),
        );
      }
    }
    pin.dispose();
    confirm.dispose();
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
            subtitle: Text(me.handle.isNotEmpty ? me.handle : me.about),
            trailing: IconButton(
              icon: const Icon(Icons.qr_code, color: Colors.grey),
              tooltip: 'My QR code',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyQrScreen()),
              ),
            ),
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
