import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_state.dart';
import 'crypto/key_exchange.dart';
import 'payments/iap_entitlement.dart';
import 'payments/payment_service.dart';
import 'relay/relay_config.dart';
import 'mesh/mesh_service.dart';
import 'state/feed_drafts.dart';
import 'relay/relay_service.dart';
import 'models/chat.dart';
import 'models/user.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/call_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/lock_screen.dart';
import 'state/account_email.dart';
import 'state/account_service.dart';
import 'state/app_lock.dart';
import 'state/backup_service.dart';
import 'state/call_log.dart';
import 'state/call_service.dart';
import 'state/callkit_bridge.dart';
import 'state/community_store.dart';
import 'state/contacts_sync.dart';
import 'state/crash_reporter.dart';
import 'state/chat_store.dart';
import 'state/cloud_sync.dart';
import 'state/feed_store.dart';
import 'state/favourites_store.dart';
import 'state/incoming_links.dart';
import 'state/bookmark_store.dart';
import 'state/feed_mute_store.dart';
import 'state/notes_store.dart';
import 'state/follow_store.dart';
import 'state/legal_consent.dart';
import 'state/live_location_broadcaster.dart';
import 'state/onboarding_store.dart';
import 'state/persistence.dart';
import 'state/recent_searches.dart';
import 'state/saved_places_store.dart';
import 'state/scheduler.dart';
import 'state/score_store.dart';
import 'state/session.dart';
import 'state/storage_store.dart';
import 'state/status_store.dart';
import 'state/streak_store.dart';
import 'state/channel_typing_store.dart';
import 'state/identity_verification.dart';
import 'state/platform_moderation.dart';
import 'state/voice_presence_store.dart';
import 'state/two_step.dart';
import 'theme/app_theme.dart';
import 'widgets/file_transfer_banner.dart';

