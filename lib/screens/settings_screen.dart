import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../app_state.dart';
import '../crypto/identity_recovery.dart';
import '../models/platform_role.dart';
import '../relay/app_pages.dart';
import '../relay/relay_config.dart';
import '../state/ad_diagnostics.dart';
import '../state/account_email.dart';
import '../state/account_service.dart';
import '../state/account_verification.dart';
import '../state/account_wipe.dart';
import '../state/translate_service.dart';
import '../state/demo_seed.dart';
import '../state/call_diagnostics.dart';
import '../state/backup_service.dart';
import '../util/build_info.dart';
import '../state/chat_store.dart';
import '../state/platform_moderation.dart';
import '../state/notification_preview_diagnostics.dart';
import '../state/push_diagnostics.dart';
import '../state/relay_diagnostics.dart';
import '../state/identity_verification.dart';
import '../state/session.dart';
import 'auth/numberless_verify_screen.dart';
import '../state/ai_pass_store.dart';
import '../state/storage_store.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'account_email_screen.dart';
import 'admin_screen.dart';
import 'home_screen.dart' show HomeNavBar;
import 'chats_settings_screen.dart';
import 'edit_profile_screen.dart';
import 'legal_edit_screen.dart';
import 'legal_screen.dart';
import 'maps_settings_screen.dart';
import 'my_qr_screen.dart';
import 'privacy_settings_screen.dart';
import 'transparency_screen.dart';
import 'verification_screen.dart';
import 'money_screen.dart';
import 'public_feed_screen.dart' show BookmarksScreen;
import 'storage_backup_screen.dart';
import 'quick_replies_screen.dart';
import 'score_screen.dart';
import 'pricing_editor_screen.dart';
import 'self_test_screen.dart';
import 'store_screen.dart';
import 'store_products_screen.dart';
import 'settings_widgets.dart';
import '../state/score_store.dart';
import '../widgets/verified_badge.dart';

/// App settings as a standalone screen (pushed from deep links / older flows).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.fromSidebar = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
        ),
        body: const SettingsView(),
        // Only on the PUSHED screen. SettingsView is also the "You" tab's
        // body, and home already draws the bar under that one — putting it
        // here would have stacked two.
        // Floats over the content like it does on home, rather than sitting in
      // a slot the list stops above (the owner's call). Each list below pads
      // itself by HomeNavBar.clearance so nothing ends underneath it.
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
      );
}

