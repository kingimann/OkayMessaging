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
import 'state/chat_store.dart';
import 'state/cloud_sync.dart';
import 'state/feed_store.dart';
import 'state/favourites_store.dart';
import 'state/follow_store.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Everything lives on the device: the phone-number identity and all chats
  // are loaded from (and saved to) local storage. If a relay is configured,
  // messages are delivered device-to-device over an ephemeral broadcast
  // channel (nothing is stored on any server).
  await Session.instance.load();
  await Persistence.init();
  await SecureKeyExchange.instance.load();
  await AppLock.instance.load();
  await TwoStepVerification.instance.load();
  await AccountEmail.instance.load();
  await CommunityStore.instance.load();
  await CallLog.instance.load();
  await ScoreStore.instance.load();
  ScoreStore.instance.dailyCheckIn();
  await StreakStore.instance.load();
  await RecentSearches.instance.load();
  await RecentSearches.maps.load();
  await BackupService.instance.load();
  await PaymentService.instance.load();
  await SavedPlacesStore.instance.load();
  await FollowStore.instance.load();
  await FeedStore.instance.load();
  await CloudSync.instance.load();
  await StatusStore.instance.load();
  await FavouritesStore.instance.load();
  await OnboardingStore.instance.load();
  LiveLocationBroadcaster.instance.start();
  if (StreakStore.instance.isEmpty) {
    // Seed a couple of demo streaks so the feature is visible on first run;
    // real streaks then build (and lapse) from actual conversation activity.
    final oneToOne =
        ChatStore.instance.chats.where((c) => !c.contact.isGroup).toList();
    if (oneToOne.isNotEmpty) StreakStore.instance.seed(oneToOne[0].id, 12);
    if (oneToOne.length > 1) StreakStore.instance.seed(oneToOne[1].id, 5);
  }
  await RelayService.instance.init();
  await Scheduler.instance.init();
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