/// Runs one startup step so that nothing can keep the app from launching:
/// a step that throws is skipped (the store keeps its defaults), and a step
/// that hangs — network init on a dead connection, a wedged plugin — is
/// abandoned after [limit]. A messenger that opens with one feature degraded
/// beats one that dies on the splash screen and gets watchdog-killed.
Future<void> _boot(String name, Future<void> Function() step,
    {Duration limit = const Duration(seconds: 6)}) async {
  try {
    await step().timeout(limit);
  } catch (e) {
    debugPrint('startup: $name failed, continuing — $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Uncaught errors are trapped (so they can't take the app down) and shipped
  // to the crash_reports table, where they can actually be read and fixed.
  CrashReporter.instance.install();
  // Everything lives on the device: the phone-number identity and all chats
  // are loaded from (and saved to) local storage. If a relay is configured,
  // messages are delivered device-to-device over an ephemeral broadcast
  // channel (nothing is stored on any server).
  await _boot('session', Session.instance.load);
  await _boot('persistence', Persistence.init);
  await _boot('keys', SecureKeyExchange.instance.load);
  await _boot('lock', AppLock.instance.load);
  await _boot('two-step', TwoStepVerification.instance.load);
  await _boot('legal', LegalConsent.instance.load);
  await _boot('email', AccountEmail.instance.load);
  await _boot('communities', CommunityStore.instance.load);
  await _boot('call log', CallLog.instance.load);
  await _boot('score', ScoreStore.instance.load);
  ScoreStore.instance.dailyCheckIn();
  await _boot('streaks', StreakStore.instance.load);
  await _boot('searches', RecentSearches.instance.load);
  await _boot('map searches', RecentSearches.maps.load);
  await _boot('backup', BackupService.instance.load);
  await _boot('payments', PaymentService.instance.load);
  await _boot('places', SavedPlacesStore.instance.load);
  await _boot('follows', FollowStore.instance.load);
  await _boot('bookmarks', BookmarkStore.instance.load);
  await _boot('feed mutes', FeedMuteStore.instance.load);
  await _boot('notes', NotesStore.instance.load);
  await _boot('feed', FeedStore.instance.load);
  await _boot('drafts', FeedDrafts.instance.load);
  await _boot('storage', StorageStore.instance.load);
  // Reads the saved setting and brings the radio up if it was on. Off by
  // default, so on nearly every launch this does nothing at all.
  await _boot('mesh', MeshService.instance.load);
  // StoreKit replays renewals that happened while the app was closed, so this
  // has to be listening before the purchase stream opens.
  IapEntitlement.instance.start();
  // The blue check is decided server-side, so ask rather than assume — a
  // check finished on another device (or after the app was closed) still
  // has to land here. And when the verdict lands, the profile follows it:
  // the badge peers see rides outgoing messages from the profile, so a
  // verdict that stays in the store is a badge nobody else ever sees.
  IdentityVerification.instance.addListener(() {
    final status = IdentityVerification.instance.status;
    if (status == IdentityStatus.none) return; // offline/unknown: no change
    final verified = status == IdentityStatus.verified;
    if (Session.instance.isSignedIn) {
      Session.instance.setVerified(verified);
    } else {
      AppState.setVerified(verified);
    }
  });
  // The stored verdict first, so a launch with no network still knows where
  // the account stands. Asking the server is further down, after the relay
  // boot: `Supabase.initialize` lives in `RelayService.init`, and both of
  // these read the session JWT through a client that does not exist until it
  // has run.
  await IdentityVerification.instance.load();
  ChannelTypingStore.instance.onTyping = (communityId, channelId) =>
      RelayService.instance.sendChannelTyping(communityId, channelId);
  VoicePresenceStore.instance.onPresence = (communityId, channelId,
          {required joined,
          required muted,
          required video,
          required screen}) =>
      RelayService.instance.sendVoicePresence(communityId, channelId,
          joined: joined, muted: muted, video: video, screen: screen);
  await _boot('cloud sync', CloudSync.instance.load);
  await _boot('status', StatusStore.instance.load);
  await _boot('favourites', FavouritesStore.instance.load);
  await _boot('onboarding', OnboardingStore.instance.load);
  LiveLocationBroadcaster.instance.start();
  // Demo streaks make the feature visible against the sample chats — but only
  // ever in a debug build. In release the chats are somebody's real
  // conversations, and a fabricated "12 day streak" on one of them is invented
  // activity about a real person. Real streaks build from real exchanges.
  if (!kReleaseMode && StreakStore.instance.isEmpty) {
    final oneToOne =
        ChatStore.instance.chats.where((c) => !c.contact.isGroup).toList();
    if (oneToOne.isNotEmpty) StreakStore.instance.seed(oneToOne[0].id, 12);
    if (oneToOne.length > 1) StreakStore.instance.seed(oneToOne[1].id, 5);
  }
  // Network-facing: most likely of all to stall on a bad connection.
  await _boot('relay', RelayService.instance.init,
      limit: const Duration(seconds: 10));
  // Both of these ask the server about this account, so they have to follow
  // the relay boot above — that is where `Supabase.initialize` runs, and a
  // client fetched before it throws. The throw is caught and turned into a
  // null client, so calling these too early failed *silently*: the role came
  // back member on every launch and the moderation console could never
  // appear no matter what the database said.
  //
  // Fire-and-forget: a device that can't reach the server shows no moderation
  // tools and enforces no sanction locally — the database is what actually
  // holds a lock-out.
  unawaited(IdentityVerification.instance.refresh());
  unawaited(PlatformModeration.instance.refresh());
  await _boot('scheduler', Scheduler.instance.init);
  ChatStore.instance.startSweeper();
  runApp(const OkayMessagingApp());
}

/// Shows the full-screen call UI on top of everything whenever there's an
/// active call, so an incoming call rings no matter what screen you're on.
class _CallOverlay extends StatelessWidget {
  final Widget child;
  const _CallOverlay({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallSession?>(
      valueListenable: CallService.instance.current,
      builder: (context, session, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: CallService.instance.minimized,
          builder: (context, minimized, __) => Stack(
            children: [
              child,
              if (session != null && !minimized)
                Positioned.fill(child: CallScreen(session: session)),
              if (session != null && minimized)
                ReturnToCallBanner(session: session),
            ],
          ),
        );
      },
    );
  }
}

/// Shows the PIN lock screen over everything while [AppLock] reports locked.
class _LockOverlay extends StatelessWidget {
  final Widget child;
  const _LockOverlay({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLock.instance.locked,
      builder: (context, locked, _) {
        return Stack(
          children: [
            child,
            // Wrapped in its own Navigator so the PIN field has an Overlay
            // ancestor (this sits above the app's own Navigator).
            if (locked)
              Positioned.fill(
                child: HeroControllerScope.none(
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const LockScreen(),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Drops the software keyboard whenever a route is left behind — leaving a
/// chat, closing a sheet, or backing out of any screen. Without this, iOS
/// sometimes keeps the keyboard up on the next screen even though nothing
/// there has focus.
class KeyboardDismissObserver extends NavigatorObserver {
  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _unfocus();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _unfocus();
}

class OkayMessagingApp extends StatefulWidget {
  const OkayMessagingApp({super.key});

  @override
  State<OkayMessagingApp> createState() => _OkayMessagingAppState();
}

/// Lets non-widget code (incoming default-messenger links) navigate.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Opens the 1:1 chat for [phone] — where a message tap lands when
/// OkayMessenger is the user's default messaging app. A number with no
/// existing chat is looked up in the directory (hashes only): people on the
/// app get a chat under their real identity; everyone else bounces to the
/// system's sms: handler so the text still happens — Apple's documented
/// fallback, which reaches Messages even when we're the default.
Future<void> openChatForPhone(String phone) async {
  final store = ChatStore.instance;
  var chat = store.chatWithContact(phone);
  AppUser? contact;
  if (chat == null && RelayConfig.isEnabled) {
    try {
      final matches = await AccountService.instance.lookupByPhoneHashes(
          ContactsSync.hashesFor([phone],
              countryCode: ContactsSync.defaultCountryCode()));
      if (matches.isEmpty) {
        if (await launchUrl(Uri.parse('sms:$phone'))) return;
      } else {
        contact = matches.first;
      }
    } catch (_) {
      // Offline: open the in-app chat rather than guessing.
    }
  }
  if (chat == null) {
    chat = Chat(
        id: 'chat_$phone',
        contact: contact ?? contactForPhone(phone),
        messages: const []);
    store.upsert(chat);
  } else if (chat.isArchived) {
    store.setArchived(chat.id, false);
  }
  final open = chat;
  rootNavigatorKey.currentState?.push(
    MaterialPageRoute(builder: (_) => ChatScreen(chat: open)),
  );
}

/// The contact a system link resolves to: the existing chat's contact when
/// there is one (so the call shows their name), else a bare number identity.
AppUser contactForPhone(String phone) {
  final existing = ChatStore.instance.chatWithContact(phone);
  if (existing != null) return existing.contact;
  return AppUser(
    id: phone,
    name: phone,
    avatarColor: '#64B5F6',
    about: 'Available',
    phone: phone,
  );
}

/// Starts a voice call to [phone] — where a call tap lands when OkayMessenger
/// is the user's default calling app. Signed out, the app can't place a VoIP
/// call, so the tap falls back to the system per Apple's guidance.
void openCallForPhone(String phone) {
  if (Session.instance.user.value == null) {
    IncomingLinks.systemCallFallback(phone);
    return;
  }
  CallService.instance.startOutgoing(contactForPhone(phone), video: false);
}

class _OkayMessagingAppState extends State<OkayMessagingApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    IncomingLinks.instance
        .init(onPhone: openChatForPhone, onCall: openCallForPhone);
    CallKitBridge.instance.init();
    // Structural server edits fan out to the other members live.
    CommunityStore.instance.onStructureChanged = (id) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.sendCommunityUpdate(id);
      }
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding with a field focused is how the keyboard gets stuck on
    // return: drop focus on the way out so the app comes back clean.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'OkayMessenger',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          navigatorObservers: [KeyboardDismissObserver()],
          home: const AuthGate(),
          builder: (context, child) => _LockOverlay(
            child: _CallOverlay(
              child: Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  const FileTransferBanner(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
