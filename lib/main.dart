import 'dart:async';
import 'state/chat_folders.dart';
import 'state/pending_server_invites.dart';
import 'state/qr_style_store.dart';
import 'state/inbox_tiers.dart';
import 'state/message_sound_store.dart';
import 'state/saved_forms.dart';
import 'state/vehicle_inspections.dart';
import 'state/password_history.dart';
import 'state/quick_replies.dart';
import 'state/translate_service.dart';
import 'state/ai_assistant.dart';
import 'state/ai_consent.dart';
import 'state/ai_memory.dart';
import 'state/ai_persona.dart';
import 'state/ai_pass_store.dart';
import 'state/sidebar_prefs.dart';
import 'state/chat_lock.dart';

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_state.dart';
import 'crypto/double_ratchet.dart';
import 'crypto/identity_recovery.dart';
import 'crypto/key_exchange.dart';
import 'crypto/sender_key.dart';
import 'payments/iap_entitlement.dart';
import 'payments/payment_service.dart';
import 'payments/store_prices.dart';
import 'relay/relay_config.dart';
import 'mesh/mesh_service.dart';
import 'state/feed_drafts.dart';
import 'state/account_wipe.dart';
import 'state/account_verification.dart';
import 'state/numberless_grace.dart';
import 'state/nwc_store.dart';
import 'state/push_service.dart';
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
import 'state/call_media.dart';
import 'state/call_service.dart';
import 'state/callkit_bridge.dart';
import 'state/community_store.dart';
import 'state/contacts_sync.dart';
import 'state/parental_controls.dart';
import 'state/payment_security_store.dart';
import 'state/room_media.dart';
import 'state/crash_reporter.dart';
import 'state/chat_store.dart';
import 'state/abuse_guard.dart';
import 'state/backup_prefs.dart';
import 'state/cloud_sync.dart';
import 'state/feed_store.dart';
import 'state/favourites_store.dart';
import 'state/incoming_links.dart';
import 'state/bookmark_store.dart';
import 'state/feed_mute_store.dart';
import 'state/feed_prefs.dart';
import 'state/contacts_store.dart';
import 'state/notes_store.dart';
import 'state/follow_store.dart';
import 'state/promotion_store.dart';
import 'state/public_feed_alerts.dart';
import 'state/public_feed_store.dart';
import 'state/legal_consent.dart';
import 'state/legal_store.dart';
import 'state/pricing_store.dart';
import 'state/live_location_broadcaster.dart';
import 'state/live_share_broadcaster.dart';
import 'state/live_share_store.dart';
import 'state/onboarding_store.dart';
import 'state/persistence.dart';
import 'state/recent_searches.dart';
import 'state/saved_places_store.dart';
import 'state/scheduler.dart';
import 'state/score_store.dart';
import 'state/session.dart';
import 'state/storage_store.dart';
import 'state/creator_sub_store.dart';
import 'state/community_sub_store.dart';
import 'state/status_store.dart';
import 'state/sticker_store.dart';
import 'state/streak_store.dart';
import 'state/channel_typing_store.dart';
import 'state/identity_verification.dart';
import 'state/platform_moderation.dart';
import 'state/voice_presence_store.dart';
import 'widgets/voice_channel_banner.dart';
import 'state/two_step.dart';
import 'theme/app_theme.dart';
import 'widgets/file_transfer_banner.dart';
import 'widgets/poke_back_banner.dart';

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


