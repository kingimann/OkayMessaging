import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/app_lock.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'blocked_contacts_screen.dart';
import 'edit_profile_screen.dart';
import 'my_qr_screen.dart';
import 'wallpaper_screen.dart';

/// App settings as a standalone screen (pushed from deep links / older flows).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const SettingsView(),
      );
}

/// The settings content without its own Scaffold, so the same UI serves both
/// the standalone screen and the "You" bottom-navigation tab.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
        children: [
          const SizedBox(height: 6),
          _ProfileCard(),

          _sectionLabel(context, 'Appearance'),
          InfoSection(
            children: [
              const _ThemeModeTile(),
              const _TextSizeTile(),
              InfoTile(
                leading: const Icon(Icons.wallpaper_outlined),
                title: 'Chat wallpaper',
                subtitle: 'Background for your conversations',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WallpaperScreen()),
                ),
              ),
              _buildEnterToSendTile(),
            ],
          ),

          _sectionLabel(context, 'Privacy'),
          InfoSection(
            children: [
              _buildContactsOnlyTile(),
              _buildLastSeenTile(),
              _buildReadReceiptsTile(),
              _buildTypingTile(),
              InfoTile(
                leading: const Icon(Icons.block_outlined),
                title: 'Blocked contacts',
                subtitle: 'Manage who can\'t reach you',
                trailing: _BlockedCountBadge(),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const BlockedContactsScreen()),
                ),
              ),
              _buildAppLockTile(),
            ],
          ),

          _sectionLabel(context, 'Calls'),
          InfoSection(children: [_buildSilenceUnknownTile()]),

          _sectionLabel(context, 'Notifications'),
          InfoSection(children: [_buildNotificationsTile()]),

          _sectionLabel(context, 'Account'),
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.key_outlined),
                title: 'Account',
                subtitle: 'Phone number, username',
                onTap: () => _showAccount(context),
              ),
              InfoTile(
                leading: const Icon(Icons.data_usage_outlined),
                title: 'Storage and data',
                subtitle: 'Clear all chats from this device',
                onTap: () => _confirmClearChats(context),
              ),
            ],
          ),

          _sectionLabel(context, 'About & support'),
          InfoSection(
            children: [
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
              'Okay Messaging · v1.0.0',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
        ],
    );
  }

  static Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ),
        ),
      );

  Widget _buildContactsOnlyTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.messagesFromContactsOnly,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: Icon(on ? Icons.mark_email_read_outlined : Icons.mail_outline),
          title: const Text('Only my contacts can message me'),
          subtitle: Text(on
              ? 'Messages from unknown numbers are ignored'
              : 'Anyone can start a chat with you'),
          value: on,
          shape: _tileShape,
          onChanged: (v) => AppState.messagesFromContactsOnly.value = v,
        );
      },
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
          shape: _tileShape,
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
          shape: _tileShape,
          onChanged: (v) => AppState.sendReadReceipts.value = v,
        );
      },
    );
  }

  Widget _buildTypingTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.sendTypingIndicators,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: Icon(on ? Icons.more_horiz : Icons.do_not_disturb_on),
          title: const Text('Typing indicators'),
          subtitle: Text(on
              ? 'Show others when you\'re typing'
              : 'Others won\'t see when you\'re typing'),
          value: on,
          shape: _tileShape,
          onChanged: (v) => AppState.sendTypingIndicators.value = v,
        );
      },
    );
  }

  Widget _buildSilenceUnknownTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.silenceUnknownCallers,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: Icon(on ? Icons.phone_disabled : Icons.phone_in_talk),
          title: const Text('Silence unknown callers'),
          subtitle: Text(on
              ? 'Only people you\'ve chatted with can ring you'
              : 'Anyone can call you'),
          value: on,
          shape: _tileShape,
          onChanged: (v) => AppState.silenceUnknownCallers.value = v,
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
          shape: _tileShape,
          onChanged: (v) => AppState.notificationsEnabled.value = v,
        );
      },
    );
  }

  Widget _buildEnterToSendTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.enterToSend,
      builder: (context, on, _) {
        return SwitchListTile(
          secondary: const Icon(Icons.keyboard_return),
          title: const Text('Enter key sends'),
          subtitle: Text(on
              ? 'Return sends the message'
              : 'Return adds a new line'),
          value: on,
          shape: _tileShape,
          onChanged: (v) => AppState.enterToSend.value = v,
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
          'directly to the people you chat with, end-to-end encrypted.',
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
          shape: _tileShape,
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
}

const RoundedRectangleBorder _tileShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

/// A three-way theme selector (System / Light / Dark) as a segmented control.
class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconFor(mode),
                    color: Theme.of(context).iconTheme.color, size: 22),
                const SizedBox(width: 14),
                const Text('Theme',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto),
                      label: Text('System')),
                  ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text('Light')),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text('Dark')),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => AppState.themeMode.value = s.first,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ThemeMode m) => switch (m) {
        ThemeMode.system => Icons.brightness_auto,
        ThemeMode.light => Icons.light_mode,
        ThemeMode.dark => Icons.dark_mode,
      };
}

/// A slider that scales message text, with a live sample bubble.
class _TextSizeTile extends StatelessWidget {
  const _TextSizeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: AppState.messageTextScale,
      builder: (context, scale, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.format_size,
                      color: Theme.of(context).iconTheme.color, size: 22),
                  const SizedBox(width: 14),
                  const Text('Message text size',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Text('${(scale * 100).round()}%',
                      style: TextStyle(color: Colors.grey.shade500)),
                ],
              ),
              // Live preview bubble.
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(top: 6, bottom: 2),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2A2D34)
                        : const Color(0xFFE7ECEF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'Aa — the quick brown fox',
                    textScaler: TextScaler.linear(scale),
                    style: const TextStyle(fontSize: 16, height: 1.35),
                  ),
                ),
              ),
              Slider(
                value: scale,
                min: 0.85,
                max: 1.30,
                divisions: 9,
                label: '${(scale * 100).round()}%',
                onChanged: (v) => AppState.messageTextScale.value =
                    double.parse(v.toStringAsFixed(2)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A small pill showing how many contacts are blocked.
class _BlockedCountBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: AppState.blockedContacts,
      builder: (context, blocked, _) {
        if (blocked.isEmpty) {
          return const Icon(Icons.chevron_right, color: Colors.grey);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${blocked.length}',
                style: TextStyle(color: Colors.grey.shade500)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
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
            shape: _tileShape,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