/// The settings content without its own Scaffold, so the same UI serves both
/// the standalone screen and the "You" bottom-navigation tab. This is a hub:
/// grouped controls live in dedicated sub-screens reached from here.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return PullToRefresh(
      // The shared refresh resyncs the relay and pulls server-kept state
      // (follows, score, communities, email); settings adds the verification
      // status, whose blue-check row lives on this hub.
      onRefresh: () async {
        if (RelayConfig.isEnabled) {
          try {
            await IdentityVerification.instance.refresh();
          } catch (_) {}
        }
      },
      child: ListView(
        padding: EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
        children: [
        const SizedBox(height: 6),
        _ProfileCard(),
        // A name-only account is unverified — nudge it to verify a number,
        // which lifts the anti-spam limits, unlocks the wallet/posting, and
        // keeps the account (an in-place upgrade). Only shown when name-only.
        if (Session.instance.isNumberless)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: InfoSection(children: [
              InfoTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: 'Verify your number',
                subtitle: 'Unlock everything and keep this account',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const NumberlessVerifyScreen()),
                ),
              ),
            ]),
          ),
        // What this account has proven: the phone behind sign-in, the email
        // that can recover it, the ID behind the blue check. All three now
        // live behind ONE row that opens a single Verification screen — they
        // used to be three scattered chips/rows, which is exactly what a
        // person hunts for when a feature says "you need to be verified".
        settingsSectionLabel(context, 'Verification'),
        ListenableBuilder(
          listenable: Listenable.merge(
              [AccountEmail.instance, IdentityVerification.instance]),
          builder: (context, _) {
            final done = [
              AccountVerification.phoneVerified,
              AccountVerification.emailVerified,
              AccountVerification.idVerified,
            ].where((v) => v).length;
            final all = done == 3;
            return InfoSection(children: [
              InfoTile(
                leading: Icon(all ? Icons.verified : Icons.shield_outlined,
                    color: all ? const Color(0xFF12B76A) : null),
                title: 'Verification',
                subtitle: all
                    ? 'Phone, email and ID all verified'
                    : 'Phone, email and ID · $done of 3 verified',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const VerificationScreen()),
                ),
              ),
            ]);
          },
        ),

        // One row, not four. Payment security, Permissions and Muted accounts
        // moved INSIDE the privacy screen — they were always privacy
        // settings, and a section heading over four rows that all say
        // "privacy" is a heading doing no work. "What the server can see" is
        // the odd one out and went to About & support, where the other
        // honest-disclosure pages (Privacy Policy, Terms) already are.
        settingsSectionLabel(context, 'Privacy & security'),
        InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.lock_outline),
              title: 'Privacy & security',
              subtitle:
                  'Visibility, receipts, app lock, blocking, permissions',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const PrivacySettingsScreen()),
              ),
            ),
          ],
        ),

        settingsSectionLabel(context, 'Chats & content'),
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
            // Came off the newsfeed's app bar, then off the sidebar, and it
            // is here rather than nowhere: bookmarks you cannot open are
            // notes you never read. It shares this section now instead of
            // holding a "Newsfeed" heading up on its own — the muted list
            // that used to sit beside it is a privacy setting and moved
            // there.
            InfoTile(
              leading: const Icon(Icons.bookmark_border),
              title: 'Bookmarks',
              subtitle: 'Saved posts and folders, kept on this device',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BookmarksScreen()),
              ),
            ),
          ],
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
        settingsSectionLabel(context, 'Store'),
        InfoSection(
          children: [
            // One door instead of three scattered ones. The Store screen
            // itself still links on to the storage plans and the tip
            // amounts — this row is the entry, not a duplicate of them.
            ListenableBuilder(
              listenable: Listenable.merge(
                  [StorageStore.instance, AiPassStore.instance]),
              builder: (context, _) {
                final storage = StorageStore.instance;
                final pro = AiPassStore.instance.active;
                final bits = [
                  if (pro) 'Okay AI Pro',
                  if (storage.isPaid) '${storage.plan.name} storage',
                ];
                return InfoTile(
                  leading: const Icon(Icons.shopping_bag_outlined),
                  title: 'Store',
                  subtitle: bits.isEmpty
                      ? 'Subscriptions, cloud storage, and tipping the developer'
                      : '${bits.join(' · ')} active',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StoreScreen()),
                  ),
                );
              },
            ),
          ],
        ),

        settingsSectionLabel(context, 'Account'),
        InfoSection(
          children: [
            // Three rows that were one topic: the Wallet already carried two
            // doors into Get paid, which is what a screen does when it is
            // really a tab. The gate stays on the WALLET TAB rather than on
            // MoneyScreen — the Lightning rail needs no account of any kind,
            // and putting the only door inside the one room a name-only
            // account cannot enter would hide it from exactly the people it
            // is for. That reasoning used to live here; it lives in
            // MoneyScreen's own doc now, beside the code that honours it.
            InfoTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: 'Money',
              subtitle: 'Wallet, getting paid, and what you\'ve earned',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MoneyScreen()),
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
            // Chat backup, Cloud storage and Storage and data were three rows
            // answering the same question in different words. The badge stays
            // out here: a backup that is overdue is the reason somebody would
            // open this at all, and burying it one level down would mean
            // never seeing it.
            ListenableBuilder(
              listenable: BackupService.instance,
              builder: (context, _) => InfoTile(
                leading: const Icon(Icons.backup_outlined),
                title: 'Storage & backup',
                subtitle: 'Chat backup, cloud storage, clearing this device',
                trailing: BackupService.instance.isBackupDue()
                    ? const Icon(Icons.schedule, color: Color(0xFFF57F17))
                    : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) =>
                          StorageBackupScreen(onClearChats: _confirmClearChats)),
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
          ],
        ),

        // Below the settings anybody uses, above About: staff tools are
        // for a handful of accounts and should not push a real user's
        // Notifications and Account rows down the screen.
        _staffTools(context),

        settingsSectionLabel(context, 'About & support'),
        InfoSection(
          children: [
            // Beside the Privacy Policy and the Terms, which is what it is:
            // the same disclosure in the app's own words rather than a
            // setting anybody changes. It used to hold a row in the privacy
            // SECTION, which is where somebody goes to change something.
            InfoTile(
              leading: const Icon(Icons.visibility_outlined),
              title: 'What the server can see',
              subtitle: 'The honest page: what we hold, and what we can\'t read',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TransparencyScreen()),
              ),
            ),
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
              //
              // A numberless account with no recovery PIN is confirmed first
              // — `Session.signOut` erases one of those rather than merely
              // signing it out (there's nothing to sign back in with), so
              // this can't be a silent one-tap the way it safely is for
              // every other account.
              onTap: () async {
                final navigator = Navigator.of(context);
                final unrecoverable = Session.instance.isNumberless &&
                    !IdentityRecovery.ready.value;
                if (unrecoverable) {
                  final ok = await showAppConfirmDialog(
                    context,
                    icon: Icons.logout,
                    title: 'Sign out?',
                    message: 'This account has no phone number and no '
                        'recovery PIN, so there\'s no way back in. Signing '
                        'out deletes it and everything on this device with '
                        'it.',
                    confirmLabel: 'Sign out',
                    destructive: true,
                  );
                  if (!ok) return;
                }
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
      ),
    );
  }

  /// Deactivate = hidden, not gone: the directory row stops answering search
  /// (so the handle stays reserved), the push token is dropped, and the
  /// device signs out with every chat still on it. Signing back in with the
  /// same number clears the flag — reactivation IS the sign-in.
  ///
  /// **A numberless account with no recovery PIN ever stored can't actually
  /// come back this way** — `Session.signOut` (which this calls) erases an
  /// unrecoverable numberless account rather than merely signing it out, the
  /// same rule "Sign out" itself now follows. The dialog checks
  /// [IdentityRecovery.ready] and says so plainly instead of promising a
  /// return that can't happen — a name-only account WITH a backup still
  /// reactivates with its username + PIN exactly as before.
  Future<void> _deactivateAccount(BuildContext context) async {
    final navigator = Navigator.of(context);
    final numberless = Session.instance.isNumberless;
    final unrecoverable = numberless && !IdentityRecovery.ready.value;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deactivate temporarily?'),
        content: Text(unrecoverable
            // No session, no recovery backup — there is genuinely no way
            // back, so this isn't a deactivation at all. Say so.
            ? 'This account has no phone number and no recovery PIN, so '
                'there\'s no way to sign back in. Deactivating would delete '
                'it and everything on this device with it — use "Delete '
                'account" below instead if that\'s what you want.'
            : numberless
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
            child: Text(unrecoverable ? 'Got it' : 'Cancel'),
          ),
          // Offering a "Deactivate" button that actually erases would be the
          // exact false promise the copy above exists to avoid — so the
          // unrecoverable case gets no proceed action at all, only the way
          // out named in its own text.
          if (!unrecoverable)
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
    final phone = Session.instance.user.value?.phone ?? '';
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
                ? 'This erases THIS account from this device — its chats, '
                    'keys and settings — and cannot be undone. Any other '
                    'account signed in on this device is left alone. Without '
                    'a phone number there is no server session to prove the '
                    'account is yours, so the directory entry for your '
                    'handle expires on its own rather than being removed '
                    'now.'
                : 'This removes your account everywhere and cannot be '
                    'undone: your @handle, profile, push registration, '
                    'encryption recovery backup and public posts are '
                    'deleted from the server, and this account\'s data on '
                    'this device is erased. Any other account signed in on '
                    'this device is left alone. Records of payments that '
                    'really happened are kept, as receipts have to be.'),
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
    await AccountWipe.eraseCurrentAccount();
    // Forget ONLY this identity — the other accounts parked on this device
    // stay one-tap signable. The sign-out above re-remembered the deleted
    // account, and the erase cleared only its data; without this, the
    // remembered list would offer one-tap entry into an account that no
    // longer exists.
    await Session.instance.forgetAccount(phone);
    navigator.popUntil((route) => route.isFirst);
  }

  /// EVERY staff tool, in one section (the owner's call).
  ///
  /// They used to be scattered across four places on this screen — a
  /// "Moderation" section near the top, a "Diagnostics (admin)" section in
  /// the middle, two owner-only rows buried inside About between Terms and
  /// the version number, and a demo-fixtures section near the bottom. Nothing
  /// about that told you where to look for the next one.
  ///
  /// The gates are unchanged and still per row, because they are not the same
  /// rank: the console is moderator-and-up, the probes and fixtures are
  /// admin-and-up, and the two editors that change what every device shows
  /// are owner-only. The SECTION appears only when at least one row would,
  /// so an ordinary account sees nothing at all rather than an empty heading
  /// announcing that staff tools exist.
  Widget _staffTools(BuildContext context) {
    return ListenableBuilder(
      listenable: PlatformModeration.instance,
      builder: (context, _) {
        final store = PlatformModeration.instance;
        final canModerate = store.canModerate;
        final canAdminister = store.canAdminister;
        final isOwner = store.isOwner;
        // DemoSeed.available is already admin-gated AND compiled out unless
        // the build carried --dart-define=DEMO_SEED=true. Spelled out at both
        // sites rather than via a local: a test pins the literal
        // `if (DemoSeed.available)` here, so the gate cannot be softened into
        // something that merely looks equivalent.
        if (!canModerate &&
            !canAdminister &&
            !isOwner &&
            !DemoSeed.available) {
          return const SizedBox.shrink();
        }
        return Column(
          children: [
            settingsSectionLabel(context, 'Admin tools'),
            InfoSection(children: [
              if (canModerate)
                InfoTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: 'Moderation console',
                  subtitle:
                      'Reports, sanctions · ${platformRoleName(store.role)}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AdminScreen()),
                  ),
                ),
              // Owner only: these change what EVERY device shows, without a
              // build going out.
              if (isOwner) ...[
                InfoTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: 'Edit legal documents',
                  subtitle: 'Update Terms & Privacy for everyone',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LegalEditScreen()),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: 'Prices',
                  // Never overrides a real store price — see PricingStore.
                  subtitle: 'Storage, tiers and tips — for everyone',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const PricingEditorScreen()),
                  ),
                ),
              ],
              // The plumbing probes. Their verdicts name Supabase secrets,
              // APNs keys and TURN configuration — words that help whoever
              // runs the backend and read as alarming noise to anybody else.
              if (canAdminister) ...[
                InfoTile(
                  leading: const Icon(Icons.phone_in_talk_outlined),
                  title: 'Check call setup',
                  // Every way a call can fail to connect looks identical —
                  // endless "Connecting…" — and which one it is depends on
                  // the network of the minute.
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
                  leading: const Icon(Icons.storefront_outlined),
                  title: 'Check store products',
                  // App Store Connect has no public API and StoreKit only
                  // answers a signed-in device, so this is the only place
                  // "did that product actually land?" can be asked.
                  subtitle: 'Which in-app purchases the App Store offers here',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const StoreProductsScreen()),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.notifications_paused_outlined),
                  title: 'Check push setup',
                  // Every way of getting push wrong looks identical from
                  // here — nothing arrives.
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
                  leading: const Icon(Icons.mark_chat_read_outlined),
                  title: 'Check notification preview',
                  // Sends a REAL test push to this device, sealed the same
                  // way a message is — the only way to see whether the
                  // Notification Service Extension is actually decrypting
                  // one, since a locked screen showing "New message" looks
                  // identical whether the cause is an old build, a stale
                  // server deployment, or a keychain the extension can't
                  // reach.
                  subtitle: 'Sends a real test push — why alerts still say '
                      '"New message"',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SelfTestScreen(
                        title: 'Check notification preview',
                        run: NotificationPreviewSelfTest.run,
                      ),
                    ),
                  ),
                ),
                InfoTile(
                  leading: const Icon(Icons.ad_units_outlined),
                  title: 'Check ads',
                  // Every way an ad can fail to appear LOOKS THE SAME: the
                  // slot renders nothing at all, deliberately, whether the
                  // build carries no unit ids, the SDK never started, or
                  // Google had nothing to serve. This is the only thing that
                  // tells the three apart — and the first is by far the
                  // commonest, because an ad unit id is not the App ID.
                  subtitle: 'Why no ad is on screen',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SelfTestScreen(
                        title: 'Check ads',
                        run: AdsSelfTest.run,
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
              ],
              // Screenshot fixtures. See DemoSeed for why this doesn't break
              // the no-fake-data rule: it exists in no build a user or a
              // reviewer gets, and only for an admin even then.
              if (DemoSeed.available) ...[
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
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Demo content removed.')));
                  },
                ),
              ],
            ]),
          ],
        );
      },
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
          Icon(Icons.local_fire_department,
              size: 16, color: AppColors.accentOn(context)),
          const SizedBox(width: 3),
          Text('${ScoreStore.instance.points}',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentOn(context))),
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