/// Brings this device's view of the follow graph back in line with the
/// server's — BOTH halves of it, which is what the launch-only version of
/// this got wrong twice.
///
/// The count came first (two devices on one account showed different
/// "Following" numbers), then the re-seed on resume (a follow made elsewhere
/// stayed invisible until a cold start). What neither did was seed the
/// LIST, so `FollowStore.isFollowing` — which is what every Follow button
/// reads — still knew nothing about a follow this install had not made
/// itself. The profile said "3 following", the list showed the three, and
/// all three buttons said Follow.
///
/// Fire-and-forget and silent: an unreachable server leaves both halves as
/// they were.
///
/// Retries first, folds second, and the order is load-bearing: an edge the
/// server was never told about would otherwise be overwritten by the graph
/// that has not heard of it — an unfollow that comes back.
Future<void> syncFollowGraph() async {
  final me = AppState.profile.value.username.trim();
  if (me.isEmpty) return;
  try {
    await FollowStore.instance.retryPending();
  } catch (_) {}
  try {
    final c = await PublicFeedStore.instance.followCounts(me);
    if (c != null) FollowStore.instance.noteServerFollowing(c.$2);
  } catch (_) {}
  try {
    final list = await PublicFeedStore.instance.followingOf(me);
    if (list != null) {
      FollowStore.instance.noteServerFollowingList([for (final p in list) p.$1]);
    }
  } catch (_) {}
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
  await _boot('ratchet', DoubleRatchet.instance.load);
  await _boot('sender keys', SenderKeyStore.instance.load);
  await _boot('lock', AppLock.instance.load);
  await _boot('chat locks', ChatLock.instance.load);
  await _boot('quick replies', QuickReplies.instance.load);
  await _boot('password history', PasswordHistory.instance.load);
  await _boot('chat folders', ChatFolders.instance.load);
  await _boot('pending server invites', PendingServerInvites.instance.load);
  await _boot('inbox tiers', InboxTiers.instance.load);
  await _boot('message sounds', MessageSoundStore.instance.load);
  await _boot('saved forms', SavedForms.instance.load);
  await _boot('vehicle inspections', VehicleInspections.instance.load);
  // The daily reminder is a short QUEUE of one-shot notifications, so every
  // launch re-arms it — see VehicleInspections.reminderDays for why, and for
  // the honest limit that the chain runs out if the app is never opened.
  unawaited(VehicleInspections.instance.scheduleReminders());
  await _boot('qr style', QrStyleStore.instance.load);
  await _boot('translation', TranslateService.instance.load);
  await _boot('assistant', AiAssistant.instance.load);
  await _boot('ai memory', AiMemory.instance.load);
  await _boot('ai consent', AiConsent.instance.load);
  await _boot('ai persona', AiPersona.instance.load);
  await _boot('ai pass', AiPassStore.instance.load);
  await _boot('sidebar', SidebarPrefs.instance.load);
  await _boot('two-step', TwoStepVerification.instance.load);
  await _boot('payment security', PaymentSecurityStore.instance.load);
  // Legal documents (cached copy) load BEFORE consent, so the acceptance gate
  // compares against the effective version, owner-published or built-in.
  await _boot('legal docs', LegalStore.instance.load);
  await _boot('prices', PricingStore.instance.load);
  await _boot('legal', LegalConsent.instance.load);
  await _boot('email', AccountEmail.instance.load);
  await _boot('communities', CommunityStore.instance.load);
  await _boot('call log', CallLog.instance.load);
  await _boot('score', ScoreStore.instance.load);
  ScoreStore.instance.dailyCheckIn();
  await _boot('streaks', StreakStore.instance.load);
  await _boot('searches', RecentSearches.instance.load);
  await _boot('backup', BackupService.instance.load);
  await _boot('payments', PaymentService.instance.load);
  await _boot('places', SavedPlacesStore.instance.load);
  await _boot('follows', FollowStore.instance.load);
  await _boot('bookmarks', BookmarkStore.instance.load);
  await _boot('feed mutes', FeedMuteStore.instance.load);
  await _boot('feed prefs', FeedPrefs.instance.load);
  await _boot('notes', NotesStore.instance.load);
  await _boot('contacts', ContactsStore.instance.load);
  await _boot('feed', FeedStore.instance.load);
  await _boot('drafts', FeedDrafts.instance.load);
  await _boot('storage', StorageStore.instance.load);
  await _boot('creator subs', CreatorSubStore.instance.load);
  await _boot('server subs', CommunitySubStore.instance.load);
  // Reads the saved setting and brings the radio up if it was on. Off by
  // default, so on nearly every launch this does nothing at all.
  await _boot('mesh', MeshService.instance.load);
  // StoreKit replays renewals that happened while the app was closed, so this
  // has to be listening before the purchase stream opens.
  IapEntitlement.instance.start();
  // Fetch the store's real, localized prices (USD/CAD) so purchase screens can
  // show what will actually be charged, in the buyer's currency, instead of a
  // computed dollar figure. Off the critical path — not awaited, and labels
  // fall back to a plain USD figure until it lands (and always, off-store).
  StorePrices.instance.load();
  // Restore a connected Lightning wallet, so a spark can be paid without
  // leaving the app on the first try rather than after a visit to Get paid.
  NwcStore.instance.load();
  // A name-only account lives 14 days. Load its clock, and if it has run
  // out, delete and sign out — explained on screen, never silently.
  await enforceNumberlessGrace();
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
  // Whether the recovery code is squared away — the flag the first-message
  // gate reads, so it has to be known before any chat can open.
  await _boot('recovery', IdentityRecovery.load);
  await _boot('parental', ParentalControls.instance.load);
  await _boot('stickers', StickerStore.instance.load);
  ChannelTypingStore.instance.onTyping = (communityId, channelId) =>
      RelayService.instance.sendChannelTyping(communityId, channelId);
  VoicePresenceStore.instance.onPresence = (communityId, channelId,
      {required joined,
      required muted,
      required video,
      required screen}) {
    RelayService.instance.sendVoicePresence(communityId, channelId,
        joined: joined, muted: muted, video: video, screen: screen);
    // The authoritative ground-truth table (docs/community_voice.sql) —
    // rides the exact same heartbeat/join/leave/state-change events the
    // live broadcast above already fires on.
    RelayService.instance.publishVoicePresence(communityId, channelId,
        joined: joined, muted: muted, video: video, screen: screen);
  };
  // The voice-channel media mesh: signaling out over the sealed pairwise
  // path, signaling in routed to the mesh, and connections following
  // presence from here on.
  RoomMedia.instance.send = (toDigits,
          {required roomId, required kind, sdp, ice}) =>
      RelayService.instance.sendRoomSignal(toDigits,
          roomId: roomId, kind: kind, sdp: sdp, ice: ice);
  RelayService.instance.onRoomSignal =
      (fromDigits, roomId, kind, {sdp, ice}) => RoomMedia.instance
          .onSignal(fromDigits, roomId, kind, sdp: sdp, ice: ice);
  RoomMedia.instance.bind();
  // A network switch mid-call redials the transport instead of hanging in
  // "Reconnecting…" forever.
  CallMedia.instance.onNeedsIceRestart = () =>
      unawaited(CallService.instance.restartIce());
  // And a link that STAYS dead ends the call: the far side's hang-up can
  // miss the live socket, and its queued copy is worth fetching now
  // rather than at the next app-open.
  CallMedia.instance.connectionState.addListener(() => CallService.instance
      .onMediaState(CallMedia.instance.connectionState.value));
  await _boot('abuse guard', AbuseGuard.instance.load);
  await _boot('backup prefs', BackupPrefs.instance.load);
  await _boot('cloud sync', CloudSync.instance.load);
  await _boot('status', StatusStore.instance.load);
  await _boot('favourites', FavouritesStore.instance.load);
  await _boot('onboarding', OnboardingStore.instance.load);
  await _boot('live shares', LiveShareStore.instance.load);
  LiveLocationBroadcaster.instance.start();
  LiveShareBroadcaster.instance.start();
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
  // Same reason, same place, and both used to sit ~85 lines ABOVE this —
  // so on every cold launch they asked a client that did not exist yet and
  // silently did nothing. The follow graph was then seeded only on the first
  // RESUME, which is why a fresh install showed "Follow" on every person it
  // already followed and a Following count of zero; the alert scan simply
  // never ran at launch at all.
  //
  // Seed the follow store from the SERVER — the count AND the list, so the
  // sidebar, the profile and every device agree, and so a Follow button knows
  // about a follow this install did not make itself.
  // An account that fell out of the directory is invisible rather than
  // broken — every handle lookup returns nobody and nothing says why. Put it
  // back before anything that reads the graph asks.
  unawaited(AccountService.instance.ensureDirectoryRow());
  unawaited(syncFollowGraph());
  // Nothing on the public timeline is delivered to a device, so a like, a
  // reply or a new follower has to be looked for. Silent when there is
  // nothing new — the first scan only takes a baseline.
  unawaited(PublicFeedAlerts.instance.scan());
  // Which posts are paid placements. Same reason and same place as the two
  // above: it reads a world-readable view through the Supabase client, so it
  // cannot run before the relay boot.
  unawaited(PromotionStore.instance.refresh());
  // Pull the latest legal documents; a bump re-prompts consent on next check.
  unawaited(LegalStore.instance.refresh());
  unawaited(PricingStore.instance.refresh());
  // Apple renews, cancels, and REFUNDS whether or not the app is open, and
  // the storage quota gate is client-side — so a refund the server already
  // honoured only takes effect here once the app asks. Asking every cold
  // start (not only when the Cloud storage screen opens) closes the window
  // between "Apple refunded" and "the app stops honouring it". Fire-and-
  // forget, and only acted on when the server actually answers.
  unawaited(IapEntitlement.instance.refresh().then((e) {
    if (e != null) {
      StorageStore.instance.applyServerEntitlement(
          active: e.active, gb: e.gb, expiresAt: e.expiresAt);
    }
  }));
  await _boot('scheduler', Scheduler.instance.init);
  ChatStore.instance.startSweeper();
  CommunityStore.instance.startSweeper();
  // Warm the Stripe SDK now, not lazily on the first charge: a Payment Sheet
  // opened before the publishable key has been applied can fail to render,
  // which looked like the wallet top-up failing the instant it was tapped.
  unawaited(PaymentService.instance.warmUpStripe());
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
Future<void> openChatForPhone(String phone,
    {bool systemFallback = true}) async {
  final store = ChatStore.instance;
  var chat = store.chatWithContact(phone);
  AppUser? contact;
  if (chat == null && RelayConfig.isEnabled) {
    try {
      final matches = await AccountService.instance.lookupByPhoneHashes(
          ContactsSync.hashesFor([phone],
              countryCode: ContactsSync.defaultCountryCode()));
      if (matches.isEmpty) {
        // Only for default-messaging-app taps about people NOT on the app.
        // A tap on OUR OWN notification sets [systemFallback] false: the
        // sender is on the app by definition (they just messaged through
        // it), and a directory miss — numberless sender, empty directory,
        // no session to read it with — was bouncing our own alerts to
        // iMessage.
        if (systemFallback && await launchUrl(Uri.parse('sms:$phone'))) {
          return;
        }
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
    about: '',
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
  /// True once the app really went to the background (not just an inactive
  /// blip from a permission dialog or the app switcher opening), so the
  /// resume handler only rebuilds the relay when the socket plausibly died.
  bool _wasSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    IncomingLinks.instance.init(
      onPhone: openChatForPhone,
      onCall: openCallForPhone,
      onPushChat: (phone) => openChatForPhone(phone, systemFallback: false),
      // A scanned QR: the payload carries who they are, so the chat is
      // created with their name and handle instead of a bare number.
      onAdd: (t) {
        final store = ChatStore.instance;
        var chat = store.chatWithContact(t.phone);
        if (chat == null) {
          chat = Chat(
            id: 'chat_${t.phone}',
            contact: AppUser(
              id: t.phone,
              name: t.name.isNotEmpty
                  ? t.name
                  : (t.username.isNotEmpty ? '@${t.username}' : t.phone),
              avatarColor: Session.colorForPhone(t.phone),
              phone: t.phone,
              username: t.username,
            ),
            messages: const [],
          );
          store.upsert(chat);
        } else if (chat.isArchived) {
          store.setArchived(chat.id, false);
        }
        final open = chat;
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => ChatScreen(chat: open)),
        );
      },
    );
    CallKitBridge.instance.init();
    // Structural server edits fan out to the other members live.
    CommunityStore.instance.onStructureChanged = (id) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.sendCommunityUpdate(id);
        // A public server's directory row carries its snapshot and member
        // count; keep it fresh when the structure changes.
        final c = CommunityStore.instance.byId(id);
        if (c != null && c.listed) {
          RelayService.instance.publishServerDirectory(id);
        }
        // The authoritative structure tables (docs/community_structure.sql):
        // publishCommunityStructure itself no-ops on any device but the
        // owner's, so this is safe to call from every member's device — only
        // the actual owner's call does anything. Covers member removals and
        // bans too: republishing the whole roster from the now-current local
        // Community naturally drops a removed member's row (rebuild-deletes-
        // by-omission) and adds a fresh ban row, with no separate handling
        // needed in onMemberRemoved below, which stays purely about key
        // rotation — a member leaving/getting kicked always fires this
        // callback alongside onMemberRemoved (removeMember/banMember both
        // call onStructureChanged first).
        RelayService.instance.publishCommunityStructure(id);
      }
    };
    // Flipping the public/private toggle publishes or removes the Discover row.
    CommunityStore.instance.onListedChanged = (id) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.publishServerDirectory(id);
      }
    };
    // A member leaving rotates the server's sender-key epoch, so the copy of
    // the chain they walked off with reads nothing sent afterward.
    CommunityStore.instance.onMemberRemoved = (id) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.rotateServerKey(id);
      }
    };
    // Forum activity fans out to every member — and their offline mailboxes —
    // like the feed. It used to stay on the device it happened on, which
    // made a delete look like it worked while everybody else kept the post.
    CommunityStore.instance.onForumEvent = (id, event, body) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.sendForumEvent(id, event, body);
      }
    };
    // A contact's CHANGED identity key gets said in the conversation —
    // Signal's warning. The crypto layer handles the change safely either
    // way; this is the human being told it happened.
    SecureKeyExchange.instance.onPeerKeyChanged =
        (digits) => ChatStore.instance.noteIdentityChange(digits);
    // A member arriving gets the feed history from the owner's device —
    // broadcast has no history, so without this a listing posted before
    // they joined would never exist for them.
    CommunityStore.instance.onMemberJoined = (id, member) {
      if (RelayConfig.isEnabled) {
        RelayService.instance.backfillFeedTo(id, member.id);
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
      _wasSuspended = true;
      FocusManager.instance.primaryFocus?.unfocus();
      // A chat opened with its password an hour ago and left there is a chat
      // the password stopped protecting. Shutting them on the way out is what
      // makes the lock mean anything after the first unlock.
      ChatLock.instance.closeAll();
    }
    if (state == AppLifecycleState.resumed && _wasSuspended) {
      _wasSuspended = false;
      // The background froze the Realtime socket along with the rest of the
      // process; without this, messages only arrive again after a manual
      // refresh (the subscription looks alive and isn't).
      if (RelayConfig.isEnabled) RelayService.instance.wake();
      // Mark this account seen again, so the moderation roster knows it's
      // online now (docs/admin_users.sql). Best-effort; a numberless account
      // has no session and this is a silent no-op.
      if (RelayConfig.isEnabled) AccountService.instance.touchLastSeen();
      // Suspension paused the voice heartbeat too, and everyone else may
      // have aged this device out of its channel — reappear immediately
      // rather than one heartbeat period later.
      VoicePresenceStore.instance.announceNow();
      // Whatever the app-icon badge was counting has now been seen.
      PushService.instance.clearBadge();
      // Periodic backup backstop: if auto-backup is on and its interval has
      // elapsed, upload now. Silent and off the critical path.
      CloudSync.instance.maybeAutoBackup();
      // Re-seed the own following count from the server graph. It used to be
      // fetched once at launch, so a follow made on another device (or an
      // unfollow that failed to land) left this phone showing a stale number
      // until the next cold start.
      unawaited(syncFollowGraph());
      // Look for likes and replies on your own public posts. This is the
      // resume half, and it is the half that matters: the app is resumed far
      // more often than it is launched, and the whole point of the scan is
      // to notice what happened while it was closed.
      PublicFeedAlerts.instance.scan();
      PromotionStore.instance.refresh();
      // Ask the store its prices again — exactly the staleness above, for
      // money. They were fetched once at launch, and on iOS the app is
      // RESUMED far more often than it is relaunched, so a price raised in
      // App Store Connect could stay wrong on this phone for as long as the
      // process lived. Cheap, and the store's answer is what a purchase
      // will really charge.
      StorePrices.instance.load();
      // The clock can run out while the app sits in the background — on iOS
      // that is the common case, since the process outlives many days.
      enforceNumberlessGrace();
      // Same reasoning for the daily check-in: it used to run at COLD LAUNCH
      // only, and on iOS the process outlives many days, so a phone that was
      // never force-quit crossed midnight without checking in — no points,
      // and a streak that lapsed for want of a relaunch. Idempotent per day.
      ScoreStore.instance.dailyCheckIn();
      // Ask again who this account IS. Reported as "the app keeps thinking
      // I'm not an admin, I have to sign out and sign in" — and signing out
      // was the cure because AuthGate was the only OTHER thing that ever
      // called this. A cold launch can reach the JWT-gated status function
      // before the stored token has been refreshed; that read failed
      // silently, the role stayed at the safe default, and on iOS the
      // process then outlived days of resumes with nothing to try again.
      // Also how a role granted in SQL reaches a phone that is already open.
      unawaited(PlatformModeration.instance.refresh());
    }
    // Private notifications: the alert did its job once the app is open, and
    // a stack of "New message" rows left in Notification Center afterwards
    // is a log of when people talked to you.
    if (state == AppLifecycleState.resumed &&
        AppState.privateNotifications.value) {
      PushService.instance.clearDelivered();
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
              // App-wide: a tap on any empty area dismisses the keyboard.
              // Translucent so it only claims taps that no field or button
              // took — tapping a TextField still focuses it, buttons still
              // fire, scrolling is untouched (onTap never claims a drag).
              // Every screen gets this without each remembering to add it.
              child: GestureDetector(
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                behavior: HitTestBehavior.translucent,
                child: Stack(
                  children: [
                    child ?? const SizedBox.shrink(),
                    // Voice-room presence outlives the room screen; this is
                    // what says so anywhere in the app, and the way back.
                    const VoiceChannelBanner(),
                    const FileTransferBanner(),
                    // A poke that lands anywhere gets an app-wide "Poke back".
                    const PokeBackBanner(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Enforces the 14-day life of a name-only account.
///
/// Loads the clock for whoever is signed in, and when it has run out ERASES
/// the account and signs out. Both halves matter: erasing without signing out
/// would leave somebody inside an account that no longer has any data, and
/// signing out without erasing would leave it on disk for the next person.
///
/// [expired] is exposed so the UI can say what happened rather than dropping
/// somebody at the login screen with no explanation.
Future<bool> enforceNumberlessGrace() async {
  final session = Session.instance;
  final me = session.user.value;
  // An account holding a server session has no clock either, even though it
  // still carries no phone number. The clock exists because a name-only
  // account is minted in seconds and ANSWERS FOR NOTHING — and one that
  // verified an email answers for a confirmed inbox, which is ban-able
  // (`banned_email_hashes`) and costs something to replace. Without this, an
  // account that verified an email to stop the countdown would be handed a
  // fresh one on the next launch.
  if (me == null ||
      !session.isNumberless ||
      AccountVerification.hasServerSession) {
    // A real account has no clock. Clearing the in-memory one keeps a banner
    // from surviving an upgrade within the same launch.
    await NumberlessGrace.instance.load('');
    return false;
  }
  final grace = NumberlessGrace.instance;
  await grace.load(me.phone);
  // An account that pre-dates the rule has no clock. It gets ONE WEEK from
  // now — not backdated to whenever it signed up, because deleting the data
  // of somebody who was never warned is the one thing this whole feature is
  // built to avoid. The week starts on the launch that tells them.
  if (!grace.running) {
    await grace.adoptExisting(me.phone);
  }
  // Tell them, once. A name-only account has no Supabase session and so no
  // push token — there is no server that can reach it — which makes a LOCAL
  // notification the only honest mechanism, and it is enough: the account
  // can only be deleted while the app is open anyway.
  if (await grace.markTold(me.phone, 'adopted')) {
    await PushService.instance.localNotify(
      title: 'Add a phone number to keep your account',
      body: grace.noticeBody,
    );
  } else if (grace.daysLeft <= 1 &&
      await grace.markTold(me.phone, 'lastday')) {
    await PushService.instance.localNotify(
      title: 'Last day for your account',
      body: 'Add a phone number today or this account and everything in it '
          'is deleted.',
    );
  }
  if (!grace.expired) return false;
  numberlessAccountExpired.value = true;
  await AccountWipe.eraseCurrentAccount();
  await grace.clear(me.phone);
  await session.signOut();
  return true;
}

/// Set when an account was deleted for running out its 14 days, so the login
/// screen can say so. A person who is simply signed out with no word for it
/// assumes the app lost their data — which, from where they stand, it did.
final ValueNotifier<bool> numberlessAccountExpired = ValueNotifier<bool>(false);
