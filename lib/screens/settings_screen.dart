import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../app_state.dart';
import '../models/platform_role.dart';
import '../relay/app_pages.dart';
import '../relay/relay_config.dart';
import '../state/account_email.dart';
import '../state/account_service.dart';
import '../state/account_wipe.dart';
import '../state/translate_service.dart';
import '../state/demo_seed.dart';
import '../state/call_diagnostics.dart';
import '../state/backup_service.dart';
import '../util/build_info.dart';
import '../state/chat_store.dart';
import '../state/platform_moderation.dart';
import '../state/push_diagnostics.dart';
import '../state/relay_diagnostics.dart';
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
import 'earnings_screen.dart';
import 'edit_profile_screen.dart';
import 'legal_edit_screen.dart';
import 'legal_screen.dart';
import 'maps_settings_screen.dart';
import 'my_qr_screen.dart';
import 'okay_pro_screen.dart';
import 'permissions_screen.dart';
import 'privacy_settings_screen.dart';
import 'transparency_screen.dart';
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

        settingsSectionLabel(context, 'Privacy & security'),
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
              leading: const Icon(Icons.visibility_outlined),
              title: 'What the server can see',
              subtitle:
                  'The honest page: what we hold, and what we can\'t read',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const TransparencyScreen()),
              ),
            ),
          ],
        ),

        settingsSectionLabel(context, 'Chats'),
        InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: 'Chats & appearance',
              subtitle: 'Theme, text size, wallpaper',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChatsSettingsScreen()),
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
            ListenableBuilder(
              listenable: TranslateService.instance,
              builder: (context, _) => InfoTile(
                leading: const Icon(Icons.translate),
                title: 'Translation language',
                subtitle:
                    'Translate messages into ${TranslateService.instance.targetName()} · '
                    'on this device, never uploaded',
                onTap: () => _pickTranslationLanguage(context),
              ),
            ),
          ],
        ),

        // Both of these came off the newsfeed's app bar, then off the
        // sidebar. They are here rather than nowhere: bookmarks you
        // cannot open are notes you never read, and a muted list nobody
        // can reach is a mute nobody can undo.
        settingsSectionLabel(context, 'Newsfeed'),
        InfoSection(
          children: [
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
        ]),

        // Named what people look for. The tip card used to sit alone with no
        // heading and the storage plan hid inside Preferences as "Cloud
        // storage" — both real, neither findable by the words anyone would
        // search the screen for.
        settingsSectionLabel(context, 'Tips & subscriptions'),
        InfoSection(
          children: [
            InfoTile(
              leading:
                  const Icon(Icons.favorite_outline, color: Color(0xFF7A5CFF)),
              title: 'Support the developer',
              subtitle: 'Leave a tip — coffee to generous',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OkayProScreen()),
              ),
            ),
            ListenableBuilder(
              listenable: StorageStore.instance,
              builder: (context, _) {
                final storage = StorageStore.instance;
                return InfoTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: 'Cloud storage subscription',
                  subtitle: storage.isPaid
                      ? '${storage.plan.name} active — ${storage.quotaLabel}, '
                          'renew or change'
                      : 'More space for encrypted backups, billed through '
                          'the App Store',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
                  ),
                );
              },
            ),
          ],
        ),

        // The three plumbing probes are operator tools, not user settings:
        // their verdicts name Supabase secrets, APNs keys and TURN
        // configuration — words that help whoever runs the backend and
        // read as alarming noise to anybody else. Same server-driven gate
        // as the moderation console, one rank stricter (admin, not
        // moderator), and never on a hunch about who holds the phone.
        ListenableBuilder(
          listenable: PlatformModeration.instance,
          builder: (context, _) {
            if (!PlatformModeration.instance.canAdminister) {
              return const SizedBox.shrink();
            }
            return Column(children: [
              settingsSectionLabel(context, 'Diagnostics (admin)'),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.phone_in_talk_outlined),
                  title: 'Check call setup',
                  // Every way a call can fail to connect looks identical —
                  // endless "Connecting…" — and which one it is depends on
                  // the network of the minute. The probe gathers real ICE
                  // candidates and names the missing path instead of
                  // leaving it to guesses.
                  subtitle: 'Why calls do or don\'t connect on this network',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SelfTestScreen(
                        title: 'Check call setup',
                        run: CallSelfTest.run,
                      ),
                    ),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.notifications_paused_outlined),
                  title: 'Check push setup',
                  // Every way of getting push wrong looks identical from
                  // here — nothing arrives — so the check is worth having
                  // rather than guessing which of six things it is.
                  subtitle:
                      'Why alerts do or don\'t arrive when the app is closed',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SelfTestScreen(
                        title: 'Check push setup',
                        run: PushSelfTest.run,
                      ),
                    ),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.bolt_outlined),
                  title: 'Check live delivery',
                  // The counterpart for the app being OPEN: a dead live
                  // socket looks exactly like "slow messages", because the
                  // offline mailbox still delivers on refresh.
                  subtitle: 'Why messages do or don\'t arrive instantly',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SelfTestScreen(
                        title: 'Check live delivery',
                        run: RelaySelfTest.run,
                      ),
                    ),
                  ),
                ),
              ]),
            ]);
          },
        ),

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
              leading: const Icon(Icons.trending_up),
              title: 'Earnings',
              subtitle: 'How much you\'ve earned, and from where',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EarningsScreen()),
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
            InfoTile(
              leading: const Icon(Icons.local_fire_department_outlined),
              title: 'Okay Score & badges',
              subtitle: 'Your points, badges, and the blue check',
              trailing: _ScorePill(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ScoreScreen()),
              ),
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
            // Owner only: edit the Terms and Privacy Policy for everyone,
            // without shipping a build. Appears when owner status loads.
            ListenableBuilder(
              listenable: PlatformModeration.instance,
              builder: (context, _) => PlatformModeration.instance.isOwner
                  ? InfoTile(
                      leading: const Icon(Icons.gavel_outlined),
                      title: 'Edit legal documents',
                      subtitle: 'Update Terms & Privacy for everyone',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const LegalEditScreen()),
                      ),
                    )
                  : const SizedBox.shrink(),
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

        // Screenshot fixtures — the section is compiled out entirely unless
        // the build carried --dart-define=DEMO_SEED=true (the owner's own
        // screenshot build). See DemoSeed for why this doesn't break the
        // no-fake-data rule: it exists in no build a user or reviewer gets.
        if (DemoSeed.enabled) ...[
          settingsSectionLabel(context, 'Screenshot fixtures (demo build)'),
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: 'Populate demo content',
                subtitle: 'Chats, calls, and a server — on this device only',
                onTap: () {
                  DemoSeed.populate();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Demo content added. It exists only on '
                          'this device.')));
                },
              ),
              InfoTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: 'Remove demo content',
                onTap: () {
                  DemoSeed.clear();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Demo content removed.')));
                },
              ),
            ],
          ),
        ],

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
            InfoTile(
              leading: const Icon(Icons.pause_circle_outline),
              title: 'Deactivate temporarily',
              subtitle: 'Step away without losing anything',
              onTap: () => _deactivateAccount(context),
            ),
            InfoTile(
              leading:
                  const Icon(Icons.delete_forever_outlined, color: Colors.red),
              title: 'Delete account',
              titleColor: Colors.red,
              subtitle: 'Permanent — removes your account everywhere',
              onTap: () => _deleteAccount(context),
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

  /// Deactivate = hidden, not gone: the directory row stops answering search
  /// (so the handle stays reserved), the push token is dropped, and the
  /// device signs out with every chat still on it. Signing back in with the
  /// same number clears the flag — reactivation IS the sign-in.
  Future<void> _deactivateAccount(BuildContext context) async {
    final navigator = Navigator.of(context);
    final numberless = Session.instance.isNumberless;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deactivate temporarily?'),
        content: Text(numberless
            // No session, no server row to manage — say what actually
            // happens rather than promising the phone-account behaviour.
            ? 'You\'ll be signed out of this device and stop receiving '
                'anything until you sign back in with your username and '
                'recovery PIN. Your chats stay on this phone. Without a '
                'phone number there is no server session, so your @handle '
                'stays visible in search while you\'re away.'
            : 'Your @handle disappears from people search and this phone '
                'stops receiving notifications. Your chats stay on this '
                'phone, and your handle stays yours. Signing back in with '
                'the same number reactivates everything.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Server half first, while the session still exists; the sign-out below
    // drops the push token and the session itself.
    await AccountService.instance.setHidden(true);
    await Session.instance.signOut();
    navigator.popUntil((route) => route.isFirst);
  }

  /// Delete = gone: the delete-account Edge Function removes every server
  /// row the phone owns and the auth user itself, then the device is wiped
  /// to nothing — including the keep-list an account SWITCH would preserve.
  /// The server half runs first and a failure stops everything: a local
  /// wipe over live server rows would only look like deletion.
  Future<void> _deleteAccount(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final numberless = Session.instance.isNumberless;
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(numberless
                ? 'This erases everything on this device — chats, keys, '
                    'settings — and cannot be undone. Without a phone '
                    'number there is no server session to prove the '
                    'account is yours, so the directory entry for your '
                    'handle expires on its own rather than being removed '
                    'now.'
                : 'This removes your account everywhere and cannot be '
                    'undone: your @handle, profile, push registration, '
                    'encryption recovery backup and public posts are '
                    'deleted from the server, and everything on this '
                    'device is erased. Records of payments that really '
                    'happened are kept, as receipts have to be.'),
            const SizedBox(height: 14),
            TextField(
              controller: confirm,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Type DELETE to confirm',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext)
                .pop(confirm.text.trim().toUpperCase() == 'DELETE'),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!numberless && RelayConfig.isEnabled) {
      try {
        final res = await supa.Supabase.instance.client.functions
            .invoke('delete-account', body: const {}).timeout(
                const Duration(seconds: 30));
        if (res.status >= 400) {
          throw StateError('the server answered ${res.status}');
        }
      } catch (e) {
        // Nothing was deleted anywhere — say so and stop, rather than
        // wiping the phone over an account that still exists.
        messenger.showSnackBar(SnackBar(
            content: Text('The server could not delete your account, so '
                'nothing was deleted. Check the connection and try again. '
                '($e)')));
        return;
      }
    }
    await Session.instance.signOut();
    await AccountWipe.eraseEverything();
    await Session.instance.clearLastAccount();
    // The sign-out above re-remembered the account and the erase only
    // cleared the DISK copy — without this, the in-memory list would
    // re-persist the deleted identity on the next sign-in and offer
    // one-tap entry into an account that no longer exists.
    await Session.instance.clearKnownAccounts();
    navigator.popUntil((route) => route.isFirst);
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

  void _pickTranslationLanguage(BuildContext context) {
    final svc = TranslateService.instance;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // Bound the height so a long list scrolls INSIDE the sheet instead of
      // stretching it to the top of the screen and cramming the title under
      // the status bar. The header stays put; only the list scrolls.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Translate messages into',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in TranslateService.languages.entries)
                    ListTile(
                      title: Text(entry.value),
                      trailing: svc.target == entry.key
                          ? Icon(Icons.check,
                              size: 20,
                              color: Theme.of(sheetContext).colorScheme.primary)
                          : null,
                      onTap: () {
                        svc.setTarget(entry.key);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
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
