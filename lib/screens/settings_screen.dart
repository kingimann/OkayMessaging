import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../relay/app_pages.dart';
import '../state/account_email.dart';
import '../state/backup_service.dart';
import '../util/build_info.dart';
import '../state/chat_store.dart';
import '../state/platform_moderation.dart';
import '../state/push_diagnostics.dart';
import '../state/session.dart';
import '../state/storage_store.dart';
import '../widgets/app_dialogs.dart';
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
import 'public_feed_screen.dart' show BookmarksScreen, MutedAccountsScreen;
import 'profile_screen.dart';
import 'quick_replies_screen.dart';
import 'score_screen.dart';
import 'self_test_screen.dart';
import 'settings_widgets.dart';
import 'wallet_screen.dart';
import '../state/score_store.dart';
import '../widgets/verified_badge.dart';

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
        // What this account has proven: the phone behind sign-in, the email
        // that can recover it, the ID behind the blue check. These lived on
        // the profile, where they were three settings rows in a profile's
        // clothes — what they say is about the account rather than about the
        // person, and each is a door into a settings screen anyway.
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: ProfileVerificationRow(),
        ),
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
            // Both of these came off the newsfeed's app bar, then off the
            // sidebar. They are here rather than nowhere: bookmarks you
            // cannot open are notes you never read, and a muted list nobody
            // can reach is a mute nobody can undo.
            InfoTile(
              leading: const Icon(Icons.bookmark_border),
              title: 'Bookmarks',
              subtitle: 'Newsfeed posts you saved, kept on this device',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BookmarksScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.volume_off_outlined),
              title: 'Muted accounts',
              subtitle: 'People whose posts you hid on the newsfeed',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MutedAccountsScreen()),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.bolt_outlined),
              title: 'Quick replies',
              subtitle: 'Saved answers, one tap away in any chat',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuickRepliesScreen()),
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
          _buildPrivateNotificationsTile(),
          _buildVoicemailTile(),
          InfoTile(
            leading: const Icon(Icons.notifications_paused_outlined),
            title: 'Check push setup',
            // Every way of getting push wrong looks identical from here —
            // nothing arrives — so the check is worth surfacing rather than
            // leaving somebody to guess which of six things it is.
            subtitle: 'Why alerts do or don\'t arrive when the app is closed',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SelfTestScreen(
                  title: 'Check push setup',
                  run: PushSelfTest.run,
                ),
              ),
            ),
          ),
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
              // Back to the root as well as out of the session. The auth gate
              // swaps its own child the moment the session clears — but this
              // screen was PUSHED on top of that gate, and so was whatever
              // opened it, so the login screen appeared underneath a stack of
              // routes nobody had closed. It looked like sign-out did nothing
              // until the app was killed and reopened.
              onTap: () async {
                final navigator = Navigator.of(context);
                await Session.instance.signOut();
                navigator.popUntil((route) => route.isFirst);
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            'OkayMessenger · v1.0.0',
            style: TextStyle(color: AppColors.subtle(context), fontSize: 12),
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

  Widget _buildPrivateNotificationsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.privateNotifications,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on
            ? Icons.notifications_paused
            : Icons.notification_important_outlined),
        title: const Text('Private notifications'),
        // What each half does, said plainly. The locked-screen half is not
        // mentioned because it is not this switch: previews hide on a locked
        // phone whatever this says.
        subtitle: Text(on
            ? 'Alerts say "New message" and nothing else, and are cleared '
                'from Notification Center when you open the app'
            : 'Alerts show who messaged you'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.privateNotifications.value = v,
      ),
    );
  }

  void _showAccount(BuildContext context) {
    final me = AppState.profile.value;
    Widget row(IconData icon, String label, String value) => ListTile(
          leading: Icon(icon, size: 22),
          title: Text(label,
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
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
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$label copied')));
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
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            if (me.pronouns.trim().isNotEmpty)
              Text(me.pronouns.trim(),
                  style:
                      TextStyle(fontSize: 13, color: AppColors.subtle(context))),
            const SizedBox(height: 8),
            row(Icons.phone_outlined, 'Phone number',
                me.phone.isEmpty ? 'Not set' : me.phone),
            row(Icons.alternate_email, 'Username',
                me.handle.isNotEmpty ? me.handle : 'Not set'),
            row(Icons.email_outlined, 'Email',
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
/// The tip jar, as a row of settings rather than a billboard.
///
/// This was a full-bleed violet gradient — the loudest thing in Settings, in
/// an app that is greyscale everywhere else, and the sort of block a reader
/// learns to scroll past because it looks like an advert. The heart keeps the
/// colour; nothing else needs it.
class _ProUpsell extends StatelessWidget {
  static const Color _accent = Color(0xFF7A5CFF);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const OkayProScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.favorite, size: 19, color: _accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Support the developer',
                          style: TextStyle(
                              fontSize: 15.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Leave a tip to help keep OkayMessenger going',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.subtle(context))),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20, color: AppColors.subtle(context)),
              ],
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
                final featured =
                    ScoreStore.badgeById(ScoreStore.instance.featuredBadge ?? '');
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
            // The handle on its own line and the bio under it. Joined with a
            // dot and wrapped over two lines, the pair broke mid-word — "@iman
            // · Building / OkayMessenger — pr…" — which reads as text that ran
            // out rather than as two facts about an account.
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (me.handle.isNotEmpty)
                  Text(me.handle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                if (me.about.isNotEmpty)
                  Text(me.about,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.subtle(context))),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.ios_share, color: Colors.grey),
                  tooltip: 'Share profile',
                  onPressed: () {
                    final who =
                        me.handle.isNotEmpty ? me.handle : me.name;
                    final link = AppPages.home;
                    Clipboard.setData(ClipboardData(
                        text: 'Chat with me ($who) on OkayMessenger'
                            '${link.isEmpty ? '' : ': $link'}'));
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
