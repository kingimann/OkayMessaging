import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../state/account_email.dart';
import '../state/backup_service.dart';
import '../util/build_info.dart';
import '../state/chat_store.dart';
import '../state/platform_moderation.dart';
import '../state/session.dart';
import '../state/storage_store.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_shell.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'account_email_screen.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';
import 'chats_settings_screen.dart';
import 'cloud_sync_screen.dart';
import 'edit_profile_screen.dart';
import 'legal_screen.dart';
import 'maps_settings_screen.dart';
import 'my_qr_screen.dart';
import 'okay_pro_screen.dart';
import 'permissions_screen.dart';
import 'privacy_settings_screen.dart';
import 'score_screen.dart';
import 'settings_widgets.dart';
import 'wallet_screen.dart';
import '../state/score_store.dart';
import '../widgets/verified_badge.dart';

/// App settings as a standalone screen (pushed from deep links / older flows).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: const SidebarButton(),
            title: const Text('Settings')),
        body: const SettingsView(),
      );
}

/// The settings content without its own Scaffold, so the same UI serves both
/// the standalone screen and the "You" bottom-navigation tab. This is a hub:
/// grouped controls live in dedicated sub-screens reached from here.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const SizedBox(height: 6),
        _ProfileCard(),
        _ProUpsell(),

        settingsSectionLabel(context, 'Preferences'),
        InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.lock_outline),
              title: 'Privacy & security',
              subtitle: 'Visibility, receipts, app lock, blocking',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const PrivacySettingsScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.shield_outlined),
              title: 'Permissions',
              subtitle: 'Camera, microphone, location, contacts, photos',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PermissionsScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: 'Chats & appearance',
              subtitle: 'Theme, text size, wallpaper',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChatsSettingsScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.local_fire_department_outlined),
              title: 'Okay Score & badges',
              subtitle: 'Your points, badges, and the blue check',
              trailing: _ScorePill(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ScoreScreen()),
              ),
            ),
          ],
        ),

        // Only for accounts the server says hold a platform role, and only
        // once it has said so — a moderation console must never appear on a
        // hunch about who is using the phone.
        ListenableBuilder(
          listenable: PlatformModeration.instance,
          builder: (context, _) {
            final store = PlatformModeration.instance;
            if (!store.canModerate) return const SizedBox.shrink();
            return Column(
              children: [
                settingsSectionLabel(context, 'Moderation'),
                InfoSection(children: [
                  InfoTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: 'Moderation console',
                    subtitle: 'Reports, sanctions · '
                        '${platformRoleName(store.role)}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AdminScreen()),
                    ),
                  ),
                ]),
              ],
            );
          },
        ),

        settingsSectionLabel(context, 'Notifications & calls'),
        InfoSection(children: [
          _buildNotificationsTile(),
          _buildVoicemailTile(),
        ]),

        settingsSectionLabel(context, 'Account'),
        InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: 'Wallet & payments',
              subtitle: 'Balance, cash out, receive money',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WalletScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.key_outlined),
              title: 'Account',
              subtitle: 'Phone number, username',
              onTap: () => _showAccount(context),
            ),
            ListenableBuilder(
              listenable: AccountEmail.instance,
              builder: (context, _) {
                final store = AccountEmail.instance;
                return InfoTile(
                  leading: const Icon(Icons.alternate_email),
                  title: 'Email address',
                  subtitle: store.isSet
                      ? (store.isVerified
                          ? store.email
                          : '${store.email} · not confirmed')
                      : 'Add one so you can recover your account',
                  trailing: store.isSet
                      ? null
                      : const Icon(Icons.error_outline,
                          color: Color(0xFFF57F17)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const AccountEmailScreen()),
                  ),
                );
              },
            ),
            ListenableBuilder(
              listenable: BackupService.instance,
              builder: (context, _) => InfoTile(
                leading: const Icon(Icons.backup_outlined),
                title: 'Chat backup',
                subtitle: 'Encrypted backup to iCloud, Dropbox, or Drive',
                trailing: BackupService.instance.isBackupDue()
                    ? const Icon(Icons.schedule, color: Color(0xFFF57F17))
                    : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BackupScreen()),
                ),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.map_outlined),
              title: 'Maps',
              subtitle: 'Style, units, voice guidance, data use',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MapsSettingsScreen()),
              ),
            ),
            ListenableBuilder(
              listenable: StorageStore.instance,
              builder: (context, _) {
                final storage = StorageStore.instance;
                return InfoTile(
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: 'Cloud storage',
                  subtitle: storage.isPaid
                      ? '${storage.plan.name} — encrypted chat backup, '
                          '${storage.quotaLabel}'
                      : 'Encrypted chat backup — Free ${storage.quotaLabel}, '
                          'upgrade for more',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
                  ),
                );
              },
            ),
            InfoTile(
              leading: const Icon(Icons.data_usage_outlined),
              title: 'Storage and data',
              subtitle: 'Clear all chats from this device',
              onTap: () => _confirmClearChats(context),
            ),
          ],
        ),

        settingsSectionLabel(context, 'About & support'),
        InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.help_outline),
              title: 'Help',
              subtitle: 'About OkayMessenger',
              onTap: () => _showHelp(context),
            ),
            InfoTile(
              leading: const Icon(Icons.group_outlined),
              title: 'Invite a friend',
              subtitle: 'Copy an invite message',
              onTap: () => _inviteFriend(context),
            ),
            InfoTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: 'Privacy Policy',
              subtitle: 'What we don\'t store',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LegalScreen.privacy()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.description_outlined),
              title: 'Terms of Service',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LegalScreen.terms()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.numbers),
              title: 'Version',
              subtitle: kBuildStamp,
              onTap: () {
                Clipboard.setData(const ClipboardData(text: kBuildStamp));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Version copied')),
                );
              },
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
            'OkayMessenger · v1.0.0',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildVoicemailTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.allowVoicemail,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on ? Icons.voicemail : Icons.voicemail_outlined),
        title: const Text('Voicemail'),
        subtitle: Text(on
            ? 'Callers can leave a voicemail if you miss a call'
            : 'Voicemails are turned off'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.allowVoicemail.value = v,
      ),
    );
  }

  Widget _buildNotificationsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.notificationsEnabled,
      builder: (context, on, _) => SwitchListTile(
        secondary:
            Icon(on ? Icons.notifications_active : Icons.notifications_off),
        title: const Text('Notifications'),
        subtitle: Text(on ? 'In-app alerts are on' : 'In-app alerts are off'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.notificationsEnabled.value = v,
      ),
    );
  }

  void _showAccount(BuildContext context) {
    final me = AppState.profile.value;
    Widget row(IconData icon, String label, String value) => ListTile(
          leading: Icon(icon, size: 22),
          title: Text(label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
          subtitle: Text(value,
              style:
                  const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
          trailing: value == 'Not set'
              ? null
              : IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$label copied')));
                  },
                ),
        );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(user: me, radius: 34),
            const SizedBox(height: 10),
            Text(me.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (me.pronouns.trim().isNotEmpty)
              Text(me.pronouns.trim(),
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            row(Icons.phone_outlined, 'Phone number',
                me.phone.isEmpty ? 'Not set' : me.phone),
            row(Icons.alternate_email, 'Username',
                me.handle.isNotEmpty ? me.handle : 'Not set'),
            row(
                Icons.email_outlined,
                'Email',
                AccountEmail.instance.isSet
                    ? AccountEmail.instance.email
                    : 'Not set'),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearChats(BuildContext context) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.delete_forever_outlined,
      title: 'Clear all chats?',
      message: 'This permanently deletes every conversation from this '
          'device. This cannot be undone.',
      confirmLabel: 'Clear all chats',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    ChatStore.instance.clearAll();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All chats cleared')),
    );
  }

  void _showHelp(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'OkayMessenger',
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
        'Message me on OkayMessenger! I\'m $who. Grab the app and say hi.';
    Clipboard.setData(ClipboardData(text: invite));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite copied to clipboard')),
    );
  }
}

