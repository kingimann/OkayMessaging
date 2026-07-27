import 'package:flutter/material.dart';

import 'app_state.dart';
import 'crypto/key_exchange.dart';
import 'payments/payment_service.dart';
import 'relay/relay_service.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/call_screen.dart';
import 'screens/lock_screen.dart';
import 'state/account_email.dart';
import 'state/app_lock.dart';
import 'state/backup_service.dart';
import 'state/call_log.dart';
import 'state/call_service.dart';
import 'state/community_store.dart';
import 'state/crash_reporter.dart';
import 'state/chat_store.dart';
import 'state/cloud_sync.dart';
import 'state/feed_store.dart';
import 'state/favourites_store.dart';
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
import 'state/status_store.dart';
import 'state/streak_store.dart';
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
  await _boot('feed', FeedStore.instance.load);
  await _boot('cloud sync', CloudSync.instance.load);
  await _boot('status', StatusStore.instance.load);
  await _boot('favourites', FavouritesStore.instance.load);
  await _boot('onboarding', OnboardingStore.instance.load);
  LiveLocationBroadcaster.instance.start();
  if (StreakStore.instance.isEmpty) {
    // Seed a couple of demo streaks so the feature is visible on first run;
    // real streaks then build (and lapse) from actual conversation activity.
    final oneToOne =
        ChatStore.instance.chats.where((c) => !c.contact.isGroup).toList();
    if (oneToOne.isNotEmpty) StreakStore.instance.seed(oneToOne[0].id, 12);
    if (oneToOne.length > 1) StreakStore.instance.seed(oneToOne[1].id, 5);
  }
  // Network-facing: most likely of all to stall on a bad connection.
  await _boot('relay', RelayService.instance.init,
      limit: const Duration(seconds: 10));
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

class _OkayMessagingAppState extends State<OkayMessagingApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