/// A compact pill showing the current Okay Score next to the settings entry.
class _ScorePill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ScoreStore.instance,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department,
              size: 16, color: Color(0xFF7A5CFF)),
          const SizedBox(width: 3),
          Text('${ScoreStore.instance.points}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFF7A5CFF))),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }
}

/// A tappable banner inviting people to support the developer.
class _ProUpsell extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const OkayProScreen()),
          ),
          child: Ink(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFF7A5CFF), Color(0xFF5B3CE0)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.favorite, color: Colors.white),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Support the developer',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Leave a tip to help keep OkayMessenger going',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Colors.white70),
                ],
              ),
            ),
          ),
        ),
      ),
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
            title: AnimatedBuilder(
              animation: ScoreStore.instance,
              builder: (context, _) {
                final featured = ScoreStore.badgeById(
                    ScoreStore.instance.featuredBadge ?? '');
                return NameWithBadge(
                  name: me.name,
                  verified: me.verified,
                  badgeSize: 18,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                  trailing: featured == null
                      ? null
                      : Text(featured.emoji,
                          style: const TextStyle(fontSize: 16)),
                );
              },
            ),
            subtitle: Text(
              [
                if (me.handle.isNotEmpty) me.handle,
                if (me.about.isNotEmpty) me.about,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.ios_share, color: Colors.grey),
                  tooltip: 'Share profile',
                  onPressed: () {
                    final who = me.handle.isNotEmpty ? me.handle : me.name;
                    Clipboard.setData(ClipboardData(
                        text: 'Chat with me ($who) on OkayMessenger: '
                            'https://kingimann.github.io/OkayMessaging/'));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Profile link copied — share it '
                              'anywhere.')),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code, color: Colors.grey),
                  tooltip: 'My QR code',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MyQrScreen()),
                  ),
                ),
              ],
            ),
            shape: kSettingsTileShape,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
