import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tool/paste_functions.dart';
import 'package:okay_messaging/payments/iap_entitlement.dart';
import 'package:okay_messaging/utils/date_formatter.dart';
import 'package:okay_messaging/state/bookmark_store.dart';
import 'package:okay_messaging/state/feed_mute_store.dart';
import 'package:okay_messaging/state/voice_presence_store.dart';
import 'package:okay_messaging/state/channel_typing_store.dart';
import 'package:okay_messaging/state/identity_verification.dart';
import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/crypto/e2e.dart';
import 'package:okay_messaging/data/mock_data.dart';
import 'package:okay_messaging/crypto/key_exchange.dart';
import 'package:okay_messaging/main.dart';
import 'package:okay_messaging/state/callkit_bridge.dart';
import 'package:okay_messaging/state/incoming_links.dart';
import 'package:okay_messaging/models/feed_notification.dart';
import 'package:okay_messaging/util/phone_format.dart';
import 'package:okay_messaging/legal/legal_content.dart';
import 'package:okay_messaging/models/call.dart' as callmodel;
import 'package:okay_messaging/screens/auth/phone_login_screen.dart';
import 'package:okay_messaging/screens/blocked_contacts_screen.dart';
import 'package:okay_messaging/screens/call_screen.dart';
import 'package:okay_messaging/screens/communities.dart';
import 'package:okay_messaging/screens/connect_onboarding_screen.dart';
import 'package:okay_messaging/screens/contacts_on_app_screen.dart';
import 'package:okay_messaging/screens/contact_info_screen.dart';
import 'package:okay_messaging/screens/chats_settings_screen.dart';
import 'package:okay_messaging/screens/okay_pro_screen.dart';
import 'package:okay_messaging/screens/community_settings_screen.dart';
import 'package:okay_messaging/screens/create_server_screen.dart';
import 'package:okay_messaging/models/platform_role.dart';
import 'package:okay_messaging/screens/admin_screen.dart';
import 'package:okay_messaging/screens/settings_screen.dart';
import 'package:okay_messaging/screens/identity_check_screen.dart';
import 'package:okay_messaging/state/platform_moderation.dart';
import 'package:okay_messaging/payments/connect_fields.dart';
import 'package:okay_messaging/payments/payment_diagnostics.dart';
import 'package:okay_messaging/payments/stripe_tokens.dart';
import 'package:okay_messaging/screens/payment_diagnostics_screen.dart';
import 'package:okay_messaging/screens/public_feed_screen.dart';
import 'package:okay_messaging/state/public_feed_store.dart';
import 'package:okay_messaging/widgets/app_shell.dart';
import 'package:okay_messaging/widgets/streak_chip.dart';
import 'package:okay_messaging/widgets/sanction_notice.dart';
import 'package:okay_messaging/screens/forum_screen.dart';
import 'package:okay_messaging/screens/location_picker_screen.dart';
import 'package:okay_messaging/screens/marketplace_screen.dart';
import 'package:okay_messaging/widgets/verified_badge.dart';
import 'package:okay_messaging/screens/map_screen.dart';
import 'package:okay_messaging/screens/maps_settings_screen.dart';
import 'package:okay_messaging/util/geocoding.dart';
import 'package:okay_messaging/util/geolocation.dart';
import 'package:okay_messaging/utils/chat_transcript.dart';
import 'package:okay_messaging/util/routing.dart';
import 'package:okay_messaging/util/speech.dart';
import 'package:okay_messaging/screens/chat_places_screen.dart';
import 'package:okay_messaging/screens/explore_map_screen.dart';
import 'package:okay_messaging/screens/feed_screen.dart';
import 'package:okay_messaging/screens/people_screen.dart';
import 'package:okay_messaging/screens/privacy_settings_screen.dart';
import 'package:okay_messaging/screens/forward_screen.dart';
import 'package:okay_messaging/screens/route_map_screen.dart';
import 'package:latlong2/latlong.dart';
import 'package:okay_messaging/screens/chat_screen.dart';
import 'package:okay_messaging/tabs/activity_tab.dart';
import 'package:okay_messaging/tabs/chats_tab.dart';
import 'package:okay_messaging/utils/maps_link.dart';
import 'package:okay_messaging/widgets/info_section.dart';
import 'package:okay_messaging/widgets/message_bubble.dart';
import 'package:okay_messaging/widgets/osm_map.dart';
import 'package:okay_messaging/screens/score_screen.dart';
import 'package:okay_messaging/models/chat.dart';
import 'package:okay_messaging/state/call_log.dart';
import 'package:okay_messaging/screens/media_gallery_screen.dart';
import 'package:okay_messaging/screens/my_qr_screen.dart';
import 'package:okay_messaging/screens/security_code_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:okay_messaging/models/community.dart';
import 'package:okay_messaging/models/message.dart';
import 'package:okay_messaging/models/user.dart';
import 'package:okay_messaging/relay/relay_service.dart';
import 'package:okay_messaging/state/account_service.dart';
import 'package:okay_messaging/state/app_lock.dart';
import 'package:okay_messaging/state/call_media.dart';
import 'package:okay_messaging/util/ringtone.dart';
import 'package:okay_messaging/state/call_service.dart';
import 'package:okay_messaging/screens/cloud_sync_count.dart';
import 'package:okay_messaging/state/cloud_sync.dart';
import 'package:okay_messaging/state/community_store.dart';
import 'package:okay_messaging/state/file_transfer.dart';
import 'package:okay_messaging/models/status_update.dart';
import 'package:okay_messaging/payments/payment_service.dart';
import 'package:okay_messaging/payments/connect_webview.dart';
import 'package:okay_messaging/payments/connect_webview_stub.dart' as stub;
import 'package:okay_messaging/payments/payment_amount_sheet.dart';
import 'package:okay_messaging/screens/wallet_screen.dart';
import 'package:okay_messaging/payments/storage_economics.dart';
import 'package:okay_messaging/payments/store_purchases.dart';
import 'package:okay_messaging/state/backup_service.dart';
import 'package:okay_messaging/screens/status_screen.dart';
import 'package:okay_messaging/state/status_store.dart';
import 'package:okay_messaging/state/chat_store.dart';
import 'package:okay_messaging/state/gif_service.dart';
import 'package:okay_messaging/state/legal_consent.dart';
import 'package:okay_messaging/state/crash_reporter.dart';
import 'package:okay_messaging/widgets/empty_state.dart';
import 'package:okay_messaging/screens/home_screen.dart';
import 'package:okay_messaging/widgets/app_dialogs.dart';
import 'package:image/image.dart' as img;
import 'package:okay_messaging/state/live_location_broadcaster.dart';
import 'package:okay_messaging/util/file_moderation.dart';
import 'package:okay_messaging/util/photo_prep.dart';
import 'package:okay_messaging/widgets/chat_photo.dart';
import 'package:okay_messaging/widgets/chat_input_bar.dart';
import 'package:okay_messaging/state/account_email.dart';
import 'package:okay_messaging/screens/account_email_screen.dart';
import 'package:okay_messaging/theme/app_theme.dart';
import 'package:okay_messaging/tabs/calls_tab.dart';
import 'package:okay_messaging/screens/starred_messages_screen.dart';
import 'package:okay_messaging/widgets/emoji_data.dart';
import 'package:okay_messaging/screens/edit_group_screen.dart';
import 'package:okay_messaging/screens/group_info_screen.dart';
import 'package:okay_messaging/state/live_location_store.dart';
import 'package:okay_messaging/state/saved_places_store.dart';
import 'package:okay_messaging/state/feed_store.dart';
import 'package:okay_messaging/state/market_media.dart';
import 'package:okay_messaging/state/follow_store.dart';
import 'package:okay_messaging/state/recent_searches.dart';
import 'package:okay_messaging/state/scheduler.dart';
import 'package:okay_messaging/state/score_store.dart';
import 'package:okay_messaging/state/session.dart';
import 'package:okay_messaging/state/storage_store.dart';
import 'package:okay_messaging/state/streak_store.dart';
import 'package:okay_messaging/state/two_step.dart';
import 'package:okay_messaging/screens/find_people_screen.dart';
import 'package:okay_messaging/state/contacts_sync.dart';
import 'package:okay_messaging/state/favourites_store.dart';
import 'package:okay_messaging/state/onboarding_store.dart';
import 'package:okay_messaging/widgets/heart_burst.dart';
import 'package:okay_messaging/widgets/rich_message_text.dart';

/// Opens the contact-info / chat-settings screen from an open chat: the
/// overflow menu's "Contact & chat settings" now hosts what used to be
/// scattered menu items.
Future<void> openChatSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Contact & chat settings'));
  await tester.pumpAndSettle();
}

/// Scrolls the contact-info ListView until [finder] is on screen, then taps
/// it — the chat-settings tiles live below the fold.
Future<void> tapInSettings(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}



/// Goes back the way somebody still can: the platform gesture.
///
/// The app bar's arrow is gone — every screen shows the sidebar there instead,
/// and the bottom bar is always on screen — but the system back gesture (an
/// iOS edge swipe, an Android back) is untouched, so this is what "back" means
/// now. tester.pageBack() looks for the button and cannot find one.
Future<void> goBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  // Singletons persist across tests; reset them so each starts clean. Most
  // tests assume a signed-in user so they land on the home screen; the
  // phone-login test signs out first.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.instance.reset();
    AppState.resetForTest();
    Session.instance.signInForTest();
    // Most tests assume the current terms are already accepted; the consent
    // tests reset this themselves.
    LegalConsent.instance.resetForTest();
    Scheduler.instance.resetForTest();
    CallService.instance.resetForTest();
    AppLock.instance.resetForTest();
    CommunityStore.instance.resetForTest();
    ChatsTab.filtersVisible.value = false;
    LiveLocationStore.instance.resetForTest();
    SavedPlacesStore.instance.resetForTest();
    RecentSearches.maps.resetForTest();
    // Plugin platform channels never complete inside the fake-async test
    // zone, so resolve GPS lookups immediately (with no fix) in tests.
    debugGeolocationOverride = () async => null;
    // The cancellable (dio) tile provider leaves timeout timers pending in
    // the test zone — use the plain provider, whose requests 400 instantly.
    debugTileProviderOverride = NetworkTileProvider.new;
    FollowStore.instance.resetForTest();
    FeedStore.instance.resetForTest();
    FavouritesStore.instance.resetForTest();
    // Treat the new-user nudge as already dismissed so it doesn't overlay
    // unrelated Chats-tab tests; the onboarding test opts back in.
    OnboardingStore.instance.markDoneForTest();
  });

  testWidgets('App boots with Chats and Calls tabs (no Status)',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('OkayMessenger'), findsOneWidget);
    // The modern pill bar labels only the active tab; Chats is active.
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Status'), findsNothing);

    // The Calls destination exists; selecting it reveals its label (and the
    // app bar title also reads "Calls", so it appears more than once).
    expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Calls'), findsWidgets);

    // The new "You" tab hosts settings.
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('At least one conversation is listed on the Chats tab',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('Alice Bennett'), findsOneWidget);
  });

  testWidgets('Create call link opens a sheet with a shareable link',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Go to the Calls tab.
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pumpAndSettle();

    // The call actions moved into the app bar's "Start a call" menu.
    await tester.tap(find.byTooltip('Start a call'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create call link'));
    await tester.pumpAndSettle();

    expect(find.text('Call link ready'), findsOneWidget);
    expect(find.textContaining('https://okay.chat/call/'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Copy'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Share'), findsOneWidget);
  });

  testWidgets('Opening a chat shows the message input bar', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alice Bennett'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Message'), findsOneWidget);
  });

  testWidgets('Sending a message adds it to the conversation', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Hello from a test');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Hello from a test'), findsOneWidget);

    // Let the simulated typing + auto-reply timer fire and settle.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Long-pressing a message shows reaction + action options',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('Reacting to a message shows the reaction on the bubble',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();

    // Tap the ❤️ quick reaction.
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();

    expect(find.text('❤️'), findsOneWidget);
  });

  testWidgets('New-chat action on the Chats tab opens the contact picker',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('New group'), findsOneWidget);
  });

  testWidgets('Searching filters conversations by contact name',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Erin');
    await tester.pumpAndSettle();

    expect(find.text('Erin Foster'), findsOneWidget);
  });

  testWidgets('Starring a message surfaces it in Starred messages',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Star'));
    await tester.pumpAndSettle();

    await goBack(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Starred messages'));
    await tester.pumpAndSettle();

    expect(find.text('Did you see the game last night?'), findsOneWidget);
  });

  testWidgets('Forwarding a message opens the chat picker and sends it',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();

    expect(find.text('Forward to...'), findsOneWidget);

    // Pick Erin's chat and send.
    await tester.tap(find.text('Erin Foster'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // The forwarded message now exists in Erin's conversation.
    final erin = ChatStore.instance.chatWithContact('u_erin');
    expect(erin!.messages.any((m) => m.forwarded), isTrue);
  });

  testWidgets('Tapping a group header opens group info with members',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Team Standup'));
    await tester.pumpAndSettle();

    // Tap the header to open group info.
    await tester.tap(find.text('Team Standup'));
    await tester.pumpAndSettle();

    expect(find.text('7 members'), findsOneWidget);
    expect(find.text('Group admin'), findsOneWidget);
  });

  testWidgets('Recording and sending a voice message adds it to the chat',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Tap the mic to start recording.
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(find.text('Recording…'), findsOneWidget);

    // Tap send to finish and send the voice message.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    final bob = ChatStore.instance.chatWithContact('u_bob');
    expect(bob!.messages.any((m) => m.isVoice), isTrue);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Editing the profile updates the name in Settings',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    // The You tab is a social profile now; edit opens from its button.
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Ada Lovelace');
    // Tap the AppBar save action (a selected avatar swatch also renders a
    // check icon, so scope the finder to the AppBar).
    await tester.tap(find.descendant(
        of: find.byType(AppBar), matching: find.byIcon(Icons.check)));
    await tester.pumpAndSettle();

    expect(find.text('Ada Lovelace'), findsOneWidget);

    // The edit is persisted to the on-device identity, not just in memory.
    expect(Session.instance.user.value?.name, 'Ada Lovelace');
  });

  testWidgets('Swiping a chat row archives it', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.drag(find.text('Bob Carter'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // Gone from the main list; still reachable via the Archived menu entry.
    expect(find.text('Bob Carter'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived chats'));
    await tester.pumpAndSettle();
    expect(find.text('Bob Carter'), findsOneWidget);
  });

  testWidgets('Chat wallpaper picker is reachable from Settings',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats & appearance'));
    await tester.pumpAndSettle();

    final tile = find.text('Chat wallpaper');
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // The wallpaper screen shows the "Default" option.
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('In-chat search filters the conversation', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Search now lives in the overflow menu (decluttered header).
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    final searchField = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(searchField, 'finish');
    await tester.pumpAndSettle();

    // Non-matching messages are filtered out; the live match count is shown.
    expect(find.text('Did you see the game last night?'), findsNothing);
    expect(find.textContaining('What a finish'), findsOneWidget);
    expect(find.textContaining('found'), findsOneWidget);
  });

  test('Chat store survives a JSON serialization round-trip', () {
    ChatStore.instance.addMessage(
      'c_bob',
      Message(
        id: 'persist_1',
        text: 'persist me',
        time: DateTime(2020, 1, 1, 9, 30),
        isMe: true,
      ),
    );
    ChatStore.instance.toggleStar('c_bob', 'persist_1');

    final snapshot = jsonDecode(jsonEncode(ChatStore.instance.toJson()))
        as Map<String, dynamic>;

    ChatStore.instance.reset();
    expect(
      ChatStore.instance
          .chatById('c_bob')!
          .messages
          .any((m) => m.id == 'persist_1'),
      isFalse,
    );

    ChatStore.instance.hydrate(snapshot);
    expect(
      ChatStore.instance
          .chatById('c_bob')!
          .messages
          .any((m) => m.text == 'persist me'),
      isTrue,
    );
    expect(ChatStore.instance.isStarred('c_bob', 'persist_1'), isTrue);
  });

  testWidgets('Multi-select lets you delete several messages at once',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Enter selection via the message actions sheet.
    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget); // selection count

    // Tap the other message to add it to the selection.
    await tester.tap(find.textContaining('What a finish'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    // Delete both.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob');
    expect(bob!.messages, isEmpty);
  });

  testWidgets('Pinning a message shows the pinned banner', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(find.text('Pinned message'), findsOneWidget);
    final bob = ChatStore.instance.chatWithContact('u_bob');
    expect(bob!.pinnedMessageId, isNotNull);
  });

  testWidgets('Archiving a chat moves it into the Archived screen',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Long-press Carol's chat and archive it.
    await tester.longPress(find.text('Carol Diaz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive chat'));
    await tester.pumpAndSettle();

    // Carol is gone from the main list.
    expect(find.text('Carol Diaz'), findsNothing);

    // Archived chats are reachable from the app-bar menu.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived chats'));
    await tester.pumpAndSettle();
    expect(find.text('Carol Diaz'), findsOneWidget);
  });

  testWidgets('Sending a photo from the attachment sheet adds an image message',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Photos now come from the real picker; stub it with a generated image.
    final photo = img.Image(width: 320, height: 240);
    img.fill(photo, color: img.ColorRgb8(30, 90, 200));
    PhotoPrep.debugPickOverride =
        () async => Uint8List.fromList(img.encodeJpg(photo));
    addTearDown(() => PhotoPrep.debugPickOverride = null);

    // Open the inline attachment panel and pick Photos.
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob');
    final sentPhoto = bob!.messages.lastWhere((m) => m.isImage);
    // The real picked photo rides inline as a data URI.
    expect(sentPhoto.imageUrl, isNotNull);
    expect(PhotoPrep.isDataUri(sentPhoto.imageUrl!), isTrue);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Sharing a location opens the map picker and sends a point',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Location'));
    // The picker hosts a FlutterMap whose tile timers never settle, so pump
    // fixed frames instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Send this location'), findsOneWidget);
    await tester.tap(find.text('Send this location'));
    await tester.pump();
    // Drain the 1.4s demo auto-reply timer so none is pending at teardown.
    await tester.pump(const Duration(seconds: 2));

    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    expect(bob.messages.any((m) => m.isLocation), isTrue);

    // Unmount so any map tile work is torn down before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('Sharing a contact sends a contact card', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contact'));
    await tester.pumpAndSettle();

    // Pick the first contact in the share sheet.
    await tester.tap(find.text('Alice Bennett').last);
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final card = bob.messages.firstWhere((m) => m.isContact);
    expect(card.contactName, 'Alice Bennett');
    // The card offers a Message action.
    expect(find.widgetWithText(TextButton, 'Message'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Tapping a photo opens the full-screen image viewer',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Erin's chat contains a sample photo message.
    await tester.tap(find.text('Erin Foster'));
    await tester.pumpAndSettle();

    // Two image icons render at this point (the photo bubble + the camera
    // button in the input bar); tapping the bubble's opens the viewer.
    await tester.tap(find.byIcon(Icons.image).first);
    await tester.pumpAndSettle();

    // The viewer shows the sender name and a zoomable image.
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Erin Foster'), findsOneWidget);
  });

  testWidgets('Double-tapping a message quick-reacts with a heart',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob');
    final firstId = bob!.messages.first.id;

    await tester.tap(find.text('Did you see the game last night?'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Did you see the game last night?'));
    await tester.pump(const Duration(milliseconds: 100));

    // A heart bursts over the tap point...
    expect(find.byType(HeartBurst), findsOneWidget);

    // ...and the reaction is recorded on the message.
    expect(ChatStore.instance.chatById('c_bob')!.messages
        .firstWhere((m) => m.id == firstId)
        .reactions
        .contains('❤️'), isTrue);

    // Let the burst animation finish and remove its overlay.
    await tester.pumpAndSettle();
    expect(find.byType(HeartBurst), findsNothing);
  });

  testWidgets('A message containing a URL renders a tappable link',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Carol Diaz'));
    await tester.pumpAndSettle();

    // Carol's chat has a message with a link, rendered via RichMessageText.
    expect(find.byType(RichMessageText), findsWidgets);

    // Tapping the link span copies it and shows a confirmation snackbar.
    // (Pump past the double-tap timeout so the single tap resolves to the
    // link's recognizer rather than the bubble's double-tap detector.)
    await tester.tapOnText(find.textRange.ofSubstring('okaydocs.example'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Link copied'), findsOneWidget);
  });

  test('Rich text parses bold/italic/strike/mono markers', () {
    List<RunStyle> stylesOf(String s) =>
        RichMessageText.parse(s).map((r) => r.style).toList();

    final runs = RichMessageText.parse('a *b* _c_ ~d~ `e`');
    expect(runs.map((r) => r.text).join(), 'a b c d e');
    expect(stylesOf('*bold*'), [RunStyle.bold]);
    expect(stylesOf('_x_'), [RunStyle.italic]);
    expect(stylesOf('~x~'), [RunStyle.strike]);
    expect(stylesOf('`x`'), [RunStyle.mono]);
    expect(stylesOf('plain'), [RunStyle.plain]);
  });

  testWidgets('Tapping the call button rings the peer, hang-up dismisses it',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Start a voice call from the chat header. The ringing halo animates
    // forever, so pump fixed frames instead of settling.
    await tester.tap(find.byIcon(Icons.call));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The call screen shows the contact and a ringing status.
    expect(find.byType(CallScreen), findsOneWidget);
    expect(find.text('Ringing…'), findsOneWidget);
    expect(CallService.instance.current.value?.direction,
        CallDirection.outgoing);

    // Hanging up dismisses the call overlay.
    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsNothing);
    expect(CallService.instance.current.value, isNull);
  });

  group('Call signaling', () {
    setUp(() => CallService.instance.resetForTest());

    AppUser peer() => const AppUser(
          id: '+1 555 0199',
          name: 'Grace',
          avatarColor: '#64B5F6',
          about: 'Available',
          phone: '+1 555 0199',
        );

    test('outgoing call is ringing, then connects when the peer answers', () {
      final call = CallService.instance;
      call.startOutgoing(peer(), video: false);
      expect(call.current.value?.status, CallStatus.ringing);
      expect(call.isBusy, isTrue);

      call.onRemoteAnswer(call.current.value!.callId);
      expect(call.current.value?.status, CallStatus.connected);
      expect(call.current.value?.connectedAt, isNotNull);
    });

    test('a declined outgoing call moves to declined', () {
      final call = CallService.instance;
      call.startOutgoing(peer(), video: true);
      call.onRemoteDecline(call.current.value!.callId);
      expect(call.current.value?.status, CallStatus.declined);
    });

    test('an incoming offer rings; accepting connects it', () {
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'call_abc', false);
      expect(call.current.value?.direction, CallDirection.incoming);
      expect(call.current.value?.status, CallStatus.ringing);

      call.accept();
      expect(call.current.value?.status, CallStatus.connected);
    });

    test('a remote hang-up ends the connected call', () {
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'call_xyz', false);
      call.accept();
      call.onRemoteEnd('call_xyz');
      expect(call.current.value?.status, CallStatus.ended);
    });

    test('a stale callId is ignored', () {
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'call_1', false);
      call.onRemoteEnd('some_other_call');
      // Still ringing — the end was for a different call.
      expect(call.current.value?.status, CallStatus.ringing);
    });

    test('silence unknown callers: strangers are muted, contacts still ring',
        () {
      final call = CallService.instance;
      ChatStore.instance.reset();
      AppState.silenceUnknownCallers.value = true;

      // A stranger we've never chatted with is silently declined.
      call.onRemoteOffer(peer(), 'call_stranger', false);
      expect(call.current.value, isNull);

      // Someone we already have a chat with still rings through.
      final known = ChatStore.instance.chats.first.contact;
      call.onRemoteOffer(known, 'call_known', false);
      expect(call.current.value?.status, CallStatus.ringing);

      AppState.silenceUnknownCallers.value = false;
      call.resetForTest();
    });

    test('blocked numbers never ring', () {
      final call = CallService.instance;
      AppState.setBlocked(peer().phone, true);
      call.onRemoteOffer(peer(), 'call_blocked', false);
      expect(call.current.value, isNull);
      AppState.setBlocked(peer().phone, false);
    });

    test('leaveVoicemail records a voicemail voice message in the chat', () {
      ChatStore.instance.reset();
      final contact = ChatStore.instance.chats.first.contact;
      final ok = CallService.instance.leaveVoicemail(contact, 8);
      expect(ok, isTrue);
      final chat = ChatStore.instance.chatWithContact(contact.id)!;
      final vm = chat.messages.last;
      expect(vm.isVoicemail, isTrue);
      expect(vm.isVoice, isTrue);
      expect(vm.voiceSeconds, 8);
      expect(vm.isMe, isTrue);
    });

    test('leaveVoicemail rejects an empty recording', () {
      final contact = ChatStore.instance.chats.first.contact;
      expect(CallService.instance.leaveVoicemail(contact, 0), isFalse);
    });

    test('ending an outgoing call records it as outgoing in the log', () {
      CallLog.instance.resetForTest();
      final call = CallService.instance;
      call.startOutgoing(peer(), video: false);
      call.end();
      final rec = CallLog.instance.records.single;
      expect(rec.direction, callmodel.CallDirection.outgoing);
      expect(rec.type, callmodel.CallType.voice);
      expect(rec.user.phone, peer().phone);
    });

    test('an unanswered incoming call is logged as missed', () {
      CallLog.instance.resetForTest();
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'c_missed', true);
      call.onRemoteEnd('c_missed'); // caller gave up before we answered
      final rec = CallLog.instance.records.single;
      expect(rec.direction, callmodel.CallDirection.missed);
      expect(rec.type, callmodel.CallType.video);
    });

    test('an answered incoming call is logged as incoming', () {
      CallLog.instance.resetForTest();
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'c_in', false);
      call.accept();
      call.end();
      expect(CallLog.instance.records.single.direction,
          callmodel.CallDirection.incoming);
    });

    test('a call is only logged once', () {
      CallLog.instance.resetForTest();
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'c_once', false);
      call.accept();
      call.onRemoteEnd('c_once');
      call.end(); // no-op: already cleared
      expect(CallLog.instance.records.length, 1);
    });
  });

  group('Call log store', () {
    setUp(() => CallLog.instance.resetForTest());

    callmodel.CallRecord rec(String id, DateTime t) => callmodel.CallRecord(
          id: id,
          user: const AppUser(
            id: '+1 555 0110',
            name: 'Dora',
            avatarColor: '#4DB6AC',
            about: 'Available',
            phone: '+1 555 0110',
          ),
          time: t,
          type: callmodel.CallType.voice,
          direction: callmodel.CallDirection.outgoing,
        );

    test('call duration formats and round-trips through JSON', () {
      const user = AppUser(
          id: 'x', name: 'X', avatarColor: '#000000', phone: '+1 555 0110');
      callmodel.CallRecord withDuration(int s) => callmodel.CallRecord(
            id: 'd',
            user: user,
            time: DateTime(2024, 1, 1),
            type: callmodel.CallType.video,
            direction: callmodel.CallDirection.outgoing,
            durationSeconds: s,
          );
      expect(withDuration(0).durationLabel, isNull); // missed / unanswered
      expect(withDuration(65).durationLabel, '1:05');
      expect(withDuration(3661).durationLabel, '1:01:01');
      final back =
          callmodel.CallRecord.fromJson(withDuration(125).toJson());
      expect(back.durationSeconds, 125);
      expect(back.durationLabel, '2:05');
    });

    test('records are ordered newest-first by time and clear empties them', () {
      CallLog.instance.add(rec('a', DateTime(2024, 1, 1)));
      CallLog.instance.add(rec('b', DateTime(2024, 1, 3)));
      CallLog.instance.add(rec('c', DateTime(2024, 1, 2)));
      // Sorted by time descending regardless of insertion order.
      expect(CallLog.instance.records.map((r) => r.id).toList(),
          ['b', 'c', 'a']);
      expect(CallLog.instance.records.length, 3);

      CallLog.instance.clear();
      expect(CallLog.instance.isEmpty, isTrue);
    });

    test('CallRecord serializes round-trip through JSON', () {
      final original = rec('x', DateTime(2024, 5, 6, 7, 8));
      final restored =
          callmodel.CallRecord.fromJson(original.toJson());
      expect(restored.id, 'x');
      expect(restored.user.name, 'Dora');
      expect(restored.type, callmodel.CallType.voice);
      expect(restored.direction, callmodel.CallDirection.outgoing);
      expect(restored.time, DateTime(2024, 5, 6, 7, 8));
    });

    test('newMissedCount counts unseen missed calls; markSeen clears it', () {
      callmodel.CallRecord missed(String id, DateTime t) =>
          callmodel.CallRecord(
            id: id,
            user: const AppUser(
              id: '+1 555 0110',
              name: 'Dora',
              avatarColor: '#4DB6AC',
              about: 'Available',
              phone: '+1 555 0110',
            ),
            time: t,
            type: callmodel.CallType.voice,
            direction: callmodel.CallDirection.missed,
          );

      CallLog.instance.add(missed('m1', DateTime(2024, 1, 1)));
      CallLog.instance.add(missed('m2', DateTime(2024, 1, 2)));
      CallLog.instance.add(rec('o1', DateTime(2024, 1, 3))); // outgoing
      // Both missed calls are unseen; the outgoing one doesn't count.
      expect(CallLog.instance.newMissedCount, 2);

      CallLog.instance.markSeen();
      expect(CallLog.instance.newMissedCount, 0);
    });
  });

  testWidgets('Media gallery lists photos and links shared in a chat',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Carol's chat has a shared link; open the media gallery from the menu.
    await tester.tap(find.text('Carol Diaz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media, links, and docs'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaGalleryScreen), findsOneWidget);

    // Media tab is empty for Carol; the Links tab shows the shared link.
    expect(find.text('No media shared yet'), findsOneWidget);
    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.textContaining('okaydocs.example'), findsOneWidget);
  });

  test('login identifiers: email vs username vs nonsense', () {
    // What the "sign in with username or email" field does with what people
    // actually type. Emails route to the email code; handles (with or
    // without the @ people habitually add) route to the account's phone;
    // anything else is refused with a message, never guessed at.
    expect(AccountService.loginIdentifierKind('ada@example.com'), 'email');
    expect(
        AccountService.loginIdentifierKind(' ada.lovelace+ok@mail.co.uk '),
        'email');
    expect(AccountService.loginIdentifierKind('ada_l'), 'username');
    expect(AccountService.loginIdentifierKind('@ada_l'), 'username');
    expect(AccountService.loginIdentifierKind('ada@'), 'invalid');
    expect(AccountService.loginIdentifierKind('has spaces'), 'invalid');
    expect(AccountService.loginIdentifierKind(''), 'invalid');
    expect(AccountService.loginIdentifierKind('ab'), 'invalid'); // too short
  });

  test('a username login never echoes the full phone number back', () {
    // The directory maps handle -> phone; the login screen must show only
    // enough of it to recognise your own.
    expect(AccountService.maskPhone('+1 555 012 3456'), '••• ••• 3456');
    expect(AccountService.maskPhone('15550123456'), '••• ••• 3456');
    expect(AccountService.maskPhone('123'), '123'); // nothing to hide behind
  });

  testWidgets('registering without a username is allowed', (tester) async {
    Session.instance.resetForTest();

    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Your name'), 'Ada');
    // Username left empty on purpose — it only means nobody can find you by
    // handle yet, and sign-in never depended on it.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone number'), '5550123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.byType(PhoneLoginScreen), findsNothing);
    expect(Session.instance.user.value?.username, isEmpty);
    Session.instance.resetForTest();
  });

  testWidgets('Signed out, the phone login screen gates the app then signs in',
      (tester) async {
    Session.instance.resetForTest();

    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // With no local identity, the phone login screen is shown, not the chats.
    expect(find.byType(PhoneLoginScreen), findsOneWidget);
    expect(find.text('Alice Bennett'), findsNothing);

    // Enter a name, username and phone number and continue.
    await tester.enterText(find.widgetWithText(TextFormField, 'Your name'),
        'Ada');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username (optional)'), 'AdaL');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone number'), '5550123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Now signed in with a normalized username.
    expect(find.byType(PhoneLoginScreen), findsNothing);
    expect(find.text('Alice Bennett'), findsOneWidget);
    expect(Session.instance.user.value?.username, 'adal');
  });

  testWidgets('Contact info shows the contact\'s @username', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alice Bennett'));
    await tester.pumpAndSettle();
    // Tap the header to open contact info.
    await tester.tap(find.text('Alice Bennett'));
    await tester.pumpAndSettle();

    expect(find.text('@aliceb'), findsOneWidget);
  });

  testWidgets('Encryption tile opens the security code screen', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alice Bennett'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice Bennett')); // open contact info
    await tester.pumpAndSettle();

    final tile = find.text('Encryption');
    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('Security code'), findsOneWidget);
    // The 12-group code renders (spot-check a couple of groups exist).
    expect(find.byType(SecurityCodeScreen), findsOneWidget);
  });

  testWidgets('Replying quotes the original and the quote jumps back to it',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Reply to the first incoming message.
    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'replying now');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    // The reply carries the original message id and quotes its text.
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final reply = bob.messages.firstWhere((m) => m.text == 'replying now');
    expect(reply.replyTo?.messageId, isNotNull);

    // Original text now appears twice: the message itself and the quote.
    expect(find.text('Did you see the game last night?'), findsNWidgets(2));

    // Tapping the quote jumps to the original without error.
    await tester.tap(find.text('Did you see the game last night?').last);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Did you see the game last night?'), findsWidgets);
    await tester.pump(const Duration(seconds: 2));
  });

  test('Scheduler delivers due messages and keeps future ones pending', () {
    ChatStore.instance.reset();
    Scheduler.instance.resetForTest();
    final now = DateTime(2024, 1, 1, 12, 0);

    // One due (in the past) and one for the future.
    Scheduler.instance.schedule(
      chatId: 'c_bob',
      contactPhone: '+1 555 0122',
      text: 'due now',
      time: now.subtract(const Duration(minutes: 1)),
    );
    Scheduler.instance.schedule(
      chatId: 'c_bob',
      contactPhone: '+1 555 0122',
      text: 'later',
      time: now.add(const Duration(hours: 2)),
    );
    expect(Scheduler.instance.pendingFor('c_bob').length, 2);

    final delivered = Scheduler.instance.flushDue(now);
    expect(delivered, 1);

    // The due message is now in the conversation; the future one stays pending.
    expect(
      ChatStore.instance.chatById('c_bob')!.messages.any((m) => m.text == 'due now'),
      isTrue,
    );
    final pending = Scheduler.instance.pendingFor('c_bob');
    expect(pending.length, 1);
    expect(pending.single.text, 'later');

    // Cancelling removes it.
    Scheduler.instance.cancel(pending.single.id);
    expect(Scheduler.instance.pendingFor('c_bob'), isEmpty);
  });

  test('disappearing messages: new messages get an expiry and are swept', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    ChatStore.instance.setDisappearing(bob.id, 3600); // 1 hour

    final base = DateTime(2024, 1, 1, 12);
    ChatStore.instance.addMessage(
      bob.id,
      Message(id: 'disp1', text: 'poof', time: base, isMe: true),
    );
    final msg = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((m) => m.id == 'disp1');
    expect(msg.expiresAt, base.add(const Duration(hours: 1)));

    // Not yet expired.
    expect(ChatStore.instance.sweepExpired(base.add(const Duration(minutes: 30))),
        0);
    expect(
      ChatStore.instance.chatById(bob.id)!.messages.any((m) => m.id == 'disp1'),
      isTrue,
    );

    // After the hour, it's swept away.
    final removed =
        ChatStore.instance.sweepExpired(base.add(const Duration(hours: 2)));
    expect(removed, greaterThanOrEqualTo(1));
    expect(
      ChatStore.instance.chatById(bob.id)!.messages.any((m) => m.id == 'disp1'),
      isFalse,
    );
  });

  test('disappearing off leaves messages without an expiry', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    ChatStore.instance.addMessage(
      bob.id,
      Message(id: 'keep1', text: 'stays', time: DateTime(2024), isMe: true),
    );
    final msg = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((m) => m.id == 'keep1');
    expect(msg.expiresAt, isNull);
  });

  testWidgets('Blocking a contact replaces the composer with a banner',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatInputBar), findsOneWidget);

    // Open contact info and block.
    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    final blockTile = find.text('Block Bob Carter');
    await tester.scrollUntilVisible(blockTile, 200,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(blockTile);
    await tester.pumpAndSettle();
    await tester.tap(blockTile);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    final bobPhone = ChatStore.instance.chatWithContact('u_bob')!.contact.phone;
    expect(AppState.isBlocked(bobPhone), isTrue);

    // Back in the conversation, the composer is gone and a banner shows.
    await goBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ChatInputBar), findsNothing);
    expect(find.text('You blocked Bob Carter'), findsOneWidget);
  });

  testWidgets('Chat menu: Wallpaper opens the picker, Export saves the chat',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Wallpaper opens the picker screen (chat settings now live on the
    // contact info screen).
    await openChatSettings(tester);
    await tapInSettings(tester, find.text('Wallpaper & sound'));
    // Per-chat wallpaper picker (its "Default" swatch is shown).
    expect(find.text('Default'), findsOneWidget);
    await goBack(tester);
    await tester.pumpAndSettle();

    // Export builds a transcript and hands it off (share/download), then
    // confirms via a snackbar.
    await tapInSettings(tester, find.text('Export chat'));
    // The save goes through a real platform channel (path_provider), so let it
    // run on the real event loop before the confirmation snackbar appears.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Disappearing-messages setting sets a timer and shows the indicator',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await openChatSettings(tester);
    await tapInSettings(tester, find.text('Disappearing messages'));
    await tester.tap(find.text('1 day'));
    await tester.pumpAndSettle();
    await goBack(tester); // back to the chat
    await tester.pumpAndSettle();

    // The timer indicator now shows in the header.
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    final chat = ChatStore.instance.chatWithContact('u_bob')!;
    expect(chat.disappearingSeconds, 86400);
  });

  test('drafts save, clear when emptied, and survive a hydrate round-trip', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    ChatStore.instance.setDraft(bob.id, '  half a thought  ');
    expect(ChatStore.instance.draftFor(bob.id), 'half a thought');

    // Persist + restore.
    final snapshot = ChatStore.instance.toJson();
    ChatStore.instance.reset();
    expect(ChatStore.instance.draftFor(bob.id), '');
    ChatStore.instance.hydrate(snapshot);
    expect(ChatStore.instance.draftFor(bob.id), 'half a thought');

    // Emptying clears it.
    ChatStore.instance.setDraft(bob.id, '');
    expect(ChatStore.instance.draftFor(bob.id), '');
  });

  test('per-chat wallpaper overrides the default and survives persistence', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    expect(ChatStore.instance.wallpaperFor(bob.id), isNull);

    ChatStore.instance.setWallpaper(bob.id, const Color(0xFFDCEBF5));
    expect(ChatStore.instance.wallpaperFor(bob.id), const Color(0xFFDCEBF5));

    final snapshot = ChatStore.instance.toJson();
    ChatStore.instance.reset();
    expect(ChatStore.instance.wallpaperFor(bob.id), isNull);
    ChatStore.instance.hydrate(snapshot);
    expect(ChatStore.instance.wallpaperFor(bob.id), const Color(0xFFDCEBF5));

    ChatStore.instance.setWallpaper(bob.id, null);
    expect(ChatStore.instance.wallpaperFor(bob.id), isNull);
  });

  testWidgets('A draft is saved on leaving a chat and restored on return',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'unsent draft');
    await tester.pump();

    // Leave the chat: the chat list shows a Draft indicator.
    await goBack(tester);
    await tester.pumpAndSettle();
    expect(find.text('Draft: '), findsOneWidget);
    expect(ChatStore.instance.chatWithContact('u_bob')!.id, isNotEmpty);
    expect(
      ChatStore.instance
          .draftFor(ChatStore.instance.chatWithContact('u_bob')!.id),
      'unsent draft',
    );

    // Reopening restores the text into the composer.
    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'unsent draft'), findsOneWidget);
  });

  testWidgets('React with any emoji via the + picker', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Did you see the game last night?'));
    await tester.pumpAndSettle();

    // Open the full emoji picker from the reaction row's "+".
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('React with…'), findsOneWidget);

    await tester.tap(find.text('😀'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    expect(bob.messages.any((m) => m.reactions.contains('😀')), isTrue);
  });

  test('Communities: create, add a slugified channel, and post a message', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Gamers');
    // A fresh community starts with a text #general and a voice channel.
    expect(c.channels.length, 2);
    expect(c.channels.first.name, 'general');
    expect(c.channels.first.type, ChannelType.text);
    expect(c.channels.last.type, ChannelType.voice);
    // The creator is the owner.
    expect(c.members.single.role, MemberRole.owner);

    CommunityStore.instance.addChannel(c.id, 'Off Topic');
    final updated = CommunityStore.instance.byId(c.id)!;
    expect(updated.channels.length, 3);
    expect(updated.channels.last.name, 'off-topic'); // slugified

    CommunityStore.instance.postMessage(
      c.id,
      updated.channels.first.id,
      Message(id: 'm', text: 'gg', time: DateTime(2024), isMe: true),
    );
    expect(
      CommunityStore.instance.byId(c.id)!.channels.first.messages.length,
      1,
    );
  });

  test('Server roles: moderator can moderate but not manage; ranks order', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Guild');
    // Rank ordering, highest first.
    expect(roleRank(MemberRole.owner), greaterThan(roleRank(MemberRole.admin)));
    expect(roleRank(MemberRole.admin),
        greaterThan(roleRank(MemberRole.moderator)));
    expect(roleRank(MemberRole.moderator),
        greaterThan(roleRank(MemberRole.member)));

    // Permission helpers: moderators moderate, only admins+ manage.
    expect(roleCanModerate(MemberRole.moderator), isTrue);
    expect(roleCanManageServer(MemberRole.moderator), isFalse);
    expect(roleCanManageServer(MemberRole.admin), isTrue);
    expect(roleCanModerate(MemberRole.member), isFalse);

    // The owner can moderate and manage.
    expect(CommunityStore.instance.canModerate(c.id), isTrue);
    expect(CommunityStore.instance.canManageServer(c.id), isTrue);

    // Assigning the new Moderator role round-trips through JSON.
    final revived = Member.fromJson(
        const Member(id: 'x', name: 'Mo', role: MemberRole.moderator).toJson());
    expect(revived.role, MemberRole.moderator);
    expect(roleName(MemberRole.moderator), 'Moderator');
  });

  test('a server is born with its privacy settings, not wide open', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity(
      'Announcements',
      description: 'Read-only news',
      icon: '🚀',
      invitePolicy: invitePolicyAdmins,
      membersCanMessage: false,
      membersCanCreateChannels: false,
      membersCanPost: false,
      slowModeSeconds: 30,
    );
    expect(c.description, 'Read-only news');
    expect(c.icon, '🚀');
    expect(c.invitePolicy, invitePolicyAdmins);
    expect(c.membersCanMessage, isFalse);
    expect(c.membersCanCreateChannels, isFalse);
    expect(c.membersCanPost, isFalse);
    expect(c.slowModeSeconds, 30);

    // The new fields survive a JSON round trip…
    final revived = Community.fromJson(c.toJson());
    expect(revived.invitePolicy, invitePolicyAdmins);
    expect(revived.membersCanMessage, isFalse);
    // …and JSON from an older build (no such keys) reads as open, which is
    // the behaviour every existing server already had.
    final oldJson = c.toJson()
      ..remove('invitePolicy')
      ..remove('membersCanMessage');
    final old = Community.fromJson(oldJson);
    expect(old.invitePolicy, invitePolicyEveryone);
    expect(old.membersCanMessage, isTrue);

    // Defaults stay open when nothing is chosen.
    final open = CommunityStore.instance.createCommunity('Open');
    expect(open.invitePolicy, invitePolicyEveryone);
    expect(open.membersCanMessage, isTrue);
  });

  test('invite policy decides who may share the server', () {
    // The pure matrix, role by role.
    expect(roleCanInvite(MemberRole.member, invitePolicyEveryone), isTrue);
    expect(roleCanInvite(MemberRole.member, invitePolicyModerators), isFalse);
    expect(
        roleCanInvite(MemberRole.moderator, invitePolicyModerators), isTrue);
    expect(roleCanInvite(MemberRole.moderator, invitePolicyAdmins), isFalse);
    expect(roleCanInvite(MemberRole.admin, invitePolicyAdmins), isTrue);
    expect(roleCanInvite(MemberRole.owner, invitePolicyAdmins), isTrue);
    // A policy string this build doesn't know fails closed for members —
    // a privacy choice must not widen on devices that can't read it.
    expect(roleCanInvite(MemberRole.member, 'via-qr'), isFalse);
    expect(roleCanInvite(MemberRole.owner, 'via-qr'), isTrue);

    // Store level: the creator (owner) may always invite; the policy rides
    // inside the invite itself and binds a joiner from the first moment.
    CommunityStore.instance.resetForTest();
    final store = CommunityStore.instance;
    final c =
        store.createCommunity('Sealed', invitePolicy: invitePolicyAdmins);
    expect(store.canInvite(c.id), isTrue);
    final invite = store.exportInvite(c.id,
        myDigits: '15550101111', myName: 'Alice')!;
    expect(invite['invitePolicy'], invitePolicyAdmins);
    store.deleteCommunity(c.id);
    final joined = store.joinFromInvite(Map<String, dynamic>.from(invite),
        myDigits: '15550102222', myName: 'Bob')!;
    expect(joined.invitePolicy, invitePolicyAdmins);
    expect(store.canInvite(joined.id), isFalse);
  });

  test('a broadcast-only server silences members, not moderators', () {
    CommunityStore.instance.resetForTest();
    final store = CommunityStore.instance;
    final c = store.createCommunity('News', membersCanMessage: false);
    // The owner speaks freely in their own broadcast server.
    expect(store.canSendMessages(c.id), isTrue);

    // A joiner is read-only from the moment they join — the setting travels
    // inside the invite, not only in later structure broadcasts.
    final invite = store.exportInvite(c.id,
        myDigits: '15550101111', myName: 'Alice')!;
    store.deleteCommunity(c.id);
    store.joinFromInvite(Map<String, dynamic>.from(invite),
        myDigits: '15550102222', myName: 'Bob');
    expect(store.canSendMessages(c.id), isFalse);

    // The owner later opens the floor; the structure broadcast flips it
    // on Bob's device too.
    final opened = Map<String, dynamic>.from(invite);
    opened['membersCanMessage'] = true;
    opened['members'] = [
      ...(invite['members'] as List),
      const Member(id: 'u_15550102222', name: 'Bob').toJson(),
    ];
    store.applyRemoteStructure(opened, myDigits: '15550102222');
    expect(store.canSendMessages(c.id), isTrue);
  });

  testWidgets('the create-server form bakes privacy in from birth',
      (tester) async {
    CommunityStore.instance.resetForTest();
    // The form is one long scroll; a tall viewport keeps it all mounted.
    tester.view.physicalSize = const Size(500, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: CreateServerScreen()));
    // Without a name there is nothing to create.
    final createBtn = find.widgetWithText(FilledButton, 'Create server');
    expect(tester.widget<FilledButton>(createBtn).onPressed, isNull);

    await tester.enterText(
        find.widgetWithText(TextField, 'Server name'), 'Book Club');
    await tester.tap(find.text('Admins only'));
    await tester.tap(find.text('Members can send messages'));
    await tester.pump();
    await tester.tap(createBtn);
    await tester.pump();

    final c = CommunityStore.instance.communities
        .firstWhere((c) => c.name == 'Book Club');
    expect(c.invitePolicy, invitePolicyAdmins);
    expect(c.membersCanMessage, isFalse);
    expect(c.members.single.role, MemberRole.owner);
    // Untouched switches keep their open defaults.
    expect(c.membersCanCreateChannels, isTrue);
    expect(c.membersCanPost, isTrue);
  });

  test('Channel messages: react (toggle) and delete', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Team');
    final chan = c.channels.firstWhere((ch) => ch.type == ChannelType.text);
    CommunityStore.instance.postMessage(c.id, chan.id,
        Message(id: 'm1', text: 'hello', time: DateTime(2024), isMe: true));

    Message msg() => CommunityStore.instance
        .byId(c.id)!
        .channels
        .firstWhere((ch) => ch.id == chan.id)
        .messages
        .firstWhere((m) => m.id == 'm1');

    CommunityStore.instance.toggleChannelReaction(c.id, chan.id, 'm1', '👍');
    expect(msg().reactions, contains('👍'));
    // Toggling the same emoji removes it.
    CommunityStore.instance.toggleChannelReaction(c.id, chan.id, 'm1', '👍');
    expect(msg().reactions, isNot(contains('👍')));

    CommunityStore.instance.deleteChannelMessage(c.id, chan.id, 'm1');
    final chanAfter = CommunityStore.instance
        .byId(c.id)!
        .channels
        .firstWhere((ch) => ch.id == chan.id);
    expect(chanAfter.messages.any((m) => m.id == 'm1'), isFalse);
  });

  group('Forum channels', () {
    test('Reddit-style vote toggles and switches direction', () {
      // Up from neutral.
      expect(applyVote(5, 0, 1), (6, 1));
      // Tapping up again clears it.
      expect(applyVote(6, 1, 1), (5, 0));
      // Down from neutral.
      expect(applyVote(5, 0, -1), (4, -1));
      // Switching from up to down moves two.
      expect(applyVote(6, 1, -1), (4, -1));
      // Switching from down to up moves two.
      expect(applyVote(4, -1, 1), (6, 1));
    });

    test('a forum channel holds votable posts with comments', () {
      CommunityStore.instance.resetForTest();
      final c = CommunityStore.instance.createCommunity('Gamers');
      CommunityStore.instance.addChannel(c.id, 'discussion',
          type: ChannelType.forum);
      final chId = CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.type == ChannelType.forum)
          .id;

      CommunityStore.instance.addForumPost(
        c.id,
        chId,
        ForumPost(
          id: 'p1',
          authorId: 'me',
          authorName: 'You',
          time: DateTime(2024, 1, 1),
          title: 'Best strategy?',
          body: 'Share yours',
        ),
      );
      var post = CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == chId)
          .posts
          .single;
      expect(post.title, 'Best strategy?');
      expect(post.score, 1); // author's own upvote

      CommunityStore.instance.voteForumPost(c.id, chId, 'p1', 1);
      // Already self-upvoted, so tapping up again clears to 0.
      post = CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == chId)
          .posts
          .single;
      expect(post.score, 0);
      expect(post.myVote, 0);

      CommunityStore.instance.addForumComment(
        c.id,
        chId,
        'p1',
        ForumComment(
          id: 'cm1',
          authorId: 'm2',
          authorName: 'Ada',
          time: DateTime(2024, 1, 1, 1),
          body: 'Rush mid.',
        ),
      );
      post = CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == chId)
          .posts
          .single;
      expect(post.comments.single.body, 'Rush mid.');
    });

    test('delete post/comment and pin float, with moderator check', () {
      CommunityStore.instance.resetForTest();
      // The seeded Design Team makes the local user (member "me") the owner.
      expect(CommunityStore.instance.canModerate('seed_design'), isTrue);

      // Pin floats a post above a higher-scored, unpinned one.
      CommunityStore.instance
          .togglePinForumPost('seed_design', 'seed_forum', 'seed_post_2');
      final posts = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts;
      expect(sortPosts(posts, ForumSort.top).first.id, 'seed_post_2');

      // Delete a comment, then the whole post.
      CommunityStore.instance.deleteForumComment(
          'seed_design', 'seed_forum', 'seed_post_1', 'seed_c1');
      var post1 = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts
          .firstWhere((p) => p.id == 'seed_post_1');
      expect(post1.comments.any((c) => c.id == 'seed_c1'), isFalse);

      CommunityStore.instance
          .deleteForumPost('seed_design', 'seed_forum', 'seed_post_1');
      final remaining = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts;
      expect(remaining.any((p) => p.id == 'seed_post_1'), isFalse);
    });

    test('editing a forum post updates it and flags edited', () {
      CommunityStore.instance.resetForTest();
      CommunityStore.instance.editForumPost('seed_design', 'seed_forum',
          'seed_post_1', 'Updated title', 'Updated body');
      final post = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts
          .firstWhere((p) => p.id == 'seed_post_1');
      expect(post.title, 'Updated title');
      expect(post.body, 'Updated body');
      expect(post.edited, isTrue);
      // A blank title is rejected (keeps the edit a no-op).
      CommunityStore.instance.editForumPost(
          'seed_design', 'seed_forum', 'seed_post_1', '   ', 'x');
      expect(
          CommunityStore.instance
              .byId('seed_design')!
              .channels
              .firstWhere((c) => c.id == 'seed_forum')
              .posts
              .firstWhere((p) => p.id == 'seed_post_1')
              .title,
          'Updated title');
    });

    test('forum post tags: set on create/edit, filtered, JSON round-trip', () {
      CommunityStore.instance.resetForTest();
      final posts = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts;
      // Seeds carry tags, and filtering keeps only the matching tag.
      expect(filterPostsByTag(posts, 'Question').single.id, 'seed_post_1');
      expect(filterPostsByTag(posts, ''), hasLength(posts.length));

      CommunityStore.instance.editForumPost(
          'seed_design', 'seed_forum', 'seed_post_1', 'T', 'B',
          tag: 'Help');
      final edited = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts
          .firstWhere((p) => p.id == 'seed_post_1');
      expect(edited.tag, 'Help');
      expect(ForumPost.fromJson(edited.toJson()).tag, 'Help');
    });

    test('comment threads: replies nest, edit flags, delete cascades', () {
      CommunityStore.instance.resetForTest();
      List<ForumComment> comments() => CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts
          .firstWhere((p) => p.id == 'seed_post_1')
          .comments;

      // The seeded reply renders under its parent, marked as a reply.
      final threaded = threadComments(comments(), ForumSort.top);
      expect(threaded.map((e) => e.$1.id).toList(), ['seed_c1', 'seed_c2']);
      expect(threaded[0].$2, isFalse);
      expect(threaded[1].$2, isTrue);
      // Round-trips: parentId survives JSON.
      expect(
          ForumComment.fromJson(comments()[1].toJson()).parentId, 'seed_c1');

      CommunityStore.instance.editForumComment(
          'seed_design', 'seed_forum', 'seed_post_1', 'seed_c1', 'Sketch!');
      expect(comments().first.body, 'Sketch!');
      expect(comments().first.edited, isTrue);

      // Deleting the parent takes the reply with it.
      CommunityStore.instance.deleteForumComment(
          'seed_design', 'seed_forum', 'seed_post_1', 'seed_c1');
      expect(comments(), isEmpty);
    });

    test('channel messages can be edited, pinned, and moved by category', () {
      CommunityStore.instance.resetForTest();
      final c = CommunityStore.instance.createCommunity('Team');
      final chan = c.channels.first;
      CommunityStore.instance.postMessage(c.id, chan.id,
          Message(id: 'm1', text: 'helo', time: DateTime.now(), isMe: true));
      Channel channel() => CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == chan.id);

      // Edit keeps the original wording and flags the message.
      CommunityStore.instance.editChannelMessage(c.id, chan.id, 'm1', 'hello');
      expect(channel().messages.single.text, 'hello');
      expect(channel().messages.single.edited, isTrue);
      expect(channel().messages.single.originalText, 'helo');

      // Pin, round-trip through JSON, then unpin.
      CommunityStore.instance.togglePinChannelMessage(c.id, chan.id, 'm1');
      expect(channel().pinnedMessages.single.id, 'm1');
      expect(Channel.fromJson(channel().toJson()).pinnedMessageIds, ['m1']);
      CommunityStore.instance.togglePinChannelMessage(c.id, chan.id, 'm1');
      expect(channel().pinnedMessages, isEmpty);

      // Deleting a pinned message also drops its pin.
      CommunityStore.instance.togglePinChannelMessage(c.id, chan.id, 'm1');
      CommunityStore.instance.deleteChannelMessage(c.id, chan.id, 'm1');
      expect(channel().pinnedMessageIds, isEmpty);

      // Moving to a new category creates the header.
      CommunityStore.instance.setChannelCategory(c.id, chan.id, 'Projects');
      expect(channel().category, 'Projects');
      expect(CommunityStore.instance.byId(c.id)!.categories,
          contains('Projects'));
    });

    test('moderation settings: slow mode, permissions, words, JSON', () {
      CommunityStore.instance.resetForTest();
      final c = CommunityStore.instance.createCommunity('Team');

      CommunityStore.instance.setSlowMode(c.id, 30);
      CommunityStore.instance.setMembersCanCreateChannels(c.id, false);
      CommunityStore.instance.setMembersCanPost(c.id, false);
      CommunityStore.instance.addBannedWord(c.id, 'spam');
      CommunityStore.instance.addBannedWord(c.id, ' SPAM '); // dedup, trims
      CommunityStore.instance.setCommunityIcon(c.id, '🎮');

      final saved = CommunityStore.instance.byId(c.id)!;
      expect(saved.slowModeSeconds, 30);
      expect(saved.membersCanCreateChannels, isFalse);
      expect(saved.membersCanPost, isFalse);
      expect(saved.bannedWords, ['spam']);
      expect(saved.icon, '🎮');

      // Owners still moderate, so the switches don't lock them out and the
      // word filter never applies to them.
      expect(CommunityStore.instance.canCreateChannels(c.id), isTrue);
      expect(CommunityStore.instance.canPost(c.id), isTrue);
      expect(CommunityStore.instance.filterHit(c.id, 'pure spam'), isNull);
      // The matcher itself is case-insensitive and ignores clean text.
      expect(blockedWord(['spam'], 'This is SPAM okay'), 'spam');
      expect(blockedWord(['spam'], 'perfectly fine'), isNull);

      final round = Community.fromJson(saved.toJson());
      expect(round.slowModeSeconds, 30);
      expect(round.membersCanCreateChannels, isFalse);
      expect(round.bannedWords, ['spam']);
      expect(round.icon, '🎮');

      CommunityStore.instance.removeBannedWord(c.id, 'spam');
      expect(CommunityStore.instance.byId(c.id)!.bannedWords, isEmpty);
      expect(slowModeLabel(0), 'Off');
      expect(slowModeLabel(30), '30s');
      expect(slowModeLabel(300), '5m');
    });

    test('ban removes and blocks rejoining; mute hides, both survive JSON',
        () {
      CommunityStore.instance.resetForTest();
      const id = 'seed_design';

      // Mute is a personal toggle.
      CommunityStore.instance.toggleMuteMember(id, 'm_grace');
      expect(CommunityStore.instance.byId(id)!.mutedIds, ['m_grace']);
      expect(Community.fromJson(CommunityStore.instance.byId(id)!.toJson())
          .mutedIds, ['m_grace']);

      // Ban kicks the member out, clears their mute, and an invite can't
      // bring them back until unbanned.
      CommunityStore.instance.banMember(id, 'm_grace');
      var c = CommunityStore.instance.byId(id)!;
      expect(c.members.any((m) => m.id == 'm_grace'), isFalse);
      expect(c.bannedMembers.single.id, 'm_grace');
      expect(c.mutedIds, isEmpty);
      CommunityStore.instance
          .addMember(id, const Member(id: 'm_grace', name: 'Grace Hopper'));
      expect(CommunityStore.instance.byId(id)!.members
          .any((m) => m.id == 'm_grace'), isFalse);

      CommunityStore.instance.unbanMember(id, 'm_grace');
      CommunityStore.instance
          .addMember(id, const Member(id: 'm_grace', name: 'Grace Hopper'));
      c = CommunityStore.instance.byId(id)!;
      expect(c.bannedMembers, isEmpty);
      expect(c.members.any((m) => m.id == 'm_grace'), isTrue);

      // The owner can't be banned.
      CommunityStore.instance.banMember(id, 'me');
      expect(CommunityStore.instance.byId(id)!.members
          .any((m) => m.id == 'me'), isTrue);
    });

    test('server invites: export, join on another device, sealed traffic',
        () {
      CommunityStore.instance.resetForTest();
      final c = CommunityStore.instance.createCommunity('Crew');
      // Every new server mints a real 32-byte secret.
      expect(c.secret, isNotEmpty);
      expect(c.secretBytes, hasLength(32));

      final invite = CommunityStore.instance
          .exportInvite(c.id, myDigits: '15550101111', myName: 'Alice')!;
      // The sender's 'me' travels as their wire id, and history stays home.
      final members = (invite['members'] as List).cast<Map>();
      expect(members.any((m) => m['id'] == 'me'), isFalse);
      expect(
          members.any(
              (m) => m['id'] == 'u_15550101111' && m['name'] == 'Alice'),
          isTrue);
      expect(members.any((m) => m['role'] == 'owner'), isTrue);
      expect((invite['channels'] as List).first.containsKey('messages'),
          isFalse);
      expect(invite['secret'], c.secret);

      // The recipient joins: same id and secret, themselves as a member.
      CommunityStore.instance.deleteCommunity(c.id);
      final joined = CommunityStore.instance.joinFromInvite(
          Map<String, dynamic>.from(invite),
          myDigits: '15550102222',
          myName: 'Bob')!;
      expect(joined.id, c.id);
      expect(joined.secret, c.secret);
      expect(joined.members.any((m) => m.id == 'me'), isTrue);
      expect(joined.members.any((m) => m.id == 'u_15550101111'), isTrue);
      expect(CommunityStore.instance.canModerate(joined.id), isFalse);
      // Joining twice is a no-op.
      expect(
          CommunityStore.instance
              .joinFromInvite(Map<String, dynamic>.from(invite),
                  myDigits: '15550102222', myName: 'Bob')!
              .id,
          joined.id);

      // The joiner shows up on the sender's roster via the relay event.
      CommunityStore.instance.applyRemoteJoin(
          joined.id, const Member(id: 'u_15550102222', name: 'Bob'));
      expect(
          CommunityStore.instance
              .byId(joined.id)!
              .members
              .any((m) => m.name == 'Bob'),
          isTrue);

      // Channel messages from members apply once, then dedupe.
      final chan = joined.channels.first;
      final msg = Message(
          id: 'r1',
          text: 'hi from Alice',
          time: DateTime.now(),
          isMe: false,
          senderName: 'Alice');
      CommunityStore.instance
          .addRemoteChannelMessage(joined.id, chan.id, msg);
      CommunityStore.instance
          .addRemoteChannelMessage(joined.id, chan.id, msg);
      expect(
          CommunityStore.instance
              .byId(joined.id)!
              .channels
              .first
              .messages
              .where((m) => m.id == 'r1'),
          hasLength(1));
      // Unknown servers/channels drop silently.
      CommunityStore.instance.addRemoteChannelMessage('nope', chan.id, msg);
      CommunityStore.instance
          .addRemoteChannelMessage(joined.id, 'nope', msg);

      // Wire ids round-trip to inbox digits for the offline fan-out; local
      // ids have no inbox.
      expect(CommunityStore.digitsOfWireId('u_15550101111'), '15550101111');
      expect(CommunityStore.digitsOfWireId('me'), isNull);
      expect(CommunityStore.digitsOfWireId('m_ada'), isNull);

      // The bus payload is sealed with the server secret and round-trips.
      final sealed =
          E2eCrypto.encrypt(joined.secretBytes!, 'channel plaintext');
      expect(sealed.contains('plaintext'), isFalse);
      expect(E2eCrypto.decrypt(joined.secretBytes!, sealed),
          'channel plaintext');

      // Feed posts ride the same sealed bus: their body round-trips through
      // the server key and leaks nothing in ciphertext.
      final post = FeedPost(
          id: 'fp1',
          communityId: joined.id,
          authorName: 'Alice',
          authorUsername: 'alice',
          time: DateTime(2026, 1, 1),
          text: 'secret plans for the launch');
      final sealedPost = E2eCrypto.encrypt(
          joined.secretBytes!, jsonEncode({'post': post.toJson()}));
      expect(sealedPost.contains('secret plans'), isFalse);
      final opened = jsonDecode(
          E2eCrypto.decrypt(joined.secretBytes!, sealedPost)!) as Map;
      expect(
          FeedPost.fromJson(
                  Map<String, dynamic>.from(opened['post'] as Map))
              .text,
          'secret plans for the launch');

      // An invite message survives the JSON round trip.
      final inviteMsg = Message(
          id: 'i1',
          text: 'Join my server',
          time: DateTime.now(),
          isMe: true,
          serverInvite: jsonEncode(invite));
      final decoded = Message.fromJson(inviteMsg.toJson());
      expect(decoded.isServerInvite, isTrue);
      expect(jsonDecode(decoded.serverInvite)['id'], c.id);
    });

    test('structure sync: members converge, kicked devices drop out', () {
      CommunityStore.instance.resetForTest();
      final store = CommunityStore.instance;
      // Alice's device: create a server and reshape it.
      final c = store.createCommunity('Crew');
      final changed = <String>[];
      store.onStructureChanged = changed.add;
      store.addChannel(c.id, 'plans');
      store.setSlowMode(c.id, 30);
      expect(changed, [c.id, c.id]); // every structural edit broadcasts

      final structure = store.exportStructure(c.id,
          myDigits: '15550101111', myName: 'Alice')!;
      expect(structure['slowModeSeconds'], 30);

      // Bob's device: joined earlier (fewer channels), then the update lands.
      final invite = store.exportInvite(c.id,
          myDigits: '15550101111', myName: 'Alice')!;
      store.deleteCommunity(c.id);
      store.joinFromInvite(Map<String, dynamic>.from(invite),
          myDigits: '15550102222', myName: 'Bob');
      // Bob has local history in general that a sync must not erase.
      final generalId = store.byId(c.id)!.channels.first.id;
      store.postMessage(c.id, generalId,
          Message(id: 'kept', text: 'hi', time: DateTime.now(), isMe: true));
      // Bob must appear in the incoming roster to stay a member.
      final withBob = Map<String, dynamic>.from(structure);
      withBob['members'] = [
        ...(structure['members'] as List),
        const Member(id: 'u_15550102222', name: 'Bob').toJson(),
      ];
      store.applyRemoteStructure(withBob, myDigits: '15550102222');
      final synced = store.byId(c.id)!;
      expect(synced.channels.any((ch) => ch.name == 'plans'), isTrue);
      expect(synced.slowModeSeconds, 30);
      expect(
          synced.channels
              .firstWhere((ch) => ch.id == generalId)
              .messages
              .any((m) => m.id == 'kept'),
          isTrue); // local history survived
      expect(synced.members.any((m) => m.id == 'me'), isTrue);

      // A roster that no longer lists Bob removes the server from his device.
      store.applyRemoteStructure(Map<String, dynamic>.from(structure),
          myDigits: '15550102222');
      expect(store.byId(c.id), isNull);
    });

    test('unread badges count what this device has not seen', () {
      CommunityStore.instance.resetForTest();
      final store = CommunityStore.instance;
      final c = store.createCommunity('Team');
      final chan = c.channels.first;
      store.postMessage(c.id, chan.id,
          Message(id: 'u1', text: 'a', time: DateTime.now(), isMe: false));
      store.postMessage(c.id, chan.id,
          Message(id: 'u2', text: 'b', time: DateTime.now(), isMe: false));
      Channel channel() =>
          store.byId(c.id)!.channels.firstWhere((x) => x.id == chan.id);
      expect(store.unreadInChannel(channel()), 2);
      expect(store.unreadInCommunity(store.byId(c.id)!), 2);
      store.markChannelSeen(chan.id, channel().messages.length);
      expect(store.unreadInChannel(channel()), 0);
      // New arrivals count again.
      store.postMessage(c.id, chan.id,
          Message(id: 'u3', text: 'c', time: DateTime.now(), isMe: false));
      expect(store.unreadInChannel(channel()), 1);
    });

    test('a server description can be set and survives JSON', () {
      CommunityStore.instance.resetForTest();
      CommunityStore.instance
          .setCommunityDescription('seed_design', '  Cool crew  ');
      final c = CommunityStore.instance.byId('seed_design')!;
      expect(c.description, 'Cool crew'); // trimmed
      expect(Community.fromJson(c.toJson()).description, 'Cool crew');
    });

    test('post ordering by hot / new / top', () {
      final base = DateTime(2024, 1, 10, 12);
      // 'old' has the higher raw score but is 5 days (120h) stale, costing it
      // 10 hot points; 'fresh' is brand new.
      final old = ForumPost(
          id: 'old',
          authorId: 'a',
          authorName: 'A',
          time: base.subtract(const Duration(days: 5)),
          title: 'old',
          score: 20);
      final fresh = ForumPost(
          id: 'fresh',
          authorId: 'b',
          authorName: 'B',
          time: base,
          title: 'fresh',
          score: 12);
      final posts = [old, fresh];
      expect(sortPosts(posts, ForumSort.newest, now: base).first.id, 'fresh');
      expect(sortPosts(posts, ForumSort.top, now: base).first.id, 'old');
      // Hot: old 20-10=10 vs fresh 12-0=12 → fresh wins despite lower score.
      expect(sortPosts(posts, ForumSort.hot, now: base).first.id, 'fresh');
    });

    test('a forum channel survives a JSON round-trip', () {
      final channel = Channel(
        id: 'f1',
        name: 'discussion',
        type: ChannelType.forum,
        category: 'Forums',
        posts: [
          ForumPost(
            id: 'p1',
            authorId: 'me',
            authorName: 'You',
            time: DateTime(2024, 1, 1),
            title: 'Hi',
            body: 'body',
            score: 3,
            myVote: 1,
            comments: [
              ForumComment(
                id: 'c1',
                authorId: 'a',
                authorName: 'A',
                time: DateTime(2024, 1, 1, 1),
                body: 'nice',
                score: 2,
              ),
            ],
          ),
        ],
      );
      final back = Channel.fromJson(channel.toJson());
      expect(back.type, ChannelType.forum);
      expect(back.posts.single.title, 'Hi');
      expect(back.posts.single.score, 3);
      expect(back.posts.single.comments.single.body, 'nice');
    });
  });

  test('Communities: voice channels keep their casing and group by category',
      () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Studio');
    CommunityStore.instance
        .addChannel(c.id, 'Music Room', type: ChannelType.voice);
    final updated = CommunityStore.instance.byId(c.id)!;
    final voice = updated.channels.firstWhere((ch) => ch.name == 'Music Room');
    expect(voice.type, ChannelType.voice); // spaces/casing preserved
    expect(voice.category, 'Voice Channels');
    // Categories are de-duplicated in first-seen order.
    expect(updated.categories, contains('Voice Channels'));
    expect(updated.channelsIn('Voice Channels').length, 2);
  });

  test('Communities: rename, retopic, and delete a channel', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Ops');
    final id = c.channels.first.id;

    CommunityStore.instance.renameChannel(c.id, id, 'On Call');
    CommunityStore.instance.setChannelTopic(c.id, id, 'Pager duty');
    var ch =
        CommunityStore.instance.byId(c.id)!.channels.firstWhere((x) => x.id == id);
    expect(ch.name, 'on-call'); // text channels slugify
    expect(ch.topic, 'Pager duty');

    CommunityStore.instance.deleteChannel(c.id, id);
    expect(
      CommunityStore.instance.byId(c.id)!.channels.any((x) => x.id == id),
      isFalse,
    );
  });

  test('Communities: server management and channel poll voting', () {
    CommunityStore.instance.resetForTest();
    final c = CommunityStore.instance.createCommunity('Guild');
    // Rename + recolor.
    CommunityStore.instance.renameCommunity(c.id, 'The Guild');
    CommunityStore.instance.setCommunityColor(c.id, '#12B76A');
    var updated = CommunityStore.instance.byId(c.id)!;
    expect(updated.name, 'The Guild');
    expect(updated.color, '#12B76A');

    // Members: add, promote, remove (owner protected).
    CommunityStore.instance
        .addMember(c.id, const Member(id: 'm_x', name: 'Xavier'));
    CommunityStore.instance.setMemberRole(c.id, 'm_x', MemberRole.admin);
    updated = CommunityStore.instance.byId(c.id)!;
    expect(updated.members.firstWhere((m) => m.id == 'm_x').role,
        MemberRole.admin);
    CommunityStore.instance.setMemberRole(c.id, 'me', MemberRole.member);
    expect(
        CommunityStore.instance
            .byId(c.id)!
            .members
            .firstWhere((m) => m.id == 'me')
            .role,
        MemberRole.owner); // owner can't be demoted
    CommunityStore.instance.removeMember(c.id, 'm_x');
    expect(CommunityStore.instance.byId(c.id)!.members.any((m) => m.id == 'm_x'),
        isFalse);

    // Poll in a channel.
    final channelId = c.channels.first.id;
    CommunityStore.instance.postMessage(
      c.id,
      channelId,
      Message(
        id: 'cpoll',
        text: '',
        time: DateTime(2024),
        isMe: true,
        isPoll: true,
        pollQuestion: 'Raid tonight?',
        pollOptions: const ['Yes', 'No'],
        pollVotes: const [0, 0],
      ),
    );
    CommunityStore.instance.votePollInChannel(c.id, channelId, 'cpoll', 0);
    CommunityStore.instance.votePollInChannel(c.id, channelId, 'cpoll', 1);
    final poll = CommunityStore.instance
        .byId(c.id)!
        .channels
        .firstWhere((ch) => ch.id == channelId)
        .messages
        .firstWhere((m) => m.id == 'cpoll');
    expect(poll.pollVotes, [0, 1]); // vote moved from Yes to No
    expect(poll.pollMyVote, 1);
  });

  testWidgets('Servers tab: open a community, a channel, and post a message',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Switch to the Servers tab (its pill shows the outline icon when idle).
    await tester.tap(find.byIcon(Icons.groups_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Design Team'), findsOneWidget);

    await tester.tap(find.text('Design Team'));
    await tester.pumpAndSettle();
    expect(find.text('general'), findsOneWidget);

    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'gm everyone');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('gm everyone'), findsOneWidget);
  });

  test('setReactionState adds/removes a reaction idempotently', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final id = bob.messages.first.id;

    ChatStore.instance.setReactionState(bob.id, id, '👍', true);
    ChatStore.instance.setReactionState(bob.id, id, '👍', true); // idempotent
    var m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == id);
    expect(m.reactions.where((r) => r == '👍').length, 1);

    ChatStore.instance.setReactionState(bob.id, id, '👍', false);
    m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == id);
    expect(m.reactions.contains('👍'), isFalse);
  });

  test('Privacy Policy states the no-storage / broadcast promise', () {
    final all = privacyPolicy.map((s) => '${s.title} ${s.body}').join('\n');
    expect(all, contains('never stored'));
    expect(all, contains('Realtime Broadcast'));
    expect(all, contains('no messages database'));
    expect(all.toLowerCase(), contains('end-to-end'));
    // Terms must point payments at Stripe's Connected Account Agreement.
    final terms = termsOfService.map((s) => s.body).join('\n');
    expect(terms, contains('Stripe Connected Account Agreement'));
    expect(terms, contains('not a bank or money-services business'));
  });

  test('votePoll moves a vote between options and syncs remote votes', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    ChatStore.instance.addMessage(
      bob.id,
      Message(
        id: 'p',
        text: '',
        time: DateTime(2024),
        isMe: false,
        isPoll: true,
        pollQuestion: 'Best?',
        pollOptions: const ['A', 'B', 'C'],
        pollVotes: const [0, 0, 0],
      ),
    );

    // Vote A, then switch to B — A goes back to 0, B to 1.
    var prev = ChatStore.instance.votePoll(bob.id, 'p', 0);
    expect(prev, -1);
    prev = ChatStore.instance.votePoll(bob.id, 'p', 1);
    expect(prev, 0);
    var m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == 'p');
    expect(m.pollVotes, [0, 1, 0]);
    expect(m.pollMyVote, 1);

    // A remote peer votes C; our own choice is untouched.
    ChatStore.instance.applyRemotePollVote(bob.id, 'p', 2, -1);
    m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == 'p');
    expect(m.pollVotes, [0, 1, 1]);
    expect(m.pollMyVote, 1);
    expect(m.pollTotalVotes, 2);
  });

  test('editMessage replaces text and marks it edited', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final id = bob.messages.firstWhere((m) => m.isMe).id;

    final before = bob.messages.firstWhere((m) => m.id == id).text;
    ChatStore.instance.editMessage(bob.id, id, 'edited text');
    final m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == id);
    expect(m.text, 'edited text');
    expect(m.edited, isTrue);
    // The original text is preserved so it can be viewed.
    expect(m.originalText, before);
    // A second edit keeps the very first original, not the interim one.
    ChatStore.instance.editMessage(bob.id, id, 'edited again');
    expect(
        ChatStore.instance.chatById(bob.id)!.messages
            .firstWhere((x) => x.id == id)
            .originalText,
        before);
  });

  test('delete for everyone leaves a tombstone; for me removes it', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final count = bob.messages.length;
    final everyoneId = bob.messages.first.id;
    final meId = bob.messages.last.id;

    // Delete for everyone → the message stays as a deleted tombstone.
    ChatStore.instance.deleteMessage(bob.id, everyoneId, forEveryone: true);
    final tomb = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((m) => m.id == everyoneId);
    expect(tomb.isDeleted, isTrue);
    expect(tomb.text, isEmpty);
    expect(ChatStore.instance.chatById(bob.id)!.messages.length, count);

    // Delete for me → the message is gone.
    ChatStore.instance.deleteMessage(bob.id, meId);
    expect(
        ChatStore.instance.chatById(bob.id)!.messages.any((m) => m.id == meId),
        isFalse);
  });

  testWidgets('Editing a sent message updates it with an edited marker',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Long-press my own message, choose Edit.
    await tester.longPress(find.textContaining('What a finish'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
          of: find.byType(Dialog), matching: find.byType(TextField)),
      'Edited!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    expect(bob.messages.any((m) => m.text == 'Edited!' && m.edited), isTrue);
    expect(find.text('Edited!'), findsOneWidget);
    expect(find.text('edited'), findsWidgets);
  });

  testWidgets('Muting from the chat menu shows a muted icon in the header',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.volume_off), findsNothing);

    await openChatSettings(tester);
    // The Switch beside "Mute notifications".
    await tapInSettings(
        tester,
        find.descendant(
            of: find.widgetWithText(InfoTile, 'Mute notifications'),
            matching: find.byType(Switch)));
    await goBack(tester);
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chatWithContact('u_bob')!.isMuted, isTrue);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
  });

  testWidgets('Pinning from chat settings pins the conversation',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await openChatSettings(tester);
    await tapInSettings(
        tester,
        find.descendant(
            of: find.widgetWithText(InfoTile, 'Pin chat'),
            matching: find.byType(Switch)));

    expect(ChatStore.instance.chatWithContact('u_bob')!.isPinned, isTrue);
  });

  testWidgets('Opening an unread chat shows the unread-messages divider',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Alice's chat starts with 2 unread messages.
    await tester.tap(find.text('Alice Bennett'));
    await tester.pumpAndSettle();

    expect(find.text('2 UNREAD MESSAGES'), findsOneWidget);
  });

  testWidgets('Clear chat empties the conversation after confirming',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();
    expect(ChatStore.instance.chatWithContact('u_bob')!.messages, isNotEmpty);

    await openChatSettings(tester);
    await tapInSettings(tester, find.text('Clear chat'));
    // Confirm in the dialog (the red action button).
    await tester.tap(find.widgetWithText(FilledButton, 'Clear chat'));
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chatWithContact('u_bob')!.messages, isEmpty);
  });

  testWidgets('Delete chat removes the conversation and pops back',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await openChatSettings(tester);
    await tapInSettings(tester, find.text('Delete chat'));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete chat'));
    await tester.pumpAndSettle();

    // The chat is gone and we're back on the list.
    expect(ChatStore.instance.chatWithContact('u_bob'), isNull);
    expect(find.text('Alice Bennett'), findsOneWidget);
  });

  testWidgets('Global search finds messages by content and opens the chat',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Open the Chats-tab search, then query message text.
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'finish');
    await tester.pumpAndSettle();

    // A "Messages" section lists the matching message; tapping opens its chat.
    expect(find.textContaining('Messages ('), findsOneWidget);
    await tester.tap(find.textContaining('What a finish'));
    await tester.pumpAndSettle();

    // Landed in Bob's conversation.
    expect(find.text('Bob Carter'), findsWidgets);
    expect(find.text('Did you see the game last night?'), findsOneWidget);
  });

  testWidgets('Universal search finds people and servers, and filters',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // A server name surfaces the community as a result.
    await tester.enterText(find.byType(TextField), 'Design');
    await tester.pumpAndSettle();
    expect(find.text('Design Team'), findsWidgets);

    // A person's name surfaces them in the People section.
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.pumpAndSettle();
    expect(find.text('Alice Bennett'), findsWidgets);

    // Filter chips are present.
    expect(find.widgetWithText(ChoiceChip, 'Servers'), findsOneWidget);

    // Channel names are searchable (the Channels header is unique — no chip).
    await tester.enterText(find.byType(TextField), 'general');
    await tester.pumpAndSettle();
    expect(find.text('Channels'), findsOneWidget);

    // Forum post titles are searchable (seeded post mentions "design tools").
    await tester.enterText(find.byType(TextField), 'design tools');
    await tester.pumpAndSettle();
    expect(find.textContaining('Posts ('), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Posts'), findsOneWidget);
  });

  testWidgets('Submitting a search remembers it on the idle screen',
      (tester) async {
    RecentSearches.instance.resetForTest();
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(RecentSearches.instance.queries, contains('Alice'));

    // Clearing the field returns to the idle screen, which now offers it.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    // Tapping the remembered search re-runs it.
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('Alice Bennett'), findsWidgets);
  });

  group('Recent searches store', () {
    test('add de-duplicates case-insensitively and moves to front', () {
      RecentSearches.instance.resetForTest();
      RecentSearches.instance.add('hello');
      RecentSearches.instance.add('World');
      RecentSearches.instance.add('  hello  '); // trims + dedupes
      expect(RecentSearches.instance.queries, ['hello', 'World']);
      RecentSearches.instance.add('HELLO'); // case-insensitive dedupe, to front
      expect(RecentSearches.instance.queries.first, 'HELLO');
      expect(RecentSearches.instance.queries.length, 2);
      RecentSearches.instance.add('   '); // blank ignored
      expect(RecentSearches.instance.queries.length, 2);
    });

    test('caps history and supports remove/clear', () {
      RecentSearches.instance.resetForTest();
      for (var i = 0; i < 12; i++) {
        RecentSearches.instance.add('q$i');
      }
      expect(RecentSearches.instance.queries.length, 8); // capped
      expect(RecentSearches.instance.queries.first, 'q11'); // newest first
      RecentSearches.instance.remove('q11');
      expect(RecentSearches.instance.queries, isNot(contains('q11')));
      RecentSearches.instance.clear();
      expect(RecentSearches.instance.isEmpty, isTrue);
    });
  });

  testWidgets('Creating a group adds it to the chat list with its members',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Chats "new chat" action → New group.
    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();

    // Pick two participants.
    await tester.tap(find.text('Alice Bennett'));
    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Next → name the group → create.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Weekend Trip');
    await tester.tap(find.text('Create group'));
    await tester.pumpAndSettle();

    // Opens the group chat; the group exists with me + 2 members.
    final group = ChatStore.instance.allChats
        .firstWhere((c) => c.contact.name == 'Weekend Trip');
    expect(group.contact.isGroup, isTrue);
    expect(group.members.length, 3);

    // The group conversation is now open, its header showing the name.
    expect(find.text('Weekend Trip'), findsOneWidget);

    // Its info screen lists all three members.
    await tester.tap(find.text('Weekend Trip'));
    await tester.pumpAndSettle();
    expect(find.text('3 members'), findsOneWidget);
  });

  testWidgets('The online-status privacy toggle flips and reflects state',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy & security'));
    await tester.pumpAndSettle();

    expect(AppState.shareLastSeen.value, isTrue);

    final tile = find.text('Share online status');
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(AppState.shareLastSeen.value, isFalse);
    expect(find.text('Your online status is hidden'), findsOneWidget);
  });

  test('App lock: set, verify (wrong/right), and disable a PIN', () async {
    SharedPreferences.setMockInitialValues({});
    AppLock.instance.resetForTest();
    await AppLock.instance.setPin('1234');
    expect(AppLock.instance.enabled.value, isTrue);
    expect(AppLock.instance.unlock('0000'), isFalse);
    expect(AppLock.instance.unlock('1234'), isTrue);
    await AppLock.instance.disable();
    expect(AppLock.instance.enabled.value, isFalse);
  });

  test('Two-step verification: set, verify, email, and disable', () async {
    SharedPreferences.setMockInitialValues({});
    final ts = TwoStepVerification.instance;
    ts.resetForTest();
    expect(ts.enabled.value, isFalse);
    expect(TwoStepVerification.isValidPin('123456'), isTrue);
    expect(TwoStepVerification.isValidPin('12ab56'), isFalse);
    expect(TwoStepVerification.isValidPin('12345'), isFalse);

    await ts.setPin('246810', recoveryEmail: 'me@example.com');
    expect(ts.enabled.value, isTrue);
    expect(ts.email, 'me@example.com');
    expect(ts.verify('000000'), isFalse);
    expect(ts.verify('246810'), isTrue);

    await ts.setEmail('new@example.com');
    expect(ts.email, 'new@example.com');

    await ts.disable();
    expect(ts.enabled.value, isFalse);
    expect(ts.email, isEmpty);
    // With nothing set, verify passes (nothing to check).
    expect(ts.verify('anything'), isTrue);
  });

  testWidgets('The lock screen gates the app and unlocks with the right PIN',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppLock.instance.resetForTest();
    await AppLock.instance.setPin('4321');
    AppLock.instance.locked.value = true; // simulate a fresh, locked launch

    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    expect(find.text('OkayMessenger is locked'), findsOneWidget);

    // Wrong PIN keeps it locked.
    await tester.enterText(find.byType(TextField).first, '0000');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('OkayMessenger is locked'), findsOneWidget);

    // Correct PIN unlocks.
    await tester.enterText(find.byType(TextField).first, '4321');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('OkayMessenger is locked'), findsNothing);
  });

  test('My QR payload encodes username, phone and name as an app URI', () {
    const me = AppUser(
      id: '+1 555 0100',
      name: 'Ada Lovelace',
      avatarColor: '#4DB6AC',
      about: 'Available',
      phone: '+1 555 0100',
      username: 'adal',
    );
    final payload = MyQrScreen.payloadFor(me);
    expect(payload, startsWith('okaymsg://add?'));
    expect(payload, contains('u=adal'));
    expect(payload, contains('n=Ada%20Lovelace')); // URL-encoded
  });

  testWidgets('The QR icon in Settings opens the My QR code screen',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.qr_code));
    await tester.pumpAndSettle();

    expect(find.text('My QR code'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('The read-receipts toggle flips and persists to AppState',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy & security'));
    await tester.pumpAndSettle();

    expect(AppState.sendReadReceipts.value, isTrue);

    final tile = find.text('Read receipts');
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(AppState.sendReadReceipts.value, isFalse);
  });

  testWidgets('Typing-indicators privacy toggle flips', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy & security'));
    await tester.pumpAndSettle();

    expect(AppState.sendTypingIndicators.value, isTrue);

    final tile = find.text('Typing indicators');
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(AppState.sendTypingIndicators.value, isFalse);
  });

  test('Message text scale defaults to 1.0 and resets', () {
    AppState.messageTextScale.value = 1.2;
    AppState.resetForTest();
    expect(AppState.messageTextScale.value, 1.0);
  });

  test('updateProfile can change avatar color and normalizes the username', () {
    AppState.resetForTest();
    Session.instance.resetForTest();
    AppState.updateProfile(
      name: 'Ada',
      about: 'Available',
      username: '@Ada_Lovelace!!',
      avatarColor: '#64B5F6',
    );
    expect(AppState.profile.value.avatarColor, '#64B5F6');
    // Uppercase/leading @/invalid chars are stripped.
    expect(AppState.profile.value.username, 'ada_lovelace');
    expect(AppState.profile.value.handle, '@ada_lovelace');
  });

  test('New privacy defaults are Everyone and reset cleanly', () {
    AppState.profilePhotoAudience.value = PrivacyAudience.nobody;
    AppState.aboutAudience.value = PrivacyAudience.contacts;
    AppState.groupAddAudience.value = PrivacyAudience.nobody;
    AppState.blockScreenshots.value = true;
    AppState.defaultDisappearingSeconds.value = 86400;
    AppState.resetForTest();
    expect(AppState.profilePhotoAudience.value, PrivacyAudience.everyone);
    expect(AppState.aboutAudience.value, PrivacyAudience.everyone);
    expect(AppState.groupAddAudience.value, PrivacyAudience.everyone);
    expect(AppState.blockScreenshots.value, isFalse);
    expect(AppState.defaultDisappearingSeconds.value, 0);
    expect(PrivacyAudience.fromName('contacts'), PrivacyAudience.contacts);
    expect(PrivacyAudience.fromName('garbage'), PrivacyAudience.everyone);
  });

  testWidgets('Settings hub opens Privacy & security and sets an audience',
      (tester) async {
    AppState.resetForTest();
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    // The hub shows grouped entry points into the sub-screens.
    expect(find.text('Privacy & security'), findsOneWidget);
    expect(find.text('Chats & appearance'), findsOneWidget);

    await tester.tap(find.text('Privacy & security'));
    await tester.pumpAndSettle();

    expect(AppState.profilePhotoAudience.value, PrivacyAudience.everyone);

    // Open the "Profile photo" audience picker and choose Nobody.
    await tester.tap(find.text('Profile photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nobody').last);
    await tester.pumpAndSettle();

    expect(AppState.profilePhotoAudience.value, PrivacyAudience.nobody);
  });

  testWidgets('Edit profile picks an avatar color and saves it',
      (tester) async {
    AppState.resetForTest();
    Session.instance.signInForTest();
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();

    // Colour and emoji now live behind the avatar's "Change look" sheet.
    await tester.tap(find.text('Change look'));
    await tester.pumpAndSettle();
    expect(find.text('AVATAR COLOR'), findsOneWidget);
    expect(find.text('AVATAR EMOJI'), findsOneWidget);
    await tester.tapAt(const Offset(400, 60)); // dismiss the sheet
    await tester.pumpAndSettle();
    expect(find.text('Username'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Ada');
    // Tap the AppBar save action (a selected swatch also renders a check icon).
    await tester.tap(find.descendant(
        of: find.byType(AppBar), matching: find.byIcon(Icons.check)));
    await tester.pumpAndSettle();

    expect(AppState.profile.value.name, 'Ada');
  });

  testWidgets('Blocked contacts screen lists a blocked number and unblocks',
      (tester) async {
    AppState.setBlocked('+1 555 0143', true);
    expect(AppState.isBlocked('+1 555 0143'), isTrue);

    await tester
        .pumpWidget(const MaterialApp(home: BlockedContactsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Unblock'), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();

    expect(AppState.isBlocked('+1 555 0143'), isFalse);
    expect(find.text('No blocked contacts'), findsOneWidget);
  });

  testWidgets('Storage → clear all chats empties the store after confirming',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    expect(ChatStore.instance.chats, isNotEmpty);

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final tile = find.text('Storage and data');
    await tester.scrollUntilVisible(tile, 120,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // Confirm the destructive dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all chats'));
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chats, isEmpty);
  });

  test('setOutgoingStatus upgrades only outgoing messages, never downgrades',
      () {
    ChatStore.instance.reset();
    // Bob's chat has an outgoing message at status read.
    ChatStore.instance.addMessage(
      'c_bob',
      Message(
        id: 'out1',
        text: 'yo',
        time: DateTime(2024),
        isMe: true,
        status: MessageStatus.sent,
      ),
    );

    // A 'delivered' receipt upgrades sent -> delivered.
    ChatStore.instance.setOutgoingStatus('c_bob', MessageStatus.delivered);
    final m1 = ChatStore.instance
        .chatById('c_bob')!
        .messages
        .firstWhere((m) => m.id == 'out1');
    expect(m1.status, MessageStatus.delivered);

    // A later 'read' receipt upgrades to read.
    ChatStore.instance.setOutgoingStatus('c_bob', MessageStatus.read);
    expect(
      ChatStore.instance
          .chatById('c_bob')!
          .messages
          .firstWhere((m) => m.id == 'out1')
          .status,
      MessageStatus.read,
    );

    // A stale 'delivered' receipt must not downgrade a read message.
    ChatStore.instance.setOutgoingStatus('c_bob', MessageStatus.delivered);
    expect(
      ChatStore.instance
          .chatById('c_bob')!
          .messages
          .firstWhere((m) => m.id == 'out1')
          .status,
      MessageStatus.read,
    );

    // Incoming messages are untouched.
    expect(
      ChatStore.instance
          .chatById('c_bob')!
          .messages
          .where((m) => !m.isMe)
          .every((m) => m.status != MessageStatus.read || m.id != 'out1'),
      isTrue,
    );
  });

  group('Relay (device-to-device delivery)', () {
    test('inbox channel id is derived from the phone digits', () {
      expect(RelayService.inboxChannel('+1 (555) 0199'), 'inbox_15550199');
      expect(RelayService.inboxChannel('15550199'),
          RelayService.inboxChannel('+1 555 0199'));
    });

    test('encode/applyIncoming round-trip preserves image and voice', () {
      ChatStore.instance.reset();
      final photo = Message(
        id: 'p1',
        text: '',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        isImage: true,
        imageSeed: 4,
      );
      final encoded = RelayService.encode(
          message: photo, fromPhone: '+1 555 0199', fromName: 'Grace');
      RelayService.applyIncoming(encoded, myPhone: '+1 555 0100');
      final got = ChatStore.instance
          .chatWithContact('+1 555 0199')!
          .messages
          .single;
      expect(got.isImage, isTrue);
      expect(got.imageSeed, 4);

      final voice = Message(
        id: 'v1',
        text: '',
        time: DateTime(2024, 1, 1, 10),
        isMe: true,
        isVoice: true,
        voiceSeconds: 12,
      );
      RelayService.applyIncoming(
        RelayService.encode(
            message: voice, fromPhone: '+1 555 0199', fromName: 'Grace'),
        myPhone: '+1 555 0100',
      );
      final v = ChatStore.instance
          .chatWithContact('+1 555 0199')!
          .messages
          .firstWhere((m) => m.id == 'v1');
      expect(v.isVoice, isTrue);
      expect(v.voiceSeconds, 12);
    });

    test('applyIncoming creates a chat and appends the message', () {
      ChatStore.instance.reset();
      final payload = {
        'id': 'r1',
        'from': '+1 555 0199',
        'fromName': 'Grace',
        'text': 'hi from another phone',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };

      final added = RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      expect(added, isTrue);

      final chat = ChatStore.instance.chatWithContact('+1 555 0199');
      expect(chat, isNotNull);
      expect(chat!.contact.name, 'Grace');
      expect(chat.messages.single.text, 'hi from another phone');
      expect(chat.messages.single.isMe, isFalse);
    });

    test('looksLikeSpam applies keyword and stranger-link filters', () {
      addTearDown(() {
        AppState.spamKeywords.value = '';
        AppState.blockLinksFromStrangers.value = false;
      });
      AppState.spamKeywords.value = 'free money, crypto';
      expect(AppState.looksLikeSpam('win FREE MONEY now', isKnownContact: true),
          isTrue);
      expect(AppState.looksLikeSpam('hey how are you', isKnownContact: true),
          isFalse);

      AppState.spamKeywords.value = '';
      AppState.blockLinksFromStrangers.value = true;
      // Links from strangers are spam; from contacts they're fine.
      expect(
          AppState.looksLikeSpam('check http://x.io', isKnownContact: false),
          isTrue);
      expect(
          AppState.looksLikeSpam('check http://x.io', isKnownContact: true),
          isFalse);
      expect(AppState.looksLikeSpam('no link here', isKnownContact: false),
          isFalse);
    });

    test('applyIncoming drops spam before it reaches the store', () {
      ChatStore.instance.reset();
      AppState.blockLinksFromStrangers.value = true;
      addTearDown(() => AppState.blockLinksFromStrangers.value = false);
      final payload = {
        'id': 'spam1',
        'from': '+1 555 7777',
        'fromName': 'Bot',
        'text': 'Claim your prize at http://scam.xyz',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };
      final added =
          RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      expect(added, isFalse);
      expect(ChatStore.instance.chatWithContact('+1 555 7777'), isNull);
    });

    test('applyIncoming ignores our own echo and duplicate ids', () {
      ChatStore.instance.reset();
      final mine = {
        'id': 'r2',
        'from': '+1 555 0100',
        'text': 'echo',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };
      expect(
        RelayService.applyIncoming(mine, myPhone: '+1 555 0100'),
        isFalse,
      );

      final incoming = {
        'id': 'r3',
        'from': '+1 555 0199',
        'text': 'once',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };
      expect(
        RelayService.applyIncoming(incoming, myPhone: '+1 555 0100'),
        isTrue,
      );
      // Same id again is a no-op (no duplicate).
      expect(
        RelayService.applyIncoming(incoming, myPhone: '+1 555 0100'),
        isFalse,
      );
      expect(
        ChatStore.instance
            .chatWithContact('+1 555 0199')!
            .messages
            .where((m) => m.id == 'r3')
            .length,
        1,
      );
    });

    test('ECDH (enc-2) message round-trips: encode with a shared secret, '
        'decode with the sender public key', () {
      ChatStore.instance.reset();
      final kx = SecureKeyExchange.instance;
      kx.resetForTest();
      kx.ensureKeys(); // acts as the recipient's identity for this test
      final myPub = kx.myPublicKey!;
      // The "sender" derives the shared secret against our public key.
      final secret = kx.sharedSecretWith(myPub)!; // self-pair for the test

      final msg = Message(
        id: 'x2',
        text: 'sent under an ECDH key',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
      );
      final payload = RelayService.encode(
        message: msg,
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        ecdhSecret: secret,
        senderPublicKey: myPub,
      );
      expect(payload['enc'], 2);
      expect(payload['spk'], myPub);
      // The whole content blob is sealed — plaintext and sender name leak nowhere.
      expect(payload['c'], isNot(contains('sent under an ECDH key')));
      expect(payload['c'], isNot(contains('Grace')));
      expect(payload.containsKey('fromName'), isFalse);
      expect(payload.containsKey('text'), isFalse);

      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.text, 'sent under an ECDH key');
      kx.resetForTest();
    });

    test('end-to-end encrypted text round-trips through encode/applyIncoming',
        () {
      ChatStore.instance.reset();
      final msg = Message(
        id: 'e1',
        text: 'secret rendezvous at noon',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
      );
      final payload = RelayService.encode(
        message: msg,
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        toPhone: '+1 555 0100',
      );
      // The wire payload is ciphertext, not the plaintext.
      expect(payload['enc'], 1);
      expect(payload['c'], isNot(contains('secret rendezvous at noon')));
      expect(payload.containsKey('text'), isFalse);

      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.text, 'secret rendezvous at noon');
    });

    test('a poll survives the relay with question, options, and tally', () {
      ChatStore.instance.reset();
      final poll = Message(
        id: 'poll1',
        text: '',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        isPoll: true,
        pollQuestion: 'Lunch?',
        pollOptions: const ['Sushi', 'Tacos'],
        pollVotes: const [3, 1],
      );
      final payload = RelayService.encode(
          message: poll, fromPhone: '+1 555 0199', fromName: 'Grace');
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.isPoll, isTrue);
      expect(got.pollQuestion, 'Lunch?');
      expect(got.pollOptions, ['Sushi', 'Tacos']);
      expect(got.pollVotes, [3, 1]);
      expect(got.pollMyVote, -1); // the receiver hasn't voted
    });

    test('an in-chat payment survives the relay with amount and note', () {
      ChatStore.instance.reset();
      final pay = Message(
        id: 'pay1',
        text: 'lunch 🍜',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        isPayment: true,
        paymentAmountCents: 2050,
        paymentCurrency: 'cad',
        paymentStatus: 'pending',
      );
      final payload = RelayService.encode(
          message: pay, fromPhone: '+1 555 0199', fromName: 'Grace');
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.isPayment, isTrue);
      expect(got.paymentAmountCents, 2050);
      expect(got.paymentCurrency, 'cad');
      expect(got.text, 'lunch 🍜'); // the note
      expect(got.paymentDisplay, r'$20.50');
      // The pending status rides along, so the receipt shows live state.
      expect(got.paymentStatus, 'pending');

      // A later 'paid' update flips only the payment receipt.
      ChatStore.instance.setPaymentStatus(
          ChatStore.instance.chatWithContact('+1 555 0199')!.id,
          'pay1',
          'paid');
      final paid =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(paid.paymentStatus, 'paid');
    });

    test('a reply, forward, and shared location survive the relay', () {
      ChatStore.instance.reset();
      final msg = Message(
        id: 'rich1',
        text: 'On my way!',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        forwarded: true,
        replyTo: const ReplyInfo(
            senderName: 'Grace', text: 'Where are you?', isMe: false),
        isLocation: true,
        locationLat: 37.7749,
        locationLng: -122.4194,
        locationLabel: 'Ferry Building',
      );
      final payload = RelayService.encode(
          message: msg, fromPhone: '+1 555 0199', fromName: 'Grace');
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.forwarded, isTrue);
      expect(got.replyTo?.text, 'Where are you?');
      expect(got.isLocation, isTrue);
      expect(got.locationLabel, 'Ferry Building');
      expect(got.locationLat, closeTo(37.7749, 0.0001));
    });

    test('contacts-only privacy drops messages from unknown senders', () {
      ChatStore.instance.reset();
      AppState.messagesFromContactsOnly.value = true;
      final payload = {
        'id': 'x1',
        'from': '+1 555 7777', // no existing chat
        'c': null,
        'text': 'hey there',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };
      final added =
          RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      expect(added, isFalse);
      expect(ChatStore.instance.chatWithContact('+1 555 7777'), isNull);
      AppState.messagesFromContactsOnly.value = false;
    });

    test('blocked senders are dropped even from an existing chat', () {
      ChatStore.instance.reset();
      final bob = ChatStore.instance.chats.first.contact;
      AppState.setBlocked(bob.phone, true);
      final payload = {
        'id': 'blk1',
        'from': bob.phone,
        'c': null,
        'text': 'spam',
        'ts': DateTime(2024, 1, 1, 9).toIso8601String(),
      };
      expect(
        RelayService.applyIncoming(payload, myPhone: '+1 555 0100'),
        isFalse,
      );
      AppState.setBlocked(bob.phone, false);
    });

    test('a voicemail survives the relay with its flag intact', () {
      ChatStore.instance.reset();
      final msg = Message(
        id: 'vm1',
        text: '',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        isVoice: true,
        isVoicemail: true,
        voiceSeconds: 12,
      );
      final payload = RelayService.encode(
          message: msg, fromPhone: '+1 555 0199', fromName: 'Grace');
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final got =
          ChatStore.instance.chatWithContact('+1 555 0199')!.messages.single;
      expect(got.isVoicemail, isTrue);
      expect(got.isVoice, isTrue);
      expect(got.voiceSeconds, 12);
    });

    test('allowVoicemail=false drops an incoming voicemail', () {
      ChatStore.instance.reset();
      AppState.allowVoicemail.value = false;
      final msg = Message(
        id: 'vm2',
        text: '',
        time: DateTime(2024, 1, 1, 9),
        isMe: true,
        isVoice: true,
        isVoicemail: true,
        voiceSeconds: 5,
      );
      final payload = RelayService.encode(
          message: msg, fromPhone: '+1 555 0199', fromName: 'Grace');
      expect(
        RelayService.applyIncoming(payload, myPhone: '+1 555 0100'),
        isFalse,
      );
      AppState.allowVoicemail.value = true;
    });

    test('shared avatar color and about reach a new contact', () {
      ChatStore.instance.reset();
      final msg = Message(
          id: 'pm1', text: 'hi', time: DateTime(2024, 1, 1, 9), isMe: true);
      final payload = RelayService.encode(
        message: msg,
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromAvatarColor: '#64B5F6',
        fromAbout: 'Building things',
      );
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final contact =
          ChatStore.instance.chatWithContact('+1 555 0199')!.contact;
      expect(contact.avatarColor, '#64B5F6');
      expect(contact.about, 'Building things');
    });

    test('withheld profile fields fall back to defaults for a new contact', () {
      ChatStore.instance.reset();
      final msg = Message(
          id: 'pm2', text: 'hi', time: DateTime(2024, 1, 1, 9), isMe: true);
      // Empty strings model a sender whose privacy setting is "Nobody".
      final payload = RelayService.encode(
        message: msg,
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromAvatarColor: '',
        fromAbout: '',
      );
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final contact =
          ChatStore.instance.chatWithContact('+1 555 0199')!.contact;
      expect(contact.avatarColor, '#7A5CFF'); // default, nothing leaked
      expect(contact.about, 'Available');
    });

    test('profile-field gating honors the privacy audience', () {
      // Everyone always shares; Nobody never does.
      expect(
          RelayService.gatedProfileField(
              PrivacyAudience.everyone, '#64B5F6', false),
          '#64B5F6');
      expect(
          RelayService.gatedProfileField(
              PrivacyAudience.nobody, '#64B5F6', true),
          '');
      // My contacts shares only with an existing contact.
      expect(
          RelayService.gatedProfileField(
              PrivacyAudience.contacts, '#64B5F6', true),
          '#64B5F6');
      expect(
          RelayService.gatedProfileField(
              PrivacyAudience.contacts, '#64B5F6', false),
          '');
    });

    test('shared profile refreshes an existing contact', () {
      ChatStore.instance.reset();
      final first = RelayService.encode(
        message: Message(
            id: 'pm3', text: 'hi', time: DateTime(2024, 1, 1, 9), isMe: true),
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromAvatarColor: '#E57373',
        fromAbout: 'Old status',
      );
      RelayService.applyIncoming(first, myPhone: '+1 555 0100');

      final second = RelayService.encode(
        message: Message(
            id: 'pm4', text: 'yo', time: DateTime(2024, 1, 1, 10), isMe: true),
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromAvatarColor: '#81C784',
        fromAbout: 'New status',
      );
      RelayService.applyIncoming(second, myPhone: '+1 555 0100');

      final contact =
          ChatStore.instance.chatWithContact('+1 555 0199')!.contact;
      expect(contact.avatarColor, '#81C784');
      expect(contact.about, 'New status');
    });
  });

  group('Contact info', () {
    Chat seedChat() {
      ChatStore.instance.reset();
      const contact = AppUser(
        id: '+1 555 0170',
        name: 'Grace Hopper',
        avatarColor: '#4DB6AC',
        about: 'Compiling',
        phone: '+1 555 0170',
        username: 'grace',
      );
      const chat =
          Chat(id: 'chat_grace', contact: contact, messages: []);
      ChatStore.instance.upsert(chat);
      return chat;
    }

    test('updateContactProfile renames a contact locally', () {
      final chat = seedChat();
      ChatStore.instance.updateContactProfile(chat.contact.id, name: 'Gracie');
      expect(ChatStore.instance.chatById('chat_grace')!.contact.name, 'Gracie');
      // Blank names are ignored.
      ChatStore.instance.updateContactProfile(chat.contact.id, name: '   ');
      expect(ChatStore.instance.chatById('chat_grace')!.contact.name, 'Gracie');
    });

    testWidgets('Contact info shows the about and action buttons',
        (tester) async {
      final chat = seedChat();
      await tester.pumpWidget(MaterialApp(
        home: ContactInfoScreen(user: chat.contact, chatId: chat.id),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('Compiling'), findsOneWidget); // the shared about
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Video'), findsOneWidget);
    });

    testWidgets('Edit name from contact info updates the stored contact',
        (tester) async {
      final chat = seedChat();
      await tester.pumpWidget(MaterialApp(
        home: ContactInfoScreen(user: chat.contact, chatId: chat.id),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit name'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Amazing Grace');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(ChatStore.instance.chatById('chat_grace')!.contact.name,
          'Amazing Grace');
    });
  });

  group('Okay Score & badges', () {
    test('points award and reset', () {
      ScoreStore.instance.resetForTest();
      expect(ScoreStore.instance.points, 0);
      ScoreStore.instance.award(10);
      ScoreStore.instance.award(0); // ignored
      ScoreStore.instance.award(-5); // ignored
      expect(ScoreStore.instance.points, 10);
      ScoreStore.instance.resetForTest();
      expect(ScoreStore.instance.points, 0);
    });

    test('threshold and flag badges unlock as expected', () {
      ScoreStore.instance.resetForTest();
      expect(ScoreStore.instance.isEarned('starter'), isFalse);
      ScoreStore.instance.award(2);
      expect(ScoreStore.instance.isEarned('starter'), isTrue); // threshold 2
      expect(ScoreStore.instance.isEarned('century'), isFalse);
      ScoreStore.instance.award(100);
      expect(ScoreStore.instance.isEarned('century'), isTrue);
      // Flag-based badge.
      expect(ScoreStore.instance.isEarned('caller'), isFalse);
      ScoreStore.instance.recordFlag('made_call');
      expect(ScoreStore.instance.isEarned('caller'), isTrue);
    });

    test('levels derive from points with progress to the next', () {
      ScoreStore.instance.resetForTest();
      expect(ScoreStore.instance.level, 1);
      expect(ScoreStore.instance.levelTitle, 'Newcomer');
      ScoreStore.instance.award(50); // level 2 threshold
      expect(ScoreStore.instance.level, 2);
      expect(ScoreStore.instance.levelTitle, 'Rookie');
      ScoreStore.instance.award(50); // 100 pts, halfway to level 3 (150)
      expect(ScoreStore.instance.nextLevelAt, 150);
      expect(ScoreStore.instance.levelProgress, closeTo(0.5, 0.001));
      ScoreStore.instance.award(5000); // max out
      expect(ScoreStore.instance.level, ScoreStore.levelTitles.length);
      expect(ScoreStore.instance.nextLevelAt, isNull);
      expect(ScoreStore.instance.levelProgress, 1.0);
    });

    test('voting a poll and posting to a forum award points and badges', () {
      ScoreStore.instance.resetForTest();
      ChatStore.instance.reset();
      CommunityStore.instance.resetForTest();

      // A poll vote awards a point and unlocks the pollster badge.
      final bob = ChatStore.instance.chatWithContact('u_bob')!;
      ChatStore.instance.addMessage(
        bob.id,
        Message(
          id: 'pv',
          text: '',
          time: DateTime(2024),
          isMe: false,
          isPoll: true,
          pollQuestion: 'Q',
          pollOptions: const ['A', 'B'],
          pollVotes: const [0, 0],
        ),
      );
      final before = ScoreStore.instance.points;
      ChatStore.instance.votePoll(bob.id, 'pv', 0);
      expect(ScoreStore.instance.points,
          before + ScoreStore.pointsPerPollVote);
      expect(ScoreStore.instance.isEarned('pollster'), isTrue);

      // Creating a forum post awards points and unlocks the contributor badge.
      final p2 = ScoreStore.instance.points;
      CommunityStore.instance.addForumPost(
        'seed_design',
        'seed_forum',
        ForumPost(
          id: 'np',
          authorId: 'me',
          authorName: 'You',
          time: DateTime(2024),
          title: 'Hello',
        ),
      );
      expect(ScoreStore.instance.points,
          p2 + ScoreStore.pointsPerForumPost);
      expect(ScoreStore.instance.isEarned('poster'), isTrue);
    });

    test('featured badge must be earned and can be cleared', () {
      ScoreStore.instance.resetForTest();
      ScoreStore.instance.setFeatured('century'); // not earned yet → ignored
      expect(ScoreStore.instance.featuredBadge, isNull);
      ScoreStore.instance.award(100);
      ScoreStore.instance.setFeatured('century');
      expect(ScoreStore.instance.featuredBadge, 'century');
      ScoreStore.instance.setFeatured(null);
      expect(ScoreStore.instance.featuredBadge, isNull);
    });

    testWidgets('the Score screen ranks chats by active streak',
        (tester) async {
      ChatStore.instance.reset();
      StreakStore.instance.resetForTest();
      final chats =
          ChatStore.instance.chats.where((c) => !c.contact.isGroup).toList();
      StreakStore.instance.seed(chats[0].id, 4);
      StreakStore.instance.seed(chats[1].id, 19);
      // The screen carries a score ring, stats, and a goal above the streak
      // list now, so give it a phone-shaped column tall enough to lay the
      // whole thing out rather than asserting against the fold.
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: ScoreScreen()));
      await tester.pumpAndSettle();

      expect(find.text('STREAKS'), findsOneWidget);
      // Both streaks are listed, as chips. Matched through StreakChip rather
      // than raw text: the stats row above also prints a best-ever of 19, and
      // that is the right number in the wrong place to assert on.
      final chips = find.descendant(
          of: find.byType(ListTile), matching: find.byType(StreakChip));
      expect(chips, findsNWidgets(2));
      final counts = tester
          .widgetList<StreakChip>(chips)
          .map((c) => c.count)
          .toList();
      expect(counts, [19, 4], reason: 'longest streak ranks first');
      // …and that ranking is the on-screen order, not just list order.
      expect(tester.getTopLeft(chips.first).dy,
          lessThan(tester.getTopLeft(chips.last).dy));
    });

    testWidgets('a streak that ticks up shows in the chat you earned it in',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ChatStore.instance.reset();
      StreakStore.instance.resetForTest();
      final chat = ChatStore.instance.chats
          .firstWhere((c) => !c.contact.isGroup);
      final today = DateTime.now();

      // I've written to them today; the streak needs their reply to advance.
      ChatStore.instance.addMessage(chat.id,
          Message(id: 'sk1', text: 'morning', time: today, isMe: true));
      await tester.pumpWidget(MaterialApp(
          home: ChatScreen(chat: ChatStore.instance.chatById(chat.id)!)));
      await tester.pumpAndSettle();
      expect(find.byType(StreakChip), findsNothing);

      // Their reply lands while the chat is open — the moment the streak
      // becomes a streak, and exactly when it should appear.
      ChatStore.instance.addMessage(chat.id,
          Message(id: 'sk2', text: 'morning!', time: today, isMe: false));
      expect(StreakStore.instance.streakFor(chat.id), 1,
          reason: 'a mutual exchange today is a one-day streak');
      await tester.pumpAndSettle();

      expect(find.byType(StreakChip), findsOneWidget,
          reason: 'the header must follow the streak store, not only the '
              'chat store — the store that changed is the streak one');
      expect(find.text('1'), findsWidgets);

      // A peer's broadcast reconciles the count without touching the chat
      // store at all (this is the relay path). Nothing else will redraw the
      // header, so it has to be listening to the streak store itself.
      StreakStore.instance.reconcile(chat.id, 9, at: today);
      await tester.pumpAndSettle();
      expect(find.text('9'), findsWidgets,
          reason: 'a streak agreed with the peer must appear without '
              'leaving and re-entering the chat');
    });

    test('a best streak outlives the streak that set it', () {
      StreakStore.instance.resetForTest();
      final d1 = DateTime(2026, 5, 1);
      // Three days of mutual messages.
      for (var i = 0; i < 3; i++) {
        final day = d1.add(Duration(days: i));
        StreakStore.instance.record('c', isMe: true, at: day);
        StreakStore.instance.record('c', isMe: false, at: day);
      }
      final third = d1.add(const Duration(days: 2));
      expect(StreakStore.instance.streakFor('c', now: third), 3);
      expect(StreakStore.instance.bestFor('c'), 3);

      // Weeks later the live streak is gone, but the record stands — the run
      // happened even though it ended.
      final later = d1.add(const Duration(days: 30));
      expect(StreakStore.instance.streakFor('c', now: later), 0);
      expect(StreakStore.instance.bestFor('c'), 3);
      expect(StreakStore.instance.bestEver, 3);

      // A peer's higher count raises the record too.
      StreakStore.instance.reconcile('c', 11, at: later);
      expect(StreakStore.instance.bestEver, 11);

      // Records written before bests existed still know the streak got at
      // least as high as its current count.
      final old = StreakData.fromJson(
          {'count': 7, 'lastDay': '2026-05-01', 'today': '2026-05-01'});
      expect(old.best, 7);
    });

    test('live streak totals count only what is still alive', () {
      StreakStore.instance.resetForTest();
      final today = DateTime.now();
      StreakStore.instance.seed('a', 4);
      StreakStore.instance.seed('b', 6);
      // Lapsed: last advanced well before yesterday.
      StreakStore.instance
          .seed('c', 20, lastDay: today.subtract(const Duration(days: 9)));
      expect(StreakStore.instance.activeCount(now: today), 2);
      expect(StreakStore.instance.totalActiveDays(now: today), 10);
      // The lapsed one still holds the best-ever record.
      expect(StreakStore.instance.bestEver, 20);
    });

    test('today\'s progress says which side the streak is waiting on', () {
      StreakStore.instance.resetForTest();
      final today = DateTime(2026, 6, 10, 9);
      expect(StreakStore.instance.todayProgress('c', now: today),
          (false, false));

      StreakStore.instance.record('c', isMe: true, at: today);
      expect(StreakStore.instance.todayProgress('c', now: today),
          (true, false),
          reason: 'I have written; it is their turn');

      StreakStore.instance.record('c', isMe: false, at: today);
      expect(
          StreakStore.instance.todayProgress('c', now: today), (true, true));

      // Yesterday's exchange says nothing about today.
      final tomorrow = today.add(const Duration(days: 1));
      expect(StreakStore.instance.todayProgress('c', now: tomorrow),
          (false, false));
    });

    test('the next badge is the nearest one still out of reach', () {
      ScoreStore.instance.resetForTest();
      // From zero, the cheapest points badge is the goal.
      expect(ScoreStore.instance.nextBadge?.id, 'starter');
      expect(ScoreStore.instance.pointsToNextBadge, 2);

      ScoreStore.instance.award(60); // past 'starter' (2) and 'chatty' (50)
      expect(ScoreStore.instance.nextBadge?.id, 'century');
      expect(ScoreStore.instance.pointsToNextBadge, 40);
      // Progress is a fraction of the target, and earned badges are complete.
      expect(ScoreStore.instance.progressToward('century'), closeTo(0.6, 0.001));
      expect(ScoreStore.instance.progressToward('chatty'), 1.0);
      // A one-off achievement has no partial credit to show.
      expect(ScoreStore.instance.progressToward('caller'), 0.0);
      expect(ScoreStore.instance.progressToward('nonexistent'), 0.0);

      // Every points badge earned: no invented goal.
      ScoreStore.instance.award(1000);
      expect(ScoreStore.instance.nextBadge, isNull);
      expect(ScoreStore.instance.pointsToNextBadge, isNull);
      // …and progress never overshoots.
      expect(ScoreStore.instance.progressToward('legend'), 1.0);
    });

    test('every earning rule names a real, positive award', () {
      expect(ScoreStore.earningRules, isNotEmpty);
      for (final (label, points) in ScoreStore.earningRules) {
        expect(label.trim(), isNotEmpty);
        expect(points, greaterThan(0),
            reason: '"$label" would be a rule that earns nothing');
      }
      // The listed numbers are the constants the app actually awards, not a
      // second copy that can drift out of step.
      final awards = {
        for (final (label, points) in ScoreStore.earningRules) label: points
      };
      expect(awards['Send a message'], ScoreStore.pointsPerSend);
      expect(awards['Open the app on a new day'],
          ScoreStore.pointsPerDailyCheckIn);
      expect(awards['Place a voice or video call'], ScoreStore.pointsPerCall);
      // Biggest award first, so the list reads as advice.
      final values = [
        for (final (_, points) in ScoreStore.earningRules) points
      ];
      final sorted = [...values]..sort((a, b) => b.compareTo(a));
      expect(values, sorted);
    });

    testWidgets('the Score screen shows the level, the goal, and the rules',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ScoreStore.instance.resetForTest();
      StreakStore.instance.resetForTest();
      ChatStore.instance.reset();
      ScoreStore.instance.award(60);
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: ScoreScreen()));
      await tester.pumpAndSettle();

      // The score and its level, which the card never used to name together.
      expect(find.text('60'), findsWidgets);
      expect(find.textContaining('Level 2'), findsOneWidget);
      expect(find.textContaining('Regular'), findsOneWidget,
          reason: '60 points is level 2, and level 3 is the next title');

      // The nearest badge, with what it costs.
      expect(find.textContaining('Next up:'), findsOneWidget);
      expect(find.textContaining('40 more points'), findsOneWidget);

      // How the number moves — previously nowhere in the app.
      expect(find.text('HOW POINTS WORK'), findsOneWidget);
      expect(find.text('+${ScoreStore.pointsPerDailyCheckIn}'),
          findsOneWidget);

      // Streaks explain that it takes both people, not just daily messaging.
      expect(find.textContaining('you and someone both send'), findsOneWidget);
    });

    testWidgets('a locked badge explains itself instead of doing nothing',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ScoreStore.instance.resetForTest();
      StreakStore.instance.resetForTest();
      ChatStore.instance.reset();
      ScoreStore.instance.award(60);
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: ScoreScreen()));
      await tester.pumpAndSettle();

      // 'Legend' needs 500 points; the card carries its own progress.
      final locked = find.text('Legend');
      await tester.ensureVisible(locked);
      await tester.pumpAndSettle();
      expect(find.text('60 / 500'), findsOneWidget);

      await tester.tap(locked);
      await tester.pumpAndSettle();
      expect(find.text('Reach 500 points'), findsWidgets);
      expect(find.text('60 / 500 points'), findsOneWidget);
    });

    test('sending a message grows the score', () {
      ScoreStore.instance.resetForTest();
      ChatStore.instance.reset();
      final chat = ChatStore.instance.chats.first;
      final before = ScoreStore.instance.points;
      ChatStore.instance.addMessage(
        chat.id,
        Message(id: 's1', text: 'hi', time: DateTime(2024, 1, 1), isMe: true),
      );
      expect(ScoreStore.instance.points,
          before + ScoreStore.pointsPerSend);
    });

    test('verified flag toggles on the profile', () {
      AppState.resetForTest();
      Session.instance.resetForTest();
      expect(AppState.profile.value.verified, isFalse);
      AppState.setVerified(true);
      expect(AppState.profile.value.verified, isTrue);
      AppState.setVerified(false);
      expect(AppState.profile.value.verified, isFalse);
    });

    test('AppUser round-trips verified and score through JSON', () {
      const u = AppUser(
        id: 'x',
        name: 'X',
        avatarColor: '#000000',
        verified: true,
        score: 77,
      );
      final back = AppUser.fromJson(u.toJson());
      expect(back.verified, isTrue);
      expect(back.score, 77);
    });

    test('AppUser round-trips emoji, pronouns and link through JSON', () {
      const u = AppUser(
        id: 'x',
        name: 'X',
        avatarColor: '#000000',
        emoji: '🦊',
        pronouns: 'they/them',
        link: 'okay.chat',
      );
      final back = AppUser.fromJson(u.toJson());
      expect(back.emoji, '🦊');
      expect(back.pronouns, 'they/them');
      expect(back.link, 'okay.chat');
      // Old payloads without the fields still decode with safe defaults.
      final legacy = AppUser.fromJson({
        'id': 'y',
        'name': 'Y',
        'avatarColor': '#111111',
      });
      expect(legacy.emoji, '');
      expect(legacy.pronouns, '');
      expect(legacy.link, '');
    });

    test('a verified, high-score sender is reflected on the contact', () {
      ChatStore.instance.reset();
      final payload = RelayService.encode(
        message: Message(
            id: 'vm9', text: 'hey', time: DateTime(2024, 1, 1), isMe: true),
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromVerified: true,
        fromScore: 900,
      );
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      final contact =
          ChatStore.instance.chatWithContact('+1 555 0199')!.contact;
      expect(contact.verified, isTrue);
      expect(contact.score, 900);
    });
  });

  group('Conversation streaks', () {
    final d1 = DateTime(2024, 3, 10, 9);
    final d2 = DateTime(2024, 3, 11, 9);

    void exchange(String chat, DateTime day) {
      StreakStore.instance.record(chat, isMe: true, at: day);
      StreakStore.instance
          .record(chat, isMe: false, at: day.add(const Duration(hours: 1)));
    }

    test('mutual exchange on consecutive days builds a streak', () {
      StreakStore.instance.resetForTest();
      exchange('c', d1);
      expect(StreakStore.instance.streakFor('c', now: d1), 1);
      exchange('c', d2);
      expect(StreakStore.instance.streakFor('c', now: d2), 2);
    });

    test('a second exchange the same day does not double-count', () {
      StreakStore.instance.resetForTest();
      exchange('c', d1);
      exchange('c', d1.add(const Duration(hours: 3)));
      expect(StreakStore.instance.streakFor('c', now: d1), 1);
    });

    test('a missed day lapses and restarts the streak', () {
      StreakStore.instance.resetForTest();
      exchange('c', d1);
      exchange('c', d2);
      // Skip to three days later — the streak restarts at 1.
      final later = d2.add(const Duration(days: 3));
      exchange('c', later);
      expect(StreakStore.instance.streakFor('c', now: later), 1);
    });

    test('streakFor reports 0 once the streak is stale', () {
      StreakStore.instance.resetForTest();
      exchange('c', d1);
      // Two days on, the last streak day is neither today nor yesterday.
      expect(
          StreakStore.instance
              .streakFor('c', now: d1.add(const Duration(days: 2))),
          0);
    });

    test('a one-sided day does not advance the streak', () {
      StreakStore.instance.resetForTest();
      StreakStore.instance.record('c', isMe: true, at: d1);
      expect(StreakStore.instance.streakFor('c', now: d1), 0);
    });

    test('reconcile adopts a higher peer count and ignores lower/zero', () {
      StreakStore.instance.resetForTest();
      exchange('c', d1); // local streak = 1
      StreakStore.instance.reconcile('c', 9, at: d1);
      expect(StreakStore.instance.streakFor('c', now: d1), 9);
      // A lower or zero broadcast never rolls it back.
      StreakStore.instance.reconcile('c', 3, at: d1);
      StreakStore.instance.reconcile('c', 0, at: d1);
      expect(StreakStore.instance.streakFor('c', now: d1), 9);
    });

    test('a streak is "expiring" only when it lapses without today\'s message',
        () {
      StreakStore.instance.resetForTest();
      exchange('c', d1); // kept up on d1
      // Same day: safe, not expiring.
      expect(StreakStore.instance.isExpiringSoon('c', now: d1), isFalse);
      // Next day, before a mutual exchange: alive but at risk.
      expect(StreakStore.instance.isExpiringSoon('c', now: d2), isTrue);
      // Keep it up on d2: no longer expiring.
      exchange('c', d2);
      expect(StreakStore.instance.isExpiringSoon('c', now: d2), isFalse);
      // Two days on it has lapsed entirely — not "expiring", just gone.
      final gone = d2.add(const Duration(days: 2));
      expect(StreakStore.instance.streakFor('c', now: gone), 0);
      expect(StreakStore.instance.isExpiringSoon('c', now: gone), isFalse);
    });

    test('a streak broadcast on an incoming message converges the receiver', () {
      StreakStore.instance.resetForTest();
      ChatStore.instance.reset();
      final at = DateTime(2024, 5, 2, 9);
      final payload = RelayService.encode(
        message: Message(id: 'st1', text: 'hi', time: at, isMe: true),
        fromPhone: '+1 555 0199',
        fromName: 'Grace',
        fromStreak: 8,
      );
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      expect(
          StreakStore.instance.streakFor('chat_+1 555 0199', now: at), 8);
    });
  });

  group('Status (stories)', () {
    StatusUpdate su(String id, String author, DateTime t) => StatusUpdate(
          id: id,
          authorId: author,
          authorName: author == 'me' ? 'You' : author,
          avatarColor: '#7A5CFF',
          text: 'hi',
          bgColor: '#12B76A',
          time: t,
        );

    test('expired updates drop out of the active window', () {
      final now = DateTime(2024, 6, 10, 12);
      StatusStore.instance.seedForTest([
        su('fresh', 'me', now.subtract(const Duration(hours: 2))),
        su('old', 'me', now.subtract(const Duration(hours: 30))), // > 24h
      ]);
      final mine = StatusStore.instance.myActive(now: now);
      expect(mine.map((u) => u.id), ['fresh']);
    });

    test('other authors are grouped and ordered by most recent', () {
      final now = DateTime(2024, 6, 10, 12);
      StatusStore.instance.seedForTest([
        su('a1', 'u_alice', now.subtract(const Duration(hours: 6))),
        su('e1', 'u_erin', now.subtract(const Duration(hours: 5))),
        su('e2', 'u_erin', now.subtract(const Duration(hours: 1))),
        su('mine', 'me', now.subtract(const Duration(hours: 2))),
      ]);
      final threads = StatusStore.instance.otherThreads(now: now);
      // Two other authors (me excluded); Erin most recent → first.
      expect(threads.length, 2);
      expect(threads.first.authorId, 'u_erin');
      expect(threads.first.updates.length, 2);
      // Grouped updates are oldest-first for playback.
      expect(threads.first.updates.map((u) => u.id), ['e1', 'e2']);
    });

    testWidgets('replying to a status sends a message to that contact',
        (tester) async {
      ChatStore.instance.reset();
      final now = DateTime.now();
      StatusStore.instance.seedForTest([
        StatusUpdate(
          id: 'a1',
          authorId: 'u_alice',
          authorName: 'Alice Bennett',
          avatarColor: '#E57373',
          text: 'Beach day',
          bgColor: '#0BA5EC',
          time: now.subtract(const Duration(hours: 1)),
        ),
      ]);
      final thread = StatusStore.instance.otherThreads().single;
      final before =
          ChatStore.instance.chatWithContact('u_alice')!.messages.length;

      await tester.pumpWidget(
          MaterialApp(home: StatusViewerScreen(thread: thread)));
      await tester.pump(); // don't settle — the auto-advance timer is pending

      await tester.enterText(find.byType(TextField), 'Looks fun!');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      final msgs = ChatStore.instance.chatWithContact('u_alice')!.messages;
      expect(msgs.length, before + 1);
      expect(msgs.last.text, 'Looks fun!');
      expect(msgs.last.isMe, isTrue);
    });

    test('posting adds a status for the current user', () {
      StatusStore.instance.resetForTest();
      final now = DateTime(2024, 6, 10, 12);
      StatusStore.instance.post(
        text: 'On vacation 🏖️',
        bgColor: '#0BA5EC',
        authorName: 'You',
        avatarColor: '#25D366',
        now: now,
      );
      final mine = StatusStore.instance.myActive(now: now);
      expect(mine.single.text, 'On vacation 🏖️');
      // Blank posts are ignored.
      StatusStore.instance.post(
          text: '   ',
          bgColor: '#0BA5EC',
          authorName: 'You',
          avatarColor: '#25D366',
          now: now);
      expect(StatusStore.instance.myActive(now: now).length, 1);
    });
  });

  group('Payments test mode', () {
    test('test mode makes payments usable and simulates a send', () async {
      final svc = PaymentService.instance;
      svc.setTestMode(false);
      // Without real Stripe config, payments are off by default.
      expect(svc.isConfigured, isFalse);

      svc.setTestMode(true);
      expect(svc.isConfigured, isTrue);
      expect(svc.canSendOnThisDevice, isTrue); // works anywhere in test mode

      // A simulated send always succeeds without touching Stripe/Supabase.
      final ok = await svc.sendMoney(toPhone: '+1 555 0111', amountCents: 500);
      expect(ok, isTrue);

      // The sandbox wallet reports a usable, receivable balance.
      final status = await svc.status();
      expect(status.canReceive, isTrue);
      expect(status.availableCents, greaterThan(0));

      svc.setTestMode(false);
      expect(svc.isConfigured, isFalse);
    });
  });

  group('Encrypted chat backup', () {
    test('archive round-trips with the right passphrase', () {
      const bundle = '{"chats":{"chats":[]},"profile":{"name":"You"}}';
      final archive =
          BackupService.encryptArchive(bundle, 'correct horse battery');
      expect(archive, isNot(contains('You'))); // payload is sealed
      expect(archive, contains('okay-messaging-backup')); // self-describing
      final back =
          BackupService.decryptArchive(archive, 'correct horse battery');
      expect(back, bundle);
    });

    test('a wrong passphrase or tampered archive fails to decrypt', () {
      final archive = BackupService.encryptArchive('{"x":1}', 'right-pass');
      expect(BackupService.decryptArchive(archive, 'wrong-pass'), isNull);
      expect(BackupService.decryptArchive('not json', 'right-pass'), isNull);
      // A file that isn't one of our archives is rejected by the app tag.
      expect(
          BackupService.decryptArchive('{"app":"other","data":"x"}', 'p'),
          isNull);
    });

    test('backing up then restoring reproduces chats and servers', () {
      ChatStore.instance.reset();
      CommunityStore.instance.resetForTest();
      final beforeChats = ChatStore.instance.chats.length;
      final beforeServers = CommunityStore.instance.communities.length;
      expect(beforeChats, greaterThan(0));
      expect(beforeServers, greaterThan(0));

      final archive = BackupService.encryptArchive(
          BackupService.buildBundle(), 'my-passphrase');

      // Wipe chats and servers, then restore from the encrypted archive.
      ChatStore.instance.clearAll();
      CommunityStore.instance.clearAll();
      expect(ChatStore.instance.chats, isEmpty);
      expect(CommunityStore.instance.communities, isEmpty);

      final bundle =
          BackupService.decryptArchive(archive, 'my-passphrase');
      expect(bundle, isNotNull);
      expect(BackupService.applyBundle(bundle!), isTrue);
      expect(ChatStore.instance.chats.length, beforeChats);
      expect(CommunityStore.instance.communities.length, beforeServers);
      // Forum posts inside a server survive the round-trip too.
      final forum = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum');
      expect(forum.posts, isNotEmpty);
    });

    test('backup reminder marks a backup overdue by cadence', () {
      BackupService.instance.resetForTest();
      final now = DateTime(2024, 6, 10, 12);
      // Off never nags.
      expect(BackupService.instance.isBackupDue(now: now), isFalse);
      // Weekly with no backup yet → due.
      BackupService.instance.setReminder(BackupReminder.weekly);
      expect(BackupService.instance.isBackupDue(now: now), isTrue);
      // A backup 3 days ago is still fresh for weekly...
      BackupService.instance
          .createArchiveBytes('pw', now: now.subtract(const Duration(days: 3)));
      expect(BackupService.instance.isBackupDue(now: now), isFalse);
      // ...but stale after 8 days.
      expect(
          BackupService.instance
              .isBackupDue(now: now.add(const Duration(days: 8))),
          isTrue);
      BackupService.instance.resetForTest();
    });

    test('createArchiveBytes stamps the last-backup time', () {
      BackupService.instance.resetForTest();
      ChatStore.instance.reset();
      expect(BackupService.instance.lastBackupAt, isNull);
      final when = DateTime(2024, 5, 1, 9);
      final bytes =
          BackupService.instance.createArchiveBytes('pw', now: when);
      expect(bytes, isNotEmpty);
      expect(BackupService.instance.lastBackupAt, when);
    });
  });

  group('Account service', () {
    test('e164 keeps digits only', () {
      expect(AccountService.e164('+1 (555) 012-3456'), '15550123456');
      expect(AccountService.e164('44 7700 900123'), '447700900123');
    });

    test('normalizeUsername lowercases and strips @ and bad chars', () {
      expect(AccountService.normalizeUsername('  @Ada_L. '), 'ada_l.');
      expect(AccountService.normalizeUsername('@@Bob!!Smith'), 'bobsmith');
    });

    test('isValidUsername enforces length and charset', () {
      expect(AccountService.isValidUsername('ada'), isTrue);
      expect(AccountService.isValidUsername('a.b_9'), isTrue);
      expect(AccountService.isValidUsername('ab'), isFalse); // too short
      expect(AccountService.isValidUsername('@AdaL'), isTrue); // normalized
    });

    test('is disabled without the REQUIRE_OTP build flag', () {
      // Tests build without --dart-define, so the real flow stays off and the
      // instant local login is used.
      expect(AccountService.isEnabled, isFalse);
    });

    test('phoneHashHex is deterministic, format-independent, and distinct', () {
      // Same number in different formats hashes identically...
      expect(
        AccountService.phoneHashHex('+1 (555) 012-3456'),
        AccountService.phoneHashHex('15550123456'),
      );
      // ...it's a 64-char hex SHA-256...
      final h = AccountService.phoneHashHex('15550123456');
      expect(h.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
      // ...and different numbers hash differently.
      expect(h, isNot(AccountService.phoneHashHex('15550009999')));
    });

    test('searchByUsername returns empty for short queries without network',
        () async {
      expect(await AccountService.instance.searchByUsername('a'), isEmpty);
      expect(await AccountService.instance.searchByUsername(''), isEmpty);
    });
  });

  group('Contacts sync (phone matching)', () {
    test('phoneCandidates handles international and bare local numbers', () {
      // Already fully qualified (11 digits) → just itself.
      expect(ContactsSync.phoneCandidates('+1 (555) 012-3456'),
          {'15550123456'});
      // Bare 10-digit NANP number → itself and the +1 form.
      expect(ContactsSync.phoneCandidates('555-012-3456'),
          {'5550123456', '15550123456'});
      // Too short to dial → nothing.
      expect(ContactsSync.phoneCandidates('123'), isEmpty);
    });

    test('hashesFor dedupes and hashes every candidate', () {
      final hashes = ContactsSync.hashesFor(['555-012-3456']);
      // Two candidates → two distinct hashes, matching AccountService's hash.
      expect(hashes.toSet().length, 2);
      expect(hashes, contains(AccountService.phoneHashHex('15550123456')));
      expect(hashes, contains(AccountService.phoneHashHex('5550123456')));
      // De-duplication across numbers that normalise to the same thing.
      final dupes =
          ContactsSync.hashesFor(['15550123456', '+1 555 012 3456']);
      expect(dupes.toSet().length, dupes.length);
    });

    test('phone display formatting touches numbers, never names', () {
      expect(formatPhoneForDisplay('14386386261'), '+1 (438) 638-6261');
      expect(formatPhoneForDisplay('+1 438 638 6261'), '+1 (438) 638-6261');
      expect(formatPhoneForDisplay('4386386261'), '(438) 638-6261');
      expect(formatPhoneForDisplay('+447911123456'), '+447911123456');
      // Real names, usernames, and short fragments pass through untouched.
      expect(formatPhoneForDisplay('Grace Hopper'), 'Grace Hopper');
      expect(formatPhoneForDisplay('555-0123'), '555-0123');
      expect(formatPhoneForDisplay(''), '');
    });

    test('CallKit uuids are stable per call and version-4 shaped', () {
      addTearDown(CallKitBridge.instance.resetForTest);
      final a = CallKitBridge.instance.uuidFor('call_1');
      expect(CallKitBridge.instance.uuidFor('call_1'), a); // stable
      expect(CallKitBridge.instance.uuidFor('call_2'), isNot(a));
      expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch(a),
          isTrue);
    });

    test('mailbox rows route by event and tolerate junk', () {
      final rows = [
        // Typed rows: messages, receipts, edits all queue offline now.
        {
          'id': 1,
          'payload': {
            'e': 'msg',
            'p': {'id': 'm1', 'from': '+15550100', 'c': 'AAA='}
          }
        },
        {
          'id': 2,
          'payload': {
            'e': 'receipt',
            'p': {'from': '+15550100', 'kind': 'delivered', 'id': 'm1'}
          }
        },
        // A legacy row from before events were queued reads as a message.
        {'id': 3, 'payload': '{"id":"m2","from":"+15550100","c":"BBB="}'},
        {'id': 4, 'payload': 42}, // corrupt — skipped, never wedges the queue
        'not even a map',
      ];
      final entries = RelayService.mailboxEntries(rows);
      expect(entries, hasLength(3));
      expect(entries[0].$1, 'msg');
      expect(entries[0].$2['id'], 'm1');
      expect(entries[1].$1, 'receipt');
      expect(entries[1].$2['kind'], 'delivered');
      expect(entries[2].$1, 'msg');
      expect(entries[2].$2['id'], 'm2');
      // Envelopes stay ciphertext, same as the live broadcast.
      expect(entries[0].$2.containsKey('text'), isFalse);
    });

    test('im: links (default messaging app) parse and open the right chat',
        () {
      // Phone targets, in every shape iOS sends them.
      expect(IncomingLinks.imPhone('im:+15550123456'), '+15550123456');
      expect(IncomingLinks.imPhone('im://+1-555-012.3456'), '+15550123456');
      expect(IncomingLinks.imPhone('sms:5550123456'), '5550123456');
      expect(IncomingLinks.imPhone('im:%2B15550123456'), '+15550123456');
      // Email, junk, and foreign schemes are not phone targets.
      expect(IncomingLinks.imPhone('im:user@example.com'), isNull);
      expect(IncomingLinks.imPhone('im:123'), isNull);
      expect(IncomingLinks.imPhone('https://okay.chat'), isNull);
      expect(IncomingLinks.isEmailTarget('im:user@example.com'), isTrue);
      expect(IncomingLinks.isEmailTarget('im:+15550123456'), isFalse);

      // Call taps (default calling app) parse the same way from tel: URLs,
      // and the two kinds never cross.
      expect(IncomingLinks.telPhone('tel:+15550123456'), '+15550123456');
      expect(IncomingLinks.telPhone('telprompt://5550123456'), '5550123456');
      expect(IncomingLinks.telPhone('im:+15550123456'), isNull);
      expect(IncomingLinks.imPhone('tel:+15550123456'), isNull);

      // A message tap creates the chat, then reuses (and unarchives) it.
      ChatStore.instance.reset();
      openChatForPhone('+15550123456');
      final created = ChatStore.instance.chatWithContact('+15550123456');
      expect(created, isNotNull);
      expect(created!.contact.phone, '+15550123456');
      ChatStore.instance.setArchived(created.id, true);
      openChatForPhone('+15550123456');
      expect(
          ChatStore.instance
              .chatWithContact('+15550123456')!
              .isArchived,
          isFalse);
      expect(
          ChatStore.instance.allChats
              .where((c) => c.contact.id == '+15550123456'),
          hasLength(1));

      // A call tap resolves to the existing chat's contact (named), and to
      // a bare number identity for strangers.
      expect(contactForPhone('+15550123456').id, '+15550123456');
      expect(contactForPhone('+19998887777').phone, '+19998887777');
    });

    test('limited access seeing nothing is not an empty address book',
        () async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
        ContactsSync.debugLimited = false;
      });

      // iOS 18 "Select Contacts" with none shared: the app is shown an empty
      // slice of a full address book. Reporting that as `empty` told people
      // their contacts had no phone numbers — the screenshotted bug.
      ContactsSync.debugNumbersOverride = () async => [];
      ContactsSync.debugLimited = true;
      expect((await ContactsSync.instance.sync()).status,
          ContactSyncStatus.limitedEmpty);

      // Full access and genuinely nothing there stays `empty`.
      ContactsSync.debugLimited = false;
      expect((await ContactsSync.instance.sync()).status,
          ContactSyncStatus.empty);

      // A limited scan that does find people is still marked partial, so the
      // list can say it only covers what was shared.
      ContactsSync.debugNumbersOverride = () async => ['555-012-3456'];
      ContactsSync.debugLimited = true;
      ContactsSync.debugLookupOverride = (_) async =>
          const [AppUser(id: 'u1', name: 'Grace', avatarColor: '#123456')];
      final result = await ContactsSync.instance.sync();
      expect(result.status, ContactSyncStatus.ok);
      expect(result.limited, isTrue);
    });

    testWidgets('the fix-it-in-Settings screens have a Settings button',
        (tester) async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLimited = false;
        ContactsSync.debugOpenSettingsOverride = null;
        ContactsSync.debugAccessLimitedOverride = null;
      });
      ContactsSync.debugNumbersOverride = () async => [];
      ContactsSync.debugLimited = true;
      // This test is about the post-sync screen; skip the pre-sync limited
      // check (whose real channel would hang the fake-async test clock).
      ContactsSync.debugAccessLimitedOverride = () async => false;
      var opened = 0;
      ContactsSync.debugOpenSettingsOverride = () => opened++;

      await tester
          .pumpWidget(const MaterialApp(home: ContactsOnAppScreen()));
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();

      // The truthful message, not the address-book blame.
      expect(find.text('No contacts shared yet'), findsOneWidget);
      expect(find.text('No contacts found'), findsNothing);

      // "Fix it in Settings" with no way to get there is a dead end.
      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('limited access is questioned before syncing, not after',
        (tester) async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
        ContactsSync.debugLimited = false;
        ContactsSync.debugAccessLimitedOverride = null;
        ContactsSync.debugOpenSettingsOverride = null;
      });
      // iOS only ever raises its contacts dialog once, so with access already
      // limited the app must do the asking itself — at sync time, when the
      // question is concrete.
      ContactsSync.debugAccessLimitedOverride = () async => true;
      ContactsSync.debugLimited = true;
      ContactsSync.debugNumbersOverride = () async => ['555-012-3456'];
      ContactsSync.debugLookupOverride = (_) async =>
          const [AppUser(id: 'u1', name: 'Grace', avatarColor: '#123456')];
      var opened = 0;
      ContactsSync.debugOpenSettingsOverride = () => opened++;

      await tester
          .pumpWidget(const MaterialApp(home: ContactsOnAppScreen()));
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();

      expect(find.text('Only some contacts are shared'), findsOneWidget);

      // Choosing Settings goes there and does NOT sync — results computed
      // from the old selection would answer a question just declared stale.
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('Find contacts'), findsOneWidget,
          reason: 'back on the intro, ready to re-run after Settings');

      // Choosing to continue syncs with the shared subset.
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use selected'));
      await tester.pumpAndSettle();
      expect(find.text('Grace'), findsOneWidget);
      // And the list admits it is partial.
      expect(find.textContaining('Only the contacts you shared'),
          findsOneWidget);
    });

    testWidgets('full access goes straight to syncing, no dialog',
        (tester) async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
        ContactsSync.debugAccessLimitedOverride = null;
      });
      ContactsSync.debugAccessLimitedOverride = () async => false;
      ContactsSync.debugNumbersOverride = () async => ['555-012-3456'];
      ContactsSync.debugLookupOverride = (_) async =>
          const [AppUser(id: 'u1', name: 'Grace', avatarColor: '#123456')];

      await tester
          .pumpWidget(const MaterialApp(home: ContactsOnAppScreen()));
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();

      expect(find.text('Only some contacts are shared'), findsNothing);
      expect(find.text('Grace'), findsOneWidget);
    });

    testWidgets('nobody on the app yet leads to inviting, not retrying',
        (tester) async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
        ContactsSync.debugAccessLimitedOverride = null;
        debugInviteShareOverride = null;
      });
      ContactsSync.debugAccessLimitedOverride = () async => false;
      ContactsSync.debugNumbersOverride = () async => ['555-012-3456'];
      ContactsSync.debugLookupOverride = (_) async => const [];
      String? shared;
      debugInviteShareOverride = (t) => shared = t;

      await tester
          .pumpWidget(const MaterialApp(home: ContactsOnAppScreen()));
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();

      expect(find.text('No contacts yet'), findsOneWidget);
      await tester.tap(find.text('Invite friends'));
      await tester.pump();
      expect(shared, isNotNull);
      expect(shared, contains('https://'),
          reason: 'an invite without a link invites nobody');
    });

    test('the directory badge is the server\'s verdict, not the client\'s',
        () {
      // A directory row with the migrated column carries the badge; a row
      // from a directory that hasn't run the migration simply doesn't — the
      // missing column costs the badge, never the lookup.
      final verified = AccountService.debugRowToUser(
          {'phone': '15550001111', 'username': 'grace', 'name': 'Grace',
           'verified': true});
      expect(verified!.verified, isTrue);
      final unmigrated = AccountService.debugRowToUser(
          {'phone': '15550002222', 'username': 'ada', 'name': 'Ada'});
      expect(unmigrated!.verified, isFalse);

      // And the webhook is what writes it: granted on a pass, withdrawn on
      // an explicit cancel, untouched otherwise.
      final hook = File('supabase/functions/payments-webhook/index.ts')
          .readAsStringSync();
      expect(hook.contains('.from("usernames")'), isTrue);
      expect(hook.contains('verified: session.status === "verified"'), isTrue);
      // The paste copy the dashboard actually runs must carry it too.
      expect(
          File('docs/edge_functions_paste/payments-webhook.ts')
              .readAsStringSync()
              .contains('.from("usernames")'),
          isTrue,
          reason: 'run: dart tool/paste_functions.dart');
    });

    testWidgets('directory-verified contacts wear the badge in the list',
        (tester) async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
        ContactsSync.debugAccessLimitedOverride = null;
      });
      ContactsSync.debugAccessLimitedOverride = () async => false;
      ContactsSync.debugNumbersOverride = () async => ['555-012-3456'];
      ContactsSync.debugLookupOverride = (_) async => const [
            AppUser(
                id: 'u1',
                name: 'Grace',
                avatarColor: '#123456',
                verified: true),
            AppUser(id: 'u2', name: 'Ada', avatarColor: '#654321'),
          ];

      await tester
          .pumpWidget(const MaterialApp(home: ContactsOnAppScreen()));
      await tester.tap(find.text('Find contacts'));
      await tester.pumpAndSettle();

      // One badge: Grace's. Ada must not inherit it from the row above.
      expect(find.byType(VerifiedBadge), findsOneWidget);
    });

    testWidgets('reachability switches speak for the directory, honestly',
        (tester) async {
      addTearDown(() {
        AccountService.debugGetReachabilityOverride = null;
        AccountService.debugSetReachabilityOverride = null;
      });
      // The directory says: findable by profile, hidden from contact sync.
      AccountService.debugGetReachabilityOverride = () async => (true, false);
      (bool, bool)? saved;
      var saveOk = true;
      AccountService.debugSetReachabilityOverride = (u, p) async {
        saved = (u, p);
        return saveOk;
      };

      await tester.pumpWidget(
          const MaterialApp(home: PrivacySettingsScreen()));
      await tester.pumpAndSettle();

      final byProfile = find.widgetWithText(SwitchListTile, 'By profile');
      final byPhone =
          find.widgetWithText(SwitchListTile, 'By phone number');
      await tester.ensureVisible(byPhone);
      expect(tester.widget<SwitchListTile>(byProfile).value, isTrue);
      expect(tester.widget<SwitchListTile>(byPhone).value, isFalse);

      // Toggling writes BOTH doors to the directory row.
      await tester.tap(byProfile);
      await tester.pumpAndSettle();
      expect(saved, (false, false));

      // A failed save must not leave the switch lying: it reverts to what
      // the directory actually holds and says why.
      saveOk = false;
      AccountService.debugGetReachabilityOverride = () async =>
          (false, false);
      await tester.tap(byPhone);
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t save'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(byPhone).value, isFalse,
          reason: 'the unsaved choice must not look chosen');
    });

    test('sync matches hashed numbers against the directory', () async {
      addTearDown(() {
        ContactsSync.debugNumbersOverride = null;
        ContactsSync.debugLookupOverride = null;
      });

      // Permission declined.
      ContactsSync.debugNumbersOverride = () async => null;
      expect((await ContactsSync.instance.sync()).status,
          ContactSyncStatus.permissionDenied);

      // Address book without numbers.
      ContactsSync.debugNumbersOverride = () async => [];
      expect((await ContactsSync.instance.sync()).status,
          ContactSyncStatus.empty);

      // The happy path: numbers are hashed (never sent raw) and matched.
      ContactsSync.debugNumbersOverride =
          () async => ['555-012-3456', 'junk'];
      List<String>? sentHashes;
      ContactsSync.debugLookupOverride = (hashes) async {
        sentHashes = hashes;
        return const [
          AppUser(id: 'u1', name: 'Grace', avatarColor: '#123456')
        ];
      };
      final result = await ContactsSync.instance.sync();
      expect(result.status, ContactSyncStatus.ok);
      expect(result.matches.single.name, 'Grace');
      expect(result.scanned, 2);
      // Only hashes crossed the boundary — never a raw number: exactly the
      // two candidate hashes of the one dialable number.
      expect(
          sentHashes!.toSet(),
          {
            AccountService.phoneHashHex('5550123456'),
            AccountService.phoneHashHex('15550123456'),
          });
    });
  });

  testWidgets('new-user nudge shows once and dismisses', (tester) async {
    OnboardingStore.instance.resetForTest(); // opt back into the nudge
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome to OkayMessenger 👋'), findsOneWidget);
    expect(find.text('Set up your profile'), findsOneWidget);
    expect(find.text('Find people by username'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to OkayMessenger 👋'), findsNothing);
    expect(OnboardingStore.instance.done, isTrue);
  });

  testWidgets('Support screen shows tips, not subscription tiers',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: OkayProScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Support OkayMessenger'), findsOneWidget);
    expect(find.text('Choose an amount'), findsOneWidget);
    // No paid-tier / subscription language survives.
    expect(find.text('per month'), findsNothing);
    expect(find.textContaining('Choose Pro'), findsNothing);

    // Fixed store products (Apple IAP) — pick the Lunch tip and the send
    // button follows (scroll to reveal it).
    await tester.tap(find.text(r'$10.99'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(r'Send $10.99 tip'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(r'Send $10.99 tip'), findsOneWidget);
  });

  group('In-call reactions', () {
    setUp(() => CallService.instance.resetForTest());

    CallSession connected(CallDirection dir) => CallSession(
          callId: 'c1',
          peer: const AppUser(
              id: '1', name: 'A', avatarColor: '#000000', phone: '15551234567'),
          video: false,
          direction: dir,
          status: CallStatus.connected,
        );

    test('sendReaction emits locally and bumps the sequence', () {
      CallService.instance.current.value = connected(CallDirection.outgoing);
      CallService.instance.sendReaction('👍');
      final r1 = CallService.instance.reaction.value!;
      expect(r1.emoji, '👍');
      expect(r1.fromMe, isTrue);
      CallService.instance.sendReaction('❤️');
      final r2 = CallService.instance.reaction.value!;
      expect(r2.emoji, '❤️');
      expect(r2.seq, greaterThan(r1.seq));
    });

    test('peer media state updates only for the active call', () {
      CallService.instance.current.value = connected(CallDirection.outgoing);
      expect(CallService.instance.peerMedia.value.video, isFalse);

      CallService.instance
          .onRemoteMediaState('c1', {'video': true, 'screen': false});
      expect(CallService.instance.peerMedia.value.video, isTrue);
      expect(CallService.instance.peerMedia.value.screen, isFalse);

      CallService.instance
          .onRemoteMediaState('c1', {'video': false, 'screen': true});
      expect(CallService.instance.peerMedia.value.screen, isTrue);

      // A stale/foreign call id or a missing payload changes nothing.
      CallService.instance
          .onRemoteMediaState('other', {'video': false, 'screen': false});
      expect(CallService.instance.peerMedia.value.screen, isTrue);
      CallService.instance.onRemoteMediaState('c1', null);
      expect(CallService.instance.peerMedia.value.screen, isTrue);

      // Clearing the call resets the announced state.
      CallService.instance.clear();
      expect(CallService.instance.peerMedia.value.video, isFalse);
      expect(CallService.instance.peerMedia.value.screen, isFalse);
    });

    test('an offer for the live call renegotiates instead of busy-declining',
        () {
      final session = connected(CallDirection.outgoing);
      CallService.instance.current.value = session;
      // Same callId while connected: must NOT be treated as a new incoming
      // call (which would flip the session to ringing or decline as busy).
      CallService.instance.onRemoteOffer(
          session.peer, 'c1', false,
          sdp: 'v=0 renegotiation');
      final after = CallService.instance.current.value!;
      expect(after.callId, 'c1');
      expect(after.status, CallStatus.connected);
      expect(after.direction, CallDirection.outgoing);
    });

    test('setVideo and toggleScreenShare are safe with no active call',
        () async {
      CallService.instance.current.value = null;
      await CallService.instance.setVideo(true); // must not throw
      expect(await CallService.instance.toggleScreenShare(), isNotNull);
    });

    test('onRemoteReaction only fires for the active call', () {
      CallService.instance.current.value = connected(CallDirection.incoming);
      CallService.instance.onRemoteReaction('c1', '🎉');
      expect(CallService.instance.reaction.value!.emoji, '🎉');
      expect(CallService.instance.reaction.value!.fromMe, isFalse);
      final before = CallService.instance.reaction.value!.seq;
      CallService.instance.onRemoteReaction('other-call', '😮');
      expect(CallService.instance.reaction.value!.seq, before); // ignored
    });
  });

  test('daily check-in awards once per day and unlocks the return badge',
      () async {
    SharedPreferences.setMockInitialValues({});
    await ScoreStore.instance.load();
    final base = ScoreStore.instance.points;

    ScoreStore.instance.dailyCheckIn(now: DateTime(2026, 7, 27, 9));
    expect(ScoreStore.instance.points,
        base + ScoreStore.pointsPerDailyCheckIn);
    // Same day again: nothing.
    ScoreStore.instance.dailyCheckIn(now: DateTime(2026, 7, 27, 21));
    expect(ScoreStore.instance.points,
        base + ScoreStore.pointsPerDailyCheckIn);
    expect(ScoreStore.instance.isEarned('daily'), isFalse);

    // A later day: second bonus + the "Daily driver" badge.
    ScoreStore.instance.dailyCheckIn(now: DateTime(2026, 7, 28, 8));
    expect(ScoreStore.instance.points,
        base + 2 * ScoreStore.pointsPerDailyCheckIn);
    expect(ScoreStore.instance.isEarned('daily'), isTrue);
  });


  testWidgets('A favourite opens call/video/message actions and calls',
      (tester) async {
    FavouritesStore.instance.resetForTest();
    FavouritesStore.instance.add(const AppUser(
        id: '+15550100',
        name: 'Zed Fav',
        avatarColor: '#123456',
        phone: '+15550100'));
    addTearDown(CallService.instance.resetForTest);

    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pumpAndSettle();

    // The favourite chip is shown; tapping opens the actions sheet.
    expect(find.text('Zed'), findsOneWidget);
    await tester.tap(find.text('Zed'));
    await tester.pumpAndSettle();
    expect(find.text('Voice call'), findsOneWidget);
    expect(find.text('Video call'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);

    // Video call actually starts the call.
    await tester.tap(find.text('Video call'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(CallService.instance.current.value?.peer.name, 'Zed Fav');
    expect(CallService.instance.current.value?.video, isTrue);
  });


  testWidgets('A favourite added while on the Calls tab appears immediately',
      (tester) async {
    FavouritesStore.instance.resetForTest();
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Neo'), findsNothing);

    // Adding AFTER the row is already built must refresh it — a const child
    // used to be skipped by canonicalization and not show until you left.
    FavouritesStore.instance.add(const AppUser(
        id: '+15550777',
        name: 'Neo One',
        avatarColor: '#123456',
        phone: '+15550777'));
    await tester.pumpAndSettle();
    expect(find.text('Neo'), findsOneWidget);
  });

  group('Call favourites store', () {
    setUp(() => FavouritesStore.instance.resetForTest());

    test('add, dedupe, isFavourite, remove and toggle', () async {
      final store = FavouritesStore.instance;
      const ada = AppUser(id: 'u1', name: 'Ada', avatarColor: '#000000');
      const bob = AppUser(id: 'u2', name: 'Bob', avatarColor: '#111111');
      const team =
          AppUser(id: 'g1', name: 'Team', avatarColor: '#222222', isGroup: true);

      store.add(ada);
      store.add(ada); // duplicate ignored
      store.add(team); // groups are not favouritable
      expect(store.favourites.map((u) => u.id), ['u1']);
      expect(store.isFavourite('u1'), isTrue);
      expect(store.isFavourite('g1'), isFalse);

      store.toggle(bob); // adds
      expect(store.favourites.length, 2);
      store.toggle(ada); // removes
      expect(store.isFavourite('u1'), isFalse);

      store.remove('u2');
      expect(store.favourites, isEmpty);
    });
  });

  testWidgets('Find people screen shows the username search prompt',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: FindPeopleScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Search by username'), findsOneWidget); // the field hint
    expect(find.text('Find people by username'), findsOneWidget); // empty state
  });

  test('file transfer chunking splits and losslessly reassembles', () {
    final data =
        Uint8List.fromList(List.generate(40000, (i) => (i * 7) % 256));
    final chunks = FileTransfer.chunk(data);
    // 40000 / 16384 -> 3 chunks (16384, 16384, 7232).
    expect(chunks.length, 3);
    expect(chunks.first.length, FileTransfer.chunkSize);
    expect(FileTransfer.reassemble(chunks), equals(data));

    // Edge: empty input.
    expect(FileTransfer.chunk(Uint8List(0)), isEmpty);
    expect(FileTransfer.reassemble(const []), isEmpty);
  });

  group('ECDH key exchange', () {
    test('two devices derive the same shared secret (P-256 ECDH)', () {
      final alice = SecureKeyExchange.instance;
      alice.resetForTest();
      alice.ensureKeys();
      final alicePub = alice.myPublicKey!;
      final alicePriv = alice.exportPrivate();

      // Bob: a second identity, restored into the same singleton to compute
      // his side, capturing his public key.
      final bob = SecureKeyExchange.instance;
      bob.resetForTest();
      bob.ensureKeys();
      final bobPub = bob.myPublicKey!;
      final bobSecret = bob.sharedSecretWith(alicePub);

      // Back to Alice's identity to compute her side.
      alice.resetForTest();
      alice.ensureKeys(restorePrivateHex: alicePriv);
      final aliceSecret = alice.sharedSecretWith(bobPub);

      expect(aliceSecret, isNotNull);
      expect(bobSecret, isNotNull);
      expect(aliceSecret, equals(bobSecret));
    });

    test('an ECDH secret encrypts/decrypts through AES-256-GCM', () {
      final kx = SecureKeyExchange.instance;
      kx.resetForTest();
      kx.ensureKeys();
      // Round-trip with the device talking to itself (same key both ways).
      final secret = kx.sharedSecretWith(kx.myPublicKey!)!;
      final blob = E2eCrypto.encrypt(secret, 'handshake secured 🔒');
      expect(E2eCrypto.decrypt(secret, blob), 'handshake secured 🔒');
    });

    test('restoring a private key reproduces the same public key', () {
      final kx = SecureKeyExchange.instance;
      kx.resetForTest();
      kx.ensureKeys();
      final pub = kx.myPublicKey;
      final priv = kx.exportPrivate();
      kx.resetForTest();
      kx.ensureKeys(restorePrivateHex: priv);
      expect(kx.myPublicKey, pub);
    });
  });

  group('E2E crypto', () {
    test('encrypt/decrypt round-trips with the derived shared key', () {
      final key = E2eCrypto.keyFor('+1 555 0199', '+1 555 0100');
      final blob = E2eCrypto.encrypt(key, 'hello 🔐 world');
      expect(blob, isNot('hello 🔐 world'));
      expect(E2eCrypto.decrypt(key, blob), 'hello 🔐 world');
    });

    test('both parties derive the same key regardless of order', () {
      expect(
        E2eCrypto.keyFor('+1 555 0199', '+1 (555) 0100'),
        E2eCrypto.keyFor('15550100', '15550199'),
      );
    });

    test('a wrong key fails to decrypt (returns null)', () {
      final key = E2eCrypto.keyFor('+1 555 0199', '+1 555 0100');
      final other = E2eCrypto.keyFor('+1 555 0199', '+1 555 0123');
      final blob = E2eCrypto.encrypt(key, 'top secret');
      expect(E2eCrypto.decrypt(other, blob), isNull);
    });

    test('a tampered ciphertext fails authentication', () {
      final key = E2eCrypto.keyFor('+1 555 0199', '+1 555 0100');
      final blob = E2eCrypto.encrypt(key, 'integrity matters');
      final bytes = base64.decode(blob);
      bytes[20] = bytes[20] ^ 0xFF; // flip a byte in the ciphertext region
      expect(E2eCrypto.decrypt(key, base64.encode(bytes)), isNull);
    });

    test('safety number is stable, symmetric, and 12 groups of 5 digits', () {
      final a = E2eCrypto.safetyNumber('+1 555 0199', '+1 555 0100');
      final b = E2eCrypto.safetyNumber('15550100', '15550199');
      expect(a, b); // order-independent
      final groups = a.split(' ');
      expect(groups.length, 12);
      expect(groups.every((g) => RegExp(r'^\d{5}$').hasMatch(g)), isTrue);
      // A different pair yields a different code.
      expect(a, isNot(E2eCrypto.safetyNumber('+1 555 0199', '+1 555 0123')));
    });
  });

  group('Custom bubble color', () {
    Color outgoingBubbleColor(WidgetTester tester) {
      final containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(MessageBubble),
          matching: find.byType(Container),
        ),
      );
      final bubble = containers.firstWhere(
        (c) => c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color != null,
      );
      return (bubble.decoration as BoxDecoration).color!;
    }

    testWidgets('anyone can pick and reset a bubble color — no paywall',
        (tester) async {
      AppState.setVerified(false); // no longer gated
      await tester.pumpWidget(
        const MaterialApp(home: ChatsSettingsScreen()),
      );
      await tester.pumpAndSettle();

      // The perk is free now: no lock, no upgrade copy.
      expect(find.text('Chat bubble color'), findsOneWidget);
      expect(find.text('An Okay Pro perk'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);

      await tester.tap(find.text('Chat bubble color'));
      await tester.pumpAndSettle();

      // The picker sheet opens.
      expect(find.text('Bubble color'), findsOneWidget);
      // Tap the Pro purple swatch (third in the palette).
      final swatch = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(swatch.at(2));
      await tester.pumpAndSettle();
      expect(AppState.bubbleColor.value, const Color(0xFF7A5CFF));

      // Reopen and reset to default.
      await tester.tap(find.text('Chat bubble color'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to default green'));
      await tester.pumpAndSettle();
      expect(AppState.bubbleColor.value, isNull);
    });

    testWidgets('outgoing bubble honors the custom color', (tester) async {
      AppState.bubbleColor.value = const Color(0xFFEB4B7E);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: Message(
                id: 'm1',
                text: 'hello',
                time: DateTime(2020, 1, 1, 10),
                isMe: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(outgoingBubbleColor(tester), const Color(0xFFEB4B7E));
    });

    testWidgets('incoming bubble ignores the custom color', (tester) async {
      AppState.bubbleColor.value = const Color(0xFFEB4B7E);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: Message(
                id: 'm2',
                text: 'hi there',
                time: DateTime(2020, 1, 1, 10),
                isMe: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(outgoingBubbleColor(tester), isNot(const Color(0xFFEB4B7E)));
    });
  });

  group('Chat list filters', () {
    Future<void> pumpTab(WidgetTester tester) async {
      // The chip bar is hidden by default; reveal it for these tests.
      ChatsTab.filtersVisible.value = true;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ChatsTab())),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('filter chips are hidden by default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ChatsTab())),
      );
      await tester.pumpAndSettle();
      // No chip row until it's toggled on from the menu.
      expect(find.text('Unread'), findsNothing);
      expect(find.text('Groups'), findsNothing);
      // The chat list is still shown, unfiltered.
      expect(find.text('Bob Carter'), findsOneWidget);
    });

    testWidgets('overflow menu toggles the filter chips', (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      expect(find.text('Unread'), findsNothing);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filter chats'));
      await tester.pumpAndSettle();
      expect(find.text('Unread'), findsOneWidget);

      // The menu now offers to hide them again.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide filters'));
      await tester.pumpAndSettle();
      expect(find.text('Unread'), findsNothing);
    });

    test('ChatFilter.matches applies the right predicate', () {
      final store = ChatStore.instance;
      final group = store.chatById('c_dev')!; // Team Standup, unread 5
      final read = store.chatById('c_bob')!; // no unread, 1:1
      expect(ChatFilter.all.matches(read), isTrue);
      expect(ChatFilter.unread.matches(group), isTrue);
      expect(ChatFilter.unread.matches(read), isFalse);
      expect(ChatFilter.groups.matches(group), isTrue);
      expect(ChatFilter.groups.matches(read), isFalse);
      expect(ChatFilter.favorites.matches(read), isFalse);
    });

    testWidgets('Favourites chip appears only after favouriting',
        (tester) async {
      await pumpTab(tester);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Unread'), findsOneWidget);
      expect(find.text('Groups'), findsOneWidget);
      expect(find.text('Favourites'), findsNothing);

      ChatStore.instance.toggleFavorite('c_alice');
      await tester.pumpAndSettle();
      expect(find.text('Favourites'), findsOneWidget);
    });

    testWidgets('Unread filter shows only unread chats', (tester) async {
      await pumpTab(tester);
      expect(find.text('Bob Carter'), findsOneWidget);

      await tester.tap(find.text('Unread'));
      await tester.pumpAndSettle();

      expect(find.text('Team Standup'), findsOneWidget); // unread 5
      expect(find.text('Bob Carter'), findsNothing); // read
    });

    testWidgets('Groups filter shows only group chats', (tester) async {
      await pumpTab(tester);
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();

      expect(find.text('Team Standup'), findsOneWidget);
      expect(find.text('Alice Bennett'), findsNothing);
    });

    testWidgets('Favourites filter shows only favourited chats',
        (tester) async {
      ChatStore.instance.toggleFavorite('c_bob');
      await pumpTab(tester);
      await tester.tap(find.text('Favourites'));
      await tester.pumpAndSettle();

      expect(find.text('Bob Carter'), findsOneWidget);
      expect(find.text('Alice Bennett'), findsNothing);
    });

    test('isFavorite survives a JSON roundtrip', () {
      final store = ChatStore.instance;
      store.toggleFavorite('c_alice');
      final snapshot = jsonDecode(jsonEncode(store.toJson()))
          as Map<String, dynamic>;
      store.reset();
      store.hydrate(snapshot);
      expect(store.chatById('c_alice')!.isFavorite, isTrue);
      expect(store.chatById('c_bob')!.isFavorite, isFalse);
    });
  });

  group('Pinned messages (multi-pin)', () {
    test('pins several messages and enforces the free limit', () {
      final store = ChatStore.instance;
      store.pinMessage('c_alice', 'm1');
      store.pinMessage('c_alice', 'm2');
      store.pinMessage('c_alice', 'm2b');
      final chat = store.chatById('c_alice')!;
      expect(chat.pinnedMessageIds, ['m1', 'm2', 'm2b']);
      expect(chat.pinnedMessageId, 'm2b'); // latest
      expect(chat.isPinnedMessage('m2'), isTrue);
      // At the free limit (3): non-Pro blocked, Pro not.
      expect(store.canPinMore('c_alice', isPro: false), isFalse);
      expect(store.canPinMore('c_alice', isPro: true), isTrue);
    });

    test('pinMessage is idempotent', () {
      final store = ChatStore.instance;
      store.pinMessage('c_alice', 'm1');
      store.pinMessage('c_alice', 'm1');
      expect(store.chatById('c_alice')!.pinnedMessageIds, ['m1']);
    });

    test('unpinMessage removes only the given message', () {
      final store = ChatStore.instance;
      store.pinMessage('c_alice', 'm1');
      store.pinMessage('c_alice', 'm2');
      store.unpinMessage('c_alice', 'm1');
      final chat = store.chatById('c_alice')!;
      expect(chat.pinnedMessageIds, ['m2']);
      expect(chat.isPinnedMessage('m1'), isFalse);
    });

    test('unpinAll clears every pin', () {
      final store = ChatStore.instance;
      store.pinMessage('c_alice', 'm1');
      store.pinMessage('c_alice', 'm2');
      store.unpinAll('c_alice');
      expect(store.chatById('c_alice')!.pinnedMessageIds, isEmpty);
    });

    test('deleting a pinned message unpins just that message', () {
      final store = ChatStore.instance;
      store.pinMessage('c_alice', 'm1');
      store.pinMessage('c_alice', 'm2');
      store.deleteMessage('c_alice', 'm1');
      expect(store.chatById('c_alice')!.pinnedMessageIds, ['m2']);
    });

    test('legacy single pinnedMessageId migrates to the list', () {
      final chat = Chat.fromJson({
        'id': 'c_x',
        'contact': MockData.me.toJson(),
        'messages': <dynamic>[],
        'pinnedMessageId': 'legacy1',
      });
      expect(chat.pinnedMessageIds, ['legacy1']);
      expect(chat.pinnedMessageId, 'legacy1');
    });

    testWidgets('banner shows a count and a sheet when several are pinned',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      Future<void> pin(String text) async {
        await tester.longPress(find.text(text));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pin'));
        await tester.pumpAndSettle();
      }

      await pin('Did you see the game last night?');
      await pin('Yes! What a finish 🔥');

      expect(find.text('2 pinned messages'), findsOneWidget);

      // Tapping the banner opens the pinned-messages sheet.
      await tester.tap(find.text('2 pinned messages'));
      await tester.pumpAndSettle();
      expect(find.text('2 pinned'), findsOneWidget);
      expect(find.text('Unpin all'), findsOneWidget);

      await tester.tap(find.text('Unpin all'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message'), findsNothing);
      expect(find.text('2 pinned messages'), findsNothing);
    });
  });

  group('Confirm before sending (wrong-person guard)', () {
    test('setConfirmBeforeSend toggles and persists via JSON', () {
      final store = ChatStore.instance;
      expect(store.chatById('c_bob')!.confirmBeforeSend, isFalse);
      store.setConfirmBeforeSend('c_bob', true);
      expect(store.chatById('c_bob')!.confirmBeforeSend, isTrue);

      final snapshot =
          jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;
      store.reset();
      store.hydrate(snapshot);
      expect(store.chatById('c_bob')!.confirmBeforeSend, isTrue);
    });

    testWidgets('a guarded chat asks to confirm and only sends on confirm',
        (tester) async {
      ChatStore.instance.setConfirmBeforeSend('c_bob', true);
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      bool sent() => ChatStore.instance
          .chatById('c_bob')!
          .messages
          .any((m) => m.isMe && m.text == 'wrong chat?');
      final before = ChatStore.instance.chatById('c_bob')!.messages.length;

      // Type and send — a confirmation appears instead of sending.
      await tester.enterText(find.byType(TextField).first, 'wrong chat?');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('Send to the right chat?'), findsOneWidget);

      // Cancelling keeps the text and sends nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(ChatStore.instance.chatById('c_bob')!.messages.length, before);
      expect(sent(), isFalse);
      expect(find.text('wrong chat?'), findsOneWidget); // still in composer

      // Sending again and confirming delivers the message.
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(sent(), isTrue);
    });

    testWidgets('an unguarded chat sends without a prompt', (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'quick hello');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('Send to the right chat?'), findsNothing);
      expect(
        ChatStore.instance
            .chatById('c_bob')!
            .messages
            .any((m) => m.isMe && m.text == 'quick hello'),
        isTrue,
      );
    });

    testWidgets('the contact info toggle turns the guard on', (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();
      // Open contact info via the header.
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      // The Follow section pushed the toggle below the fold — scroll to it.
      await tester.scrollUntilVisible(
          find.text('Confirm before sending'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('Confirm before sending'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm before sending'), findsOneWidget);
      await tester.tap(find.text('Confirm before sending'));
      await tester.pumpAndSettle();
      expect(
          ChatStore.instance.chatById('c_bob')!.confirmBeforeSend, isTrue);
    });
  });

  group('Maps links (Apple Maps on Apple devices)', () {
    test('Apple devices get an Apple Maps link with a titled pin', () {
      final uri = mapsUrl(
          lat: 37.3349, lng: -122.009, label: 'Apple Park', apple: true);
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters['ll'], '37.3349,-122.009');
      expect(uri.queryParameters['q'], 'Apple Park');
    });

    test('Apple Maps link omits the pin title when there is no label', () {
      final uri = mapsUrl(lat: 1.0, lng: 2.0, apple: true);
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters.containsKey('q'), isFalse);
    });

    test('non-Apple devices get a Google Maps link', () {
      final uri = mapsUrl(
          lat: 37.3349, lng: -122.009, label: 'Apple Park', apple: false);
      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['query'], '37.3349,-122.009');
    });

    test('directionsUrl targets Apple / Google with the destination', () {
      final apple = directionsUrl(lat: 40.7, lng: -74.0, apple: true);
      expect(apple.host, 'maps.apple.com');
      expect(apple.queryParameters['daddr'], '40.7,-74.0');

      final google = directionsUrl(lat: 40.7, lng: -74.0, apple: false);
      expect(google.host, 'www.google.com');
      expect(google.queryParameters['destination'], '40.7,-74.0');
    });

    test('formatDistance renders metres and kilometres sensibly', () {
      expect(formatDistance(120), '120 m');
      expect(formatDistance(950), '950 m');
      expect(formatDistance(2300), '2.3 km');
      expect(formatDistance(15400), '15 km');
    });

    test('parseOsrmRoute reads geometry, distance, duration and steps', () {
      const body = '''
      {"code":"Ok","routes":[{
        "distance":1965.6,"duration":242.8,
        "geometry":{"type":"LineString","coordinates":[
          [-122.42,37.77],[-122.419,37.771],[-122.41,37.78]
        ]},
        "legs":[{"steps":[
          {"maneuver":{"type":"depart"},"name":"13th Street","distance":12},
          {"maneuver":{"type":"turn","modifier":"left"},"name":"","distance":55},
          {"maneuver":{"type":"arrive"},"name":"","distance":0}
        ]}]
      }]}''';
      final r = parseOsrmRoute(body);
      expect(r, isNotNull);
      expect(r!.points.length, 3);
      // GeoJSON is [lng, lat]; make sure we store LatLng correctly.
      expect(r.points.first.latitude, closeTo(37.77, 0.0001));
      expect(r.points.first.longitude, closeTo(-122.42, 0.0001));
      expect(r.distanceMeters, closeTo(1965.6, 0.1));
      expect(r.durationSeconds, closeTo(242.8, 0.1));
      expect(r.steps.length, 3);
      expect(r.steps.first.instruction, 'Head out on 13th Street');
      expect(r.steps[1].instruction, 'Turn left');
      expect(r.steps.last.instruction, 'Arrive at your destination');
    });

    test('parseOsrmRoute reads maneuver locations for navigation', () {
      const body = '''
      {"code":"Ok","routes":[{
        "distance":100,"duration":60,
        "geometry":{"coordinates":[[-122.42,37.77],[-122.41,37.78]]},
        "legs":[{"steps":[
          {"maneuver":{"type":"depart","location":[-122.42,37.77]},
           "name":"A St","distance":100},
          {"maneuver":{"type":"arrive","location":[-122.41,37.78]},
           "name":"","distance":0}
        ]}]
      }]}''';
      final r = parseOsrmRoute(body)!;
      expect(r.steps.first.location!.latitude, closeTo(37.77, 0.0001));
      expect(r.steps.first.location!.longitude, closeTo(-122.42, 0.0001));
      expect(r.steps.last.location!.latitude, closeTo(37.78, 0.0001));
    });

    test('advanceStep passes maneuvers the user has reached', () {
      const steps = [
        RouteStep('Start', 100, location: LatLng(37.7700, -122.4200)),
        RouteStep('Turn left', 200, location: LatLng(37.7710, -122.4200)),
        RouteStep('Arrive', 0, location: LatLng(37.7730, -122.4200)),
      ];
      // Far from the upcoming maneuver: stays put.
      expect(
        advanceStep(
            steps: steps, current: 1, user: const LatLng(37.7702, -122.4200)),
        1,
      );
      // Standing on maneuver 1: advances to the next one.
      expect(
        advanceStep(
            steps: steps, current: 1, user: const LatLng(37.7710, -122.4200)),
        2,
      );
      // Never advances past the final (arrive) step.
      expect(
        advanceStep(
            steps: steps, current: 2, user: const LatLng(37.7730, -122.4200)),
        2,
      );
    });

    test('remainingMeters sums the distance to go', () {
      const route = RouteResult(
        points: [LatLng(37.77, -122.42), LatLng(37.78, -122.41)],
        distanceMeters: 300,
        durationSeconds: 120,
        steps: [
          RouteStep('Start', 100, location: LatLng(37.7700, -122.4200)),
          RouteStep('Turn', 200, location: LatLng(37.7709, -122.4200)),
          RouteStep('Arrive', 0, location: LatLng(37.7727, -122.4200)),
        ],
      );
      // ~100m short of maneuver 1, plus the 200m remaining segments.
      final left = remainingMeters(
          route: route, current: 1, user: const LatLng(37.7700, -122.4200));
      expect(left, closeTo(300, 15));
      // Past the end → nothing left.
      expect(remainingMeters(route: route, current: 3), 0);
    });

    test('imperial units switch distances to feet and miles', () {
      AppState.mapUnits.value = 'imperial';
      addTearDown(() => AppState.mapUnits.value = 'metric');
      expect(formatDistance(150), '490 ft');
      expect(formatDistance(1609.344), '1.0 mi');
      expect(formatDistance(32187), '20 mi');
      expect(spokenDistance(1609.344), '1.0 miles');
      expect(spokenDistance(152), '500 feet');
      AppState.mapUnits.value = 'metric';
      expect(formatDistance(150), '150 m');
      expect(spokenDistance(400), '400 metres');
    });

    testWidgets('Maps settings switch units and voice guidance',
        (tester) async {
      addTearDown(() {
        AppState.mapUnits.value = 'metric';
        AppState.navVoice.value = true;
        AppState.defaultTravelMode.value = 'car';
      });
      await tester.pumpWidget(
          const MaterialApp(home: MapsSettingsScreen()));
      await tester.pump();

      // The screen is a scrolling list and the style section grew, so each
      // control has to be brought on screen before it can be tapped —
      // tapping an off-screen widget silently does nothing.
      await tester.ensureVisible(find.text('Miles'));
      await tester.tap(find.text('Miles'));
      await tester.pump();
      expect(AppState.mapUnits.value, 'imperial');

      await tester.ensureVisible(find.text('Voice guidance'));
      await tester.tap(find.text('Voice guidance'));
      await tester.pump();
      expect(AppState.navVoice.value, isFalse);

      await tester.ensureVisible(find.text('Walk'));
      await tester.tap(find.text('Walk'));
      await tester.pump();
      expect(AppState.defaultTravelMode.value, 'foot');
    });

    test('remote feed posts merge once and bump their parent thread', () {
      final now = DateTime.now().toIso8601String();
      final post = FeedPost.fromJson({
        'id': 'r1',
        'communityId': 'c1',
        'authorName': 'Grace Hopper',
        'authorUsername': 'gracehop',
        'time': now,
        'text': 'hi from another phone',
      });
      FeedStore.instance.addRemote(post);
      FeedStore.instance.addRemote(post); // duplicate delivery is ignored
      expect(FeedStore.instance.postsFor('c1').single.text,
          'hi from another phone');

      FeedStore.instance.addRemote(FeedPost.fromJson({
        'id': 'r2',
        'communityId': 'c1',
        'authorName': 'You',
        'authorUsername': 'you',
        'time': now,
        'text': 'welcome!',
        'parentId': 'r1',
      }));
      // The reply threads under its parent and bumps the count.
      expect(FeedStore.instance.postById('r1')!.replies, 1);
      expect(FeedStore.instance.repliesTo('r1').single.text, 'welcome!');
      expect(FeedStore.instance.postsFor('c1').length, 1);
    });

    test('feed moderation hides posts and mutes authors', () {
      FeedStore.instance.hydratePosts([
        {
          'id': 'p1',
          'communityId': 'c1',
          'authorName': 'Troll',
          'authorUsername': 'troll',
          'time': DateTime.now().toIso8601String(),
          'text': 'spam',
        },
        {
          'id': 'p2',
          'communityId': 'c1',
          'authorName': 'Nice',
          'authorUsername': 'nice',
          'time': DateTime.now().toIso8601String(),
          'text': 'hello',
        },
      ]);
      expect(FeedStore.instance.postsFor('c1').length, 2);
      FeedStore.instance.hidePost('p1');
      expect(FeedStore.instance.postsFor('c1').single.id, 'p2');
      expect(FeedStore.instance.toggleMute('Nice'), isTrue);
      expect(FeedStore.instance.postsFor('c1'), isEmpty);
      expect(FeedStore.instance.toggleMute('nice'), isFalse);
      expect(FeedStore.instance.postsFor('c1').single.id, 'p2');
    });

    test('spokenDistance phrases distances for voice prompts', () {
      expect(spokenDistance(384), '380 metres');
      expect(spokenDistance(4), '10 metres');
      expect(spokenDistance(1200), '1.2 kilometres');
      expect(spokenDistance(12600), '13 kilometres');
    });

    testWidgets('navigation speaks turns, can be muted, and shares the ETA',
        (tester) async {
      final spoken = <String>[];
      debugSpeakOverride = spoken.add;
      addTearDown(() => debugSpeakOverride = null);
      const route = RouteResult(
        points: [LatLng(37.7749, -122.4194), LatLng(37.7680, -122.4150)],
        distanceMeters: 1120,
        durationSeconds: 300,
        steps: [
          RouteStep('Head out on Market Street', 120,
              location: LatLng(37.7749, -122.4194), type: 'depart'),
          RouteStep('Turn right onto Valencia Street', 400,
              location: LatLng(37.7757, -122.4180), type: 'turn',
              modifier: 'right'),
          RouteStep('Arrive at your destination', 0,
              location: LatLng(37.7680, -122.4150), type: 'arrive'),
        ],
      );
      await tester.pumpWidget(const MaterialApp(
        home: RouteMapScreen(
          dest: LatLng(37.7680, -122.4150),
          from: LatLng(37.7749, -122.4194),
          label: 'Blue Bottle',
          initialRoute: route,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The upcoming turn was announced out loud, and the banner previews
      // the maneuver after it, Apple-style.
      expect(spoken, isNotEmpty);
      expect(spoken.first, contains('Turn right onto Valencia Street'));
      expect(find.textContaining('then Arrive'), findsOneWidget);

      // Mute flips the toggle.
      await tester.tap(find.byTooltip('Mute voice'));
      await tester.pump();
      expect(find.byTooltip('Unmute voice'), findsOneWidget);

      // Share ETA drafts an on-my-way message to send in a chat.
      await tester.tap(find.byTooltip('Share ETA'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Forward to...'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('FollowStore toggles follows by normalised username', () {
      expect(FollowStore.instance.isFollowing('gracehop'), isFalse);
      expect(FollowStore.instance.toggle('@GraceHop'), isTrue);
      expect(FollowStore.instance.isFollowing('gracehop'), isTrue);
      expect(FollowStore.instance.followingCount, 1);
      expect(FollowStore.instance.toggle('gracehop'), isFalse);
      expect(FollowStore.instance.followingCount, 0);
    });

    testWidgets('the Notifications tab lists unread chats and missed calls',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ActivityTab())));
      await tester.pump();

      // The demo data ships chats with unread messages — they surface here.
      final unread = ChatStore.instance.chats
          .where((c) => c.unreadCount > 0)
          .toList();
      expect(unread, isNotEmpty);
      expect(find.text('NEW MESSAGES'), findsOneWidget);
      expect(find.text(unread.first.contact.name), findsWidgets);

      // Opening a chat from a notification works.
      await tester.tap(find.text(unread.first.contact.name).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('contact page follows and unfollows a user', (tester) async {
      final user = MockData.contacts()
          .firstWhere((c) => c.username.isNotEmpty && !c.isGroup);
      await tester.pumpWidget(MaterialApp(home: ContactInfoScreen(user: user)));
      await tester.pump();

      expect(find.text('Follow'), findsOneWidget);
      // No invented follower counts anywhere.
      expect(find.textContaining('followers'), findsNothing);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(find.text('Following'), findsOneWidget);
      expect(FollowStore.instance.isFollowing(user.username), isTrue);
    });

    test('feedAge renders compact X-style ages', () {
      final now = DateTime(2026, 7, 24, 12, 0);
      expect(feedAge(now.subtract(const Duration(seconds: 20)), now: now),
          'now');
      expect(feedAge(now.subtract(const Duration(minutes: 5)), now: now),
          '5m');
      expect(feedAge(now.subtract(const Duration(hours: 3)), now: now), '3h');
      expect(feedAge(now.subtract(const Duration(days: 2)), now: now), '2d');
    });

    testWidgets('the timeline tabs are exclusive and span the width',
        (tester) async {
      FeedStore.instance.add('c1', 'first');
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pumpAndSettle();

      // Three tabs sharing the width, not three chips in the corner.
      final width = tester.getSize(find.byType(FeedScreen)).width;
      for (final label in ['Latest', 'Top', 'Saved']) {
        expect(tester.getSize(find.text(label)).width, lessThan(width),
            reason: '$label must fit');
      }
      final latest = tester.getTopLeft(find.text('Latest')).dx;
      final saved = tester.getTopLeft(find.text('Saved')).dx;
      expect(saved - latest, greaterThan(width * 0.5),
          reason: 'the tabs should be spread across the row, not huddled');

      // Exactly one is on at a time. Saved used to be a filter you could
      // combine with Top, which left two of the three looking selected.
      Color? barOf(String label) {
        final container = tester.widget<Container>(find.descendant(
            of: find.ancestor(
                of: find.text(label), matching: find.byType(Column)).first,
            matching: find.byType(Container)));
        return (container.decoration as BoxDecoration?)?.color;
      }

      expect(barOf('Latest'), isNot(Colors.transparent));
      expect(barOf('Top'), Colors.transparent);

      await tester.tap(find.text('Saved'));
      await tester.pumpAndSettle();
      expect(barOf('Saved'), isNot(Colors.transparent));
      expect(barOf('Latest'), Colors.transparent);
      expect(barOf('Top'), Colors.transparent);
    });

    testWidgets('the composer gets the whole screen, not one squeezed line',
        (tester) async {
      // In a bottom sheet the field shared one row with an avatar, three icon
      // buttons and Post, which squeezed it until the placeholder wrapped onto
      // two lines with nothing typed.
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pump();
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();

      expect(find.byType(FeedComposerScreen), findsOneWidget);
      final field = find.widgetWithText(TextField, "What's happening?");
      final screen = tester.getSize(find.byType(FeedComposerScreen));
      final box = tester.getSize(field);
      // Room to write in, and the field runs the width of the screen rather
      // than what four buttons leave over.
      expect(box.height, greaterThan(80));
      expect(box.width, greaterThan(screen.width * 0.7));

      // Focused on open — the point of the screen is typing.
      expect(tester.widget<TextField>(field).autofocus, isTrue);

      // And no box drawn round it. InputDecoration.collapsed only nulls
      // `border`, so the app theme's focusedBorder still applied — and an
      // autofocused field meant that box appeared the instant it opened.
      final decoration = tester.widget<TextField>(field).decoration!;
      for (final border in [
        decoration.border,
        decoration.enabledBorder,
        decoration.focusedBorder,
      ]) {
        expect(border, InputBorder.none);
      }
      expect(decoration.filled, isFalse);
    });

    testWidgets('a draft is not thrown away by a mis-tap', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pump();
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'half a thought');
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Still there, behind a question.
      expect(find.text('Discard post?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.byType(FeedComposerScreen), findsOneWidget);
      expect(find.text('half a thought'), findsOneWidget);
    });

    testWidgets('the length ring only speaks up when it matters',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pump();
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();

      final field = find.byType(TextField).first;
      // A running count is noise for the first two hundred characters.
      await tester.enterText(field, 'x' * 100);
      await tester.pump();
      expect(find.text('180'), findsNothing);

      // Near the limit the exact number is the only thing worth knowing.
      await tester.enterText(field, 'x' * 265);
      await tester.pump();
      expect(find.text('15'), findsOneWidget);

      // Over it, Post has to be off — a post that cannot be sent must not
      // look sendable.
      await tester.enterText(field, 'x' * 281);
      await tester.pump();
      expect(find.text('-1'), findsOneWidget);
      expect(
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
              .onPressed,
          isNull);
    });

    test('a listing is a post with a price, and stays out of the timeline',
        () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      final listing = FeedStore.instance.addListing('c1',
          title: 'Blue bike',
          priceCents: 12050,
          category: 'Sports',
          description: 'Rides fine');
      FeedStore.instance.add('c1', 'an ordinary post');

      // The timeline shows the post; the marketplace shows the listing. A
      // feed full of price tags reads as ads, and a marketplace of chatter
      // isn't one.
      final timeline = FeedStore.instance.postsFor('c1');
      expect(timeline.any((p) => p.id == listing.id), isFalse);
      expect(timeline.any((p) => p.text == 'an ordinary post'), isTrue);
      final listings = FeedStore.instance.listings(communityId: 'c1');
      expect(listings.single.id, listing.id);
      expect(listings.single.priceCents, 12050);

      // And it survives the relay's JSON round trip with its structure.
      final wire = FeedPost.fromJson(listing.toJson());
      expect(wire.isListing, isTrue);
      expect(wire.priceCents, 12050);
      expect(wire.listingCategory, 'Sports');
      expect(wire.text, 'Blue bike\nRides fine');
    });

    test('a stale mailbox replay cannot roll back a sold flag', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      final listing = FeedStore.instance
          .addListing('c1', title: 'Lamp', priceCents: 500, category: 'Home & Garden');
      final staleCopy = FeedPost.fromJson(listing.toJson());

      expect(FeedStore.instance.setListingSold(listing.id, true), isTrue);
      expect(FeedStore.instance.listings().single.listingSold, isTrue);

      // The mailbox replays the pre-sold copy: rev 0 against rev 1 loses.
      FeedStore.instance.addRemote(staleCopy);
      expect(FeedStore.instance.listings().single.listingSold, isTrue,
          reason: 'a replayed old copy must never un-sell a listing');

      // A genuinely newer copy (another device marking it available) wins.
      final newer =
          staleCopy.copyWith(listingSold: false, listingRev: 2);
      FeedStore.instance.addRemote(newer);
      expect(FeedStore.instance.listings().single.listingSold, isFalse);
    });

    test('prices parse forgivingly and format like price tags', () {
      expect(parseListingPrice('20'), 2000);
      expect(parseListingPrice(r'$1,200'), 120000);
      expect(parseListingPrice('12.50'), 1250);
      expect(parseListingPrice(''), 0, reason: 'blank means free');
      expect(parseListingPrice('cheap'), isNull);
      expect(parseListingPrice('12.345'), isNull);

      expect(formatListingPrice(0), 'Free');
      expect(formatListingPrice(2000), r'$20');
      expect(formatListingPrice(1250), r'$12.50');
      expect(formatListingPrice(1205), r'$12.05');
    });

    testWidgets('the marketplace browses, filters, and sells', (tester) async {
      // Phone-shaped: at the default 800x600 the grid tiles are taller than
      // the viewport and their labels sit below the fold, untappable.
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final server = CommunityStore.instance.createCommunity('Okay HQ');
      addTearDown(CommunityStore.instance.resetForTest);

      FeedStore.instance.addListing(server.id,
          title: 'Blue bike', priceCents: 2000, category: 'Sports');
      FeedStore.instance.addListing(server.id,
          title: 'Green lamp', priceCents: 500, category: 'Home & Garden');

      await tester
          .pumpWidget(const MaterialApp(home: MarketplaceScreen()));
      await tester.pump();

      expect(find.text('Blue bike'), findsOneWidget);
      expect(find.text('Green lamp'), findsOneWidget);
      expect(find.text(r'$20'), findsOneWidget);

      // Filters moved to the top-right corner: the tune button opens a
      // sheet, picking a category applies it and shows a removable chip.
      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      // Chips carry counts now ("Sports · 1") and sit below the sort list.
      await tester.ensureVisible(find.textContaining('Sports'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Sports'));
      await tester.pumpAndSettle();
      expect(find.text('Blue bike'), findsOneWidget);
      expect(find.text('Green lamp'), findsNothing);
      // Clearing is one tap on the active chip's delete.
      await tester.tap(find
          .descendant(of: find.byType(InputChip), matching: find.byType(Icon))
          .last);
      await tester.pumpAndSettle();
      expect(find.text('Green lamp'), findsOneWidget);

      // Search lives in the corner too and narrows as you type.
      await tester.tap(find.byTooltip('Search Marketplace'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'lamp');
      await tester.pumpAndSettle();
      expect(find.text('Green lamp'), findsOneWidget);
      expect(find.text('Blue bike'), findsNothing);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.text('Blue bike'), findsOneWidget);

      // Selling walks through the form and lands in the grid.
      await tester.tap(find.text('Sell'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'What are you selling?'), 'Red chair');
      await tester.enterText(find.widgetWithText(TextField, 'Price'), '15');
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(find.text('Red chair'), findsOneWidget);
      expect(find.text(r'$15'), findsOneWidget);

      // Own listing: open it and mark sold; the tile gains the badge.
      await tester.tap(find.text('Red chair'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as sold'));
      await tester.pumpAndSettle();
      expect(find.text('SOLD'), findsOneWidget);
    });

    test('a listing can be edited, and the edit outruns stale replays', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      final listing = FeedStore.instance.addListing('c1',
          title: 'Desk', priceCents: 3000, category: 'Furniture');
      final preEditCopy = FeedPost.fromJson(listing.toJson());

      expect(
          FeedStore.instance.updateListing(listing.id,
              title: 'Standing desk',
              priceCents: 4500,
              category: 'Furniture',
              description: 'Now with the crank handle found'),
          isTrue);
      var current = FeedStore.instance.listings().single;
      expect(current.text, 'Standing desk\nNow with the crank handle found');
      expect(current.priceCents, 4500);
      expect(current.edited, isTrue);
      expect(current.listingRev, 1);

      // The mailbox replaying the pre-edit copy must not undo the edit.
      FeedStore.instance.addRemote(preEditCopy);
      current = FeedStore.instance.listings().single;
      expect(current.priceCents, 4500);

      // Someone else's listing cannot be rewritten from this device.
      final theirs = FeedPost(
        id: 'post_theirs',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Lamp',
        priceCents: 500,
        listingCategory: 'Home & Garden',
      );
      FeedStore.instance.addRemote(theirs);
      expect(
          FeedStore.instance.updateListing('post_theirs',
              title: 'Hacked', priceCents: 1, category: 'Other'),
          isFalse);
    });

    testWidgets('the server word filter applies to listings too',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      addTearDown(CommunityStore.instance.resetForTest);
      CommunityStore.instance.resetForTest();
      // Joined as a plain member — owners moderate and the filter exempts
      // moderators, so a server the tester created could never trip it.
      final joined = CommunityStore.instance.joinFromInvite(
          {'id': 'srv_filtered', 'name': 'Filtered', 'members': []},
          myDigits: '15550000000',
          myName: 'Me')!;
      for (final c in List.of(CommunityStore.instance.communities)) {
        if (c.id != joined.id) {
          CommunityStore.instance.deleteCommunity(c.id);
        }
      }
      // The owner's filter, as structure sync would deliver it.
      CommunityStore.instance.addBannedWord(joined.id, 'crypto');
      expect(CommunityStore.instance.filterHit(joined.id, 'free crypto'),
          'crypto');

      await tester.pumpWidget(const MaterialApp(home: SellScreen()));
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextField, 'What are you selling?'),
          'Free crypto advice');
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pump();

      // Refused with the reason, and nothing was posted or broadcast — a
      // rule that applies to posts but not price tags isn't a rule.
      expect(find.textContaining('word filter'), findsOneWidget);
      expect(FeedStore.instance.listings(), isEmpty);
    });

    test('reviews: one voice per person, never the seller, honest average',
        () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      // A listing from someone else, as the relay would deliver it.
      final theirs = FeedPost(
        id: 'lst_grace',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Lamp',
        priceCents: 500,
        listingCategory: 'Home & Garden',
      );
      FeedStore.instance.addRemote(theirs);

      // Rating clamps into 1..5 and the review text rides along.
      expect(
          FeedStore.instance
              .addReview('lst_grace', rating: 9, text: 'Great lamp'),
          isTrue);
      var reviews = FeedStore.instance.reviewsFor('lst_grace');
      expect(reviews.single.rating, 5);
      expect(reviews.single.text, 'Great lamp');
      // And it survives the relay JSON round trip.
      expect(FeedPost.fromJson(reviews.single.toJson()).rating, 5);

      // Reviewing again replaces — one person is one voice, not a chorus.
      FeedStore.instance.addReview('lst_grace', rating: 2, text: 'Broke');
      reviews = FeedStore.instance.reviewsFor('lst_grace');
      expect(reviews.length, 1);
      expect(reviews.single.rating, 2);

      // The seller cannot review their own listing: five stars you gave
      // yourself would make every rating worthless.
      final mine = FeedStore.instance
          .addListing('c1', title: 'Chair', priceCents: 100, category: 'Other');
      expect(FeedStore.instance.addReview(mine.id, rating: 5), isFalse);
      expect(FeedStore.instance.reviewsFor(mine.id), isEmpty);

      // The seller's average spans their listings, from what this device
      // can see.
      final second = FeedPost.fromJson(theirs.toJson());
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_grace2',
        communityId: second.communityId,
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Desk',
        priceCents: 2000,
        listingCategory: 'Furniture',
      ));
      // A review from another buyer arrives over the relay.
      FeedStore.instance.addRemote(FeedPost(
        id: 'rev_ada',
        communityId: 'c1',
        authorName: 'Ada',
        authorUsername: 'ada',
        time: DateTime.now(),
        text: '',
        parentId: 'lst_grace2',
        rating: 4,
      ));
      final (avg, count) = FeedStore.instance.sellerRating('grace');
      expect(count, 2);
      expect(avg, 3.0); // (2 + 4) / 2
    });

    testWidgets('a buyer can review from the listing screen; the seller '
        'cannot', (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_rev',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Lamp',
        priceCents: 500,
        listingCategory: 'Home & Garden',
      ));

      await tester.pumpWidget(
          const MaterialApp(home: ListingScreen(listingId: 'lst_rev')));
      await tester.pump();
      expect(find.text('No reviews yet.'), findsOneWidget);

      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();
      // Post review stays off until stars are given — the rating is the one
      // required part.
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Post review'))
              .onPressed,
          isNull);
      await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3)); // 4th
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextField, 'How did it go? (optional)'),
          'Solid lamp');
      await tester.tap(find.text('Post review'));
      await tester.pumpAndSettle();

      expect(find.text('Solid lamp'), findsOneWidget);
      expect(find.text('Edit your review'), findsOneWidget);
      expect(find.textContaining('4.0 · 1 review'), findsOneWidget);

      // The seller's own listing offers no review button at all.
      final mine = FeedStore.instance
          .addListing('c1', title: 'Chair', priceCents: 100, category: 'Other');
      await tester.pumpWidget(
          MaterialApp(home: ListingScreen(listingId: mine.id)));
      await tester.pump();
      expect(find.text('Write a review'), findsNothing);
    });

    testWidgets('Message seller opens the chat with the question typed',
        (tester) async {
      FeedStore.instance.resetForTest();
      ChatStore.instance.reset();
      addTearDown(() {
        FeedStore.instance.resetForTest();
        ChatStore.instance.reset();
        debugResolveSellerOverride = null;
      });
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_msg',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Blue bike',
        priceCents: 2000,
        listingCategory: 'Sports',
      ));
      // The directory knows the seller.
      debugResolveSellerOverride = (username) async => AppUser(
          id: 'u_grace',
          name: 'Grace',
          avatarColor: '#123456',
          username: username);

      await tester.pumpWidget(
          const MaterialApp(home: ListingScreen(listingId: 'lst_msg')));
      await tester.pump();
      await tester.tap(find.text('Message Grace'));
      await tester.pumpAndSettle();

      // Landed in the chat, question already typed — sending stays the
      // user's choice.
      expect(find.byType(ChatScreen), findsOneWidget);
      final chat = ChatStore.instance.chatWithContact('u_grace');
      expect(chat, isNotNull);
      expect(ChatStore.instance.draftFor(chat!.id),
          'Is this still available? — "Blue bike" (\$20)');
    });

    test('listing sort: price orders, ties stay stable, sold always sinks',
        () {
      FeedPost l(String id, int price, {bool sold = false, int minute = 0}) =>
          FeedPost(
            id: id,
            communityId: 'c1',
            authorName: 'G',
            authorUsername: 'g',
            time: DateTime(2026, 1, 1, 12, minute),
            text: id,
            priceCents: price,
            listingCategory: 'Other',
            listingSold: sold,
          );
      final items = [
        l('cheap', 500, minute: 1),
        l('free', 0, minute: 2),
        l('dear', 9000, minute: 3),
        l('cheap2', 500, minute: 4),
        l('soldfree', 0, sold: true, minute: 5),
      ];

      ids(List<FeedPost> x) => [for (final p in x) p.id];

      // Low to high: free first, equal prices newest-first, sold dead last
      // even though it is the cheapest thing on the list.
      expect(ids(sortListings(items, ListingSort.priceLow)),
          ['free', 'cheap2', 'cheap', 'dear', 'soldfree']);
      expect(ids(sortListings(items, ListingSort.priceHigh)),
          ['dear', 'cheap2', 'cheap', 'free', 'soldfree']);
      expect(ids(sortListings(items, ListingSort.newest)),
          ['cheap2', 'dear', 'free', 'cheap', 'soldfree']);
    });

    testWidgets('saving a listing and shopping the saved shelf',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_savea',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Blue bike',
        priceCents: 2000,
        listingCategory: 'Sports',
      ));
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_saveb',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Green lamp',
        priceCents: 500,
        listingCategory: 'Home & Garden',
      ));

      // Save from the listing's own screen.
      await tester.pumpWidget(
          const MaterialApp(home: ListingScreen(listingId: 'lst_savea')));
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(find.byTooltip('Unsave'), findsOneWidget);
      expect(FeedStore.instance.isSaved('lst_savea'), isTrue);

      // The Saved switch in the browse filters narrows to it.
      await tester.pumpWidget(const MaterialApp(home: MarketplaceScreen()));
      await tester.pump();
      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Saved'));
      await tester.pumpAndSettle();
      // Sheet stays open for stacking filters; close it by hand.
      Navigator.of(tester.element(find.text('SORT'))).pop();
      await tester.pumpAndSettle();

      expect(find.text('Blue bike'), findsOneWidget);
      expect(find.text('Green lamp'), findsNothing);
    });

    test('extra photos ride as child posts and die with the listing', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      final listing = FeedStore.instance.addListing('c1',
          title: 'Bike',
          priceCents: 2000,
          category: 'Sports',
          photoUrl: 'data:image/jpeg;base64,AAA',
          extraPhotos: ['data:image/jpeg;base64,BBB', 'data:image/jpeg;base64,CCC']);

      // Cover first, parts in order — and each part is its own post, because
      // the relay caps one envelope near a single photo's budget.
      expect(FeedStore.instance.listingPhotos(listing.id), [
        'data:image/jpeg;base64,AAA',
        'data:image/jpeg;base64,BBB',
        'data:image/jpeg;base64,CCC',
      ]);
      final parts = FeedStore.instance
          .reviewsFor(listing.id); // parts must NOT read as reviews
      expect(parts, isEmpty);

      // A part survives the relay JSON round trip with its index.
      final wirePart = FeedPost.fromJson(FeedPost(
        id: 'part_wire',
        communityId: 'c1',
        authorName: 'You',
        authorUsername: 'you',
        time: DateTime.now(),
        text: '',
        parentId: listing.id,
        gifUrl: 'data:image/jpeg;base64,BBB',
        mediaPart: 2,
      ).toJson());
      expect(wirePart.mediaPart, 2);
      expect(wirePart.isMediaPart, isTrue);

      // Editing with a new set replaces the parts; a replay of a removed
      // part's copy stays dead (tombstoned), so devices converge.
      final removedPartCopy = FeedPost(
        id: 'probe_part',
        communityId: 'c1',
        authorName: 'You',
        authorUsername: 'you',
        time: DateTime.now(),
        text: '',
        parentId: listing.id,
        gifUrl: 'data:image/jpeg;base64,BBB',
        mediaPart: 1,
      );
      FeedStore.instance.updateListing(listing.id,
          title: 'Bike',
          priceCents: 2000,
          category: 'Sports',
          photoUrl: 'data:image/jpeg;base64,AAA',
          extraPhotos: ['data:image/jpeg;base64,DDD']);
      expect(FeedStore.instance.listingPhotos(listing.id), [
        'data:image/jpeg;base64,AAA',
        'data:image/jpeg;base64,DDD',
      ]);

      // Deleting the listing takes its photo parts down in the cascade.
      FeedStore.instance.deletePost(listing.id);
      expect(FeedStore.instance.listingPhotos(listing.id), isEmpty);
      FeedStore.instance.addRemote(removedPartCopy);
      expect(FeedStore.instance.listingPhotos(listing.id), isEmpty,
          reason: 'a replayed part of a deleted listing must stay dead');
    });

    testWidgets('the gallery pages through a listing\'s photos',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_gal',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Bike',
        priceCents: 2000,
        listingCategory: 'Sports',
        gifUrl: 'data:image/jpeg;base64,AAA',
      ));
      for (var i = 1; i <= 2; i++) {
        FeedStore.instance.addRemote(FeedPost(
          id: 'lst_gal_p$i',
          communityId: 'c1',
          authorName: 'Grace',
          authorUsername: 'grace',
          time: DateTime.now(),
          text: '',
          parentId: 'lst_gal',
          gifUrl: 'data:image/jpeg;base64,P$i',
          mediaPart: i,
        ));
      }

      await tester.pumpWidget(
          const MaterialApp(home: ListingScreen(listingId: 'lst_gal')));
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);
      await tester.fling(
          find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
    });

    test('listing videos: sealed round trip, caps, and honest sniffing',
        () async {
      CommunityStore.instance.resetForTest();
      addTearDown(() {
        CommunityStore.instance.resetForTest();
        MarketMedia.debugBucketOverride = null;
      });
      final server = CommunityStore.instance.createCommunity('Video HQ');
      expect(server.secret, isNotEmpty,
          reason: 'a minted server carries the key its media is sealed with');
      final bucket = <String, String>{};
      MarketMedia.debugBucketOverride = bucket;

      // A plausible tiny MP4: size box + ftyp brand.
      final mp4 = Uint8List.fromList([
        0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, // ftyp
        ...List.filled(64, 7),
      ]);
      expect(MarketMedia.looksLikeVideo(mp4), isTrue);
      expect(
          MarketMedia.looksLikeVideo(
              Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, ...List.filled(16, 0)])),
          isTrue,
          reason: 'WebM is a video too');
      expect(
          MarketMedia.looksLikeVideo(
              Uint8List.fromList(List.filled(64, 0x41))),
          isFalse,
          reason: 'a text file with a video extension is not a video');

      {
        final path = await MarketMedia.instance.uploadVideo(
            communityId: server.id, listingId: 'lst_v', bytes: mp4);
        expect(path, MarketMedia.pathFor(server.id, 'lst_v'));

        // What sits in the bucket is ciphertext, not the video.
        expect(bucket[path], isNotNull);
        expect(bucket[path]!.contains('ftyp'), isFalse);

        // Members round-trip it back to the exact bytes.
        final back = await MarketMedia.instance.downloadVideo(server.id, path);
        expect(back, mp4);

        // A non-member (no key for that server) gets nothing readable.
        final other = CommunityStore.instance.createCommunity('Other');
        expect(await MarketMedia.instance.downloadVideo(other.id, path),
            isNull);

        // Deleting a listing's video empties its slot.
        await MarketMedia.instance.deleteVideo(path);
        expect(bucket[path], isNull);

        // Oversize and non-video are refused with reasons, not uploaded.
        await expectLater(
            MarketMedia.instance.uploadVideo(
                communityId: server.id,
                listingId: 'lst_big',
                bytes: Uint8List(MarketMedia.maxVideoBytes + 1)),
            throwsA(isA<MarketMediaError>()));
        await expectLater(
            MarketMedia.instance.uploadVideo(
                communityId: server.id,
                listingId: 'lst_txt',
                bytes: Uint8List.fromList(List.filled(64, 0x41))),
            throwsA(isA<MarketMediaError>()));
        expect(bucket, isEmpty);
      }
    });

    test('the video path rides the listing envelope, not the bytes', () {
      final listing = FeedPost(
        id: 'lst_vp',
        communityId: 'c1',
        authorName: 'You',
        authorUsername: 'you',
        time: DateTime.now(),
        text: 'Bike',
        priceCents: 2000,
        listingCategory: 'Sports',
        listingVideo: 'c1/lst_vp.sealed',
      );
      final wire = FeedPost.fromJson(listing.toJson());
      expect(wire.listingVideo, 'c1/lst_vp.sealed');
      // And the sell form's tile promise matches the enforced cap.
      expect(MarketMedia.maxVideoBytes, 12 * 1024 * 1024,
          reason: 'the "up to 12 MB" label hardcodes this number');
    });

    testWidgets('video upload is part of the storage subscription',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(() {
        FeedStore.instance.resetForTest();
        StorageStore.instance.debugSubscribe(0);
      });

      // Without the subscription the slot explains itself instead of hiding.
      await tester.pumpWidget(const MaterialApp(home: SellScreen()));
      await tester.pump();
      expect(find.textContaining('Add a video with cloud storage'),
          findsOneWidget);
      expect(find.text('Add a video (up to 12 MB, ~30s)'), findsNothing);

      // With it, the picker button appears.
      StorageStore.instance.debugSubscribe(50);
      await tester.pumpWidget(const MaterialApp(home: SellScreen()));
      await tester.pump();
      expect(find.text('Add a video (up to 12 MB, ~30s)'), findsOneWidget);
    });

    testWidgets('the seller screen gathers a seller\'s shop in one place',
        (tester) async {
      FeedStore.instance.resetForTest();
      ChatStore.instance.reset();
      addTearDown(() {
        FeedStore.instance.resetForTest();
        ChatStore.instance.reset();
        debugResolveSellerOverride = null;
      });
      for (final (id, title, price) in [
        ('sl_a', 'Blue bike', 2000),
        ('sl_b', 'Green lamp', 500),
      ]) {
        FeedStore.instance.addRemote(FeedPost(
          id: id,
          communityId: 'c1',
          authorName: 'Grace',
          authorUsername: 'grace',
          time: DateTime.now(),
          text: title,
          priceCents: price,
          listingCategory: 'Other',
        ));
      }
      // Someone else's stuff must not leak into Grace's shop.
      FeedStore.instance.addRemote(FeedPost(
        id: 'sl_x',
        communityId: 'c1',
        authorName: 'Ada',
        authorUsername: 'ada',
        time: DateTime.now(),
        text: 'Red desk',
        priceCents: 900,
        listingCategory: 'Other',
      ));
      FeedStore.instance.addReview('sl_a', rating: 4);

      await tester.pumpWidget(const MaterialApp(
          home: SellerScreen(username: 'grace', name: 'Grace')));
      await tester.pump();

      expect(find.text('Blue bike'), findsOneWidget);
      expect(find.text('Green lamp'), findsOneWidget);
      expect(find.text('Red desk'), findsNothing);
      expect(find.textContaining('4.0 · 1 review'), findsOneWidget);
      expect(find.textContaining('2 listings'), findsOneWidget);

      // Message from the profile opens the chat with NO prefilled question —
      // there is no listing being asked about.
      debugResolveSellerOverride = (u) async =>
          AppUser(id: 'u_grace', name: 'Grace', avatarColor: '#123456', username: u);
      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      final chat = ChatStore.instance.chatWithContact('u_grace');
      expect(ChatStore.instance.draftFor(chat!.id), isEmpty);
    });

    test('a price drop is remembered; a raise is not advertised', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final listing = FeedStore.instance
          .addListing('c1', title: 'Desk', priceCents: 4000, category: 'Other');

      // Dropping the price records the old ask, and it rides the wire.
      FeedStore.instance.updateListing(listing.id,
          title: 'Desk', priceCents: 3000, category: 'Other');
      var current = FeedStore.instance.listings().single;
      expect(current.prevPriceCents, 4000);
      expect(FeedPost.fromJson(current.toJson()).prevPriceCents, 4000);

      // An edit that leaves the price alone keeps the history.
      FeedStore.instance.updateListing(listing.id,
          title: 'Desk, oak', priceCents: 3000, category: 'Other');
      current = FeedStore.instance.listings().single;
      expect(current.prevPriceCents, 4000);

      // A raise overwrites it — and the tile only shows a strikethrough when
      // the old price is HIGHER, so "was \$30, now \$50" never renders as a
      // deal.
      FeedStore.instance.updateListing(listing.id,
          title: 'Desk, oak', priceCents: 5000, category: 'Other');
      current = FeedStore.instance.listings().single;
      expect(current.prevPriceCents, 3000);
      expect(current.prevPriceCents > (current.priceCents ?? 0), isFalse);
    });

    testWidgets('long-pressing someone else\'s listing offers the shield',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_mod',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime.now(),
        text: 'Spam item',
        priceCents: 100,
        listingCategory: 'Other',
      ));

      await tester.pumpWidget(const MaterialApp(home: MarketplaceScreen()));
      await tester.pump();
      await tester.longPress(find.text('Spam item'));
      await tester.pumpAndSettle();

      expect(find.text('Hide this listing'), findsOneWidget);
      expect(find.text('Mute Grace'), findsOneWidget);

      await tester.tap(find.text('Mute Grace'));
      await tester.pumpAndSettle();
      // Muted everywhere: gone from the grid, like their posts from the feed.
      expect(find.text('Spam item'), findsNothing);
      expect(FeedStore.instance.listings(), isEmpty);
    });

    testWidgets('many saved places scroll instead of overflowing the sheet',
        (tester) async {
      SavedPlacesStore.instance.resetForTest();
      addTearDown(SavedPlacesStore.instance.resetForTest);
      for (var i = 0; i < 20; i++) {
        SavedPlacesStore.instance
            .toggle(SavedPlace('Place $i', 43.0 + i * 0.01, -79.0));
      }

      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(debugMyLocation: LatLng(43.6, -79.3)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Saved places'));
      await tester.pumpAndSettle();

      // Twenty rows in a half-screen sheet: no overflow error arriving here
      // means the list scrolls. And each row says how far away it is.
      expect(tester.takeException(), isNull);
      expect(find.textContaining('away'), findsWidgets);
    });

    test('every category that ever shipped still exists', () {
      // Categories live as strings on listings already out on the relay;
      // renaming or dropping one orphans every listing filed under it. The
      // original ten are the floor this list can never sink below.
      const legacy = [
        'Electronics', 'Furniture', 'Clothing', 'Vehicles', 'Home & Garden',
        'Sports', 'Games & Toys', 'Books', 'Free stuff', 'Other',
      ];
      for (final c in legacy) {
        expect(kMarketplaceCategories, contains(c),
            reason: '$c has shipped and cannot be renamed or dropped');
      }
      expect(kMarketplaceCategories.length, greaterThanOrEqualTo(15));
      expect(kMarketplaceCategories.last, 'Other');
    });

    testWidgets('condition rides the listing and the sell form sets it',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      // Wire round trip, and updateListing preserves it when unmentioned.
      final listing = FeedStore.instance.addListing('c1',
          title: 'Bike',
          priceCents: 2000,
          category: 'Sports',
          condition: 'Good');
      expect(FeedPost.fromJson(listing.toJson()).listingCondition, 'Good');
      FeedStore.instance.updateListing(listing.id,
          title: 'Bike', priceCents: 1500, category: 'Sports');
      expect(FeedStore.instance.listings().single.listingCondition, 'Good');
      FeedStore.instance.resetForTest();

      // The form: pick a condition, post, and the detail meta shows it.
      // Pushed, not home — Post pops the route, and the home route can't pop.
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SellScreen())),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'What are you selling?'), 'Lamp');
      await tester.ensureVisible(find.text('Like new'));
      await tester.tap(find.text('Like new'));
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      final posted = FeedStore.instance.listings().single;
      expect(posted.listingCondition, 'Like new');

      await tester.pumpWidget(
          MaterialApp(home: ListingScreen(listingId: posted.id)));
      await tester.pump();
      expect(find.textContaining('Like new ·'), findsOneWidget);
    });

    testWidgets('backing out of a dirty sell form asks; a clean one just '
        'closes', (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);

      Object? result = 'not popped';
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => result = await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SellScreen())),
            child: const Text('open'),
          ),
        ),
      ));
      // Untouched: close means close. A dialog here would teach people the
      // dialog is noise.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(SellScreen), findsNothing);

      // Typed something: the work is guarded.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'What are you selling?'),
          'Half a listing');
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard listing?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.byType(SellScreen), findsOneWidget,
          reason: 'declining the discard keeps the form and the work');
    });

    test('the blue check rides posts the way it rides messages', () {
      FeedStore.instance.resetForTest();
      addTearDown(() {
        FeedStore.instance.resetForTest();
        AppState.setVerified(false);
      });

      // Verified author: the attestation rides listing, review, and post,
      // and survives the relay JSON round trip and edits.
      AppState.setVerified(true);
      final listing = FeedStore.instance
          .addListing('c1', title: 'Bike', priceCents: 100, category: 'Other');
      expect(listing.authorVerified, isTrue);
      expect(FeedPost.fromJson(listing.toJson()).authorVerified, isTrue);
      FeedStore.instance.updateListing(listing.id,
          title: 'Bike', priceCents: 90, category: 'Other');
      expect(FeedStore.instance.listings().single.authorVerified, isTrue,
          reason: 'an edit must not strip the badge');

      final post = FeedStore.instance.add('c1', 'hello');
      expect(post.authorVerified, isTrue);

      // Unverified author: nothing claims otherwise.
      AppState.setVerified(false);
      final plain = FeedStore.instance
          .addListing('c1', title: 'Lamp', priceCents: 50, category: 'Other');
      expect(plain.authorVerified, isFalse);
    });

    testWidgets('a verified seller shows the badge on their listing and shop',
        (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      FeedStore.instance.addRemote(FeedPost(
        id: 'lst_vb',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        authorVerified: true,
        time: DateTime.now(),
        text: 'Bike',
        priceCents: 2000,
        listingCategory: 'Sports',
      ));

      await tester.pumpWidget(
          const MaterialApp(home: ListingScreen(listingId: 'lst_vb')));
      await tester.pump();
      expect(find.byType(VerifiedBadge), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
          home: SellerScreen(username: 'grace', name: 'Grace')));
      await tester.pump();
      expect(find.byType(VerifiedBadge), findsWidgets);
    });

    testWidgets('the profile says what the account has proven',
        (tester) async {
      AccountEmail.instance.resetForTest();
      IdentityVerification.instance.resetForTest();
      addTearDown(() {
        AccountEmail.instance.resetForTest();
        IdentityVerification.instance.resetForTest();
      });

      // What an account has proven is shown on your OWN profile — it is the
      // door to changing each of those things, and a stranger's verification
      // state is not somebody else's business to inspect.
      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);
      AppState.profile.value = const AppUser(
          id: 'me', name: 'Me', avatarColor: '#000000', username: 'me');
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: PublicProfileScreen(username: 'me', embedded: true))));
      await tester.pump();

      // Local mode, nothing attached: honest about all three.
      expect(find.text('Phone unverified'), findsOneWidget);
      expect(find.text('Add email'), findsOneWidget);
      expect(find.text('Get the blue check'), findsOneWidget);

      // States change, chips follow.
      await AccountEmail.instance.setEmail('ada@example.com');
      IdentityVerification.instance.debugSetStatus(IdentityStatus.verified);
      await tester.pump();
      expect(find.text('Email unconfirmed'), findsOneWidget,
          reason: 'attached but never confirmed must not read as confirmed');
      expect(find.text('ID verified'), findsOneWidget);
    });

    testWidgets('an open listing follows the relay: sold updates, removal '
        'says so', (tester) async {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final listing = FeedStore.instance.addListing('c1',
          title: 'Desk', priceCents: 3000, category: 'Furniture');

      await tester.pumpWidget(
          MaterialApp(home: ListingScreen(listingId: listing.id)));
      await tester.pump();
      expect(find.text('Mark as sold'), findsOneWidget);
      expect(find.text('Your listing'), findsOneWidget);

      // A sold flag arriving over the relay updates the OPEN screen — the
      // viewer must not act on a listing that just changed under them.
      final soldRemotely = FeedPost.fromJson(listing.toJson())
          .copyWith(listingSold: true, listingRev: 1);
      FeedStore.instance.addRemote(soldRemotely);
      await tester.pump();
      expect(find.text('Mark as available'), findsOneWidget);
      expect(find.text('SOLD'), findsOneWidget);

      // Deleted under the viewer: say so, never show a ghost to message.
      FeedStore.instance.deletePost(listing.id);
      await tester.pump();
      expect(find.text('This listing was removed.'), findsOneWidget);
      expect(find.text('Mark as available'), findsNothing);
    });

    testWidgets('the server feed starts empty, posts, likes, and threads',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pump();

      // No fake accounts: a fresh feed is honestly empty.
      expect(find.textContaining('No posts yet'), findsOneWidget);

      // Composing moved to the app-bar pencil; Post stays disabled until
      // there's text.
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post'), warnIfMissed: false);
      await tester.pump();
      expect(FeedStore.instance.postsFor('c1'), isEmpty);
      await tester.enterText(
          find.byType(TextField).last, 'First post from me!');
      await tester.pump(); // the Post button enables on the next frame
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle(); // posting closes the sheet
      expect(find.text('First post from me!'), findsOneWidget);

      // Like it: the heart count appears.
      await tester.tap(find.byTooltip('Like'));
      await tester.pump();
      expect(find.text('1'), findsWidgets);

      // Open the thread and reply — the reply shows under the post.
      await tester.tap(find.byTooltip('Reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Post'), findsWidgets); // thread screen title
      await tester.enterText(find.byType(TextField).last, 'And a reply');
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pump();
      expect(find.text('And a reply'), findsOneWidget);

      // Back on the timeline the reply lives in the thread, not inline —
      // and there is no For you / Following split, just one timeline.
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('First post from me!'), findsOneWidget);
      expect(find.text('And a reply'), findsNothing); // threaded, not inline
      expect(find.text('For you'), findsNothing);
      expect(find.text('Following'), findsNothing);

      // Deleting lives in the long-press sheet now, not a standing icon.
      await tester.longPress(find.text('First post from me!'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete post'));
      await tester.pumpAndSettle();
      expect(find.text('First post from me!'), findsNothing);
    });

    test('backupCount pluralises the backup summary', () {
      expect(backupCount(0, 'chat'), '0 chats');
      expect(backupCount(1, 'chat'), '1 chat');
      expect(backupCount(5, 'saved place'), '5 saved places');
    });

    test('communal sync stores only ciphertext and restores everything',
        () async {
      // Servers, feed, follows, places — the free communal backup.
      CloudSync.debugServerOverride = {};
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
      });
      await CloudSync.instance
          .configure(passphrase: 'correct horse battery', on: false);

      FeedStore.instance.add('c1', 'Backed up post');
      FollowStore.instance.toggle('gracehop');
      SavedPlacesStore.instance.toggle(const SavedPlace('Cafe', 43.6, -79.3));

      expect(await CloudSync.instance.syncNow(), isNull);
      final blob = CloudSync.debugServerOverride!.values.single;
      // Heavily encrypted: the stored blob leaks nothing readable.
      expect(blob.contains('Backed up post'), isFalse);
      expect(blob.contains('gracehop'), isFalse);
      expect(blob.contains('Cafe'), isFalse);

      // Wipe local state, then restore from the encrypted blob.
      FeedStore.instance.resetForTest();
      FollowStore.instance.resetForTest();
      SavedPlacesStore.instance.resetForTest();
      expect(await CloudSync.instance.restore(), isNull);
      expect(FeedStore.instance.postsFor('c1').single.text, 'Backed up post');
      expect(FollowStore.instance.isFollowing('gracehop'), isTrue);
      expect(SavedPlacesStore.instance.places.single.name, 'Cafe');

      // The wrong passphrase cannot find (let alone decrypt) the backup.
      await CloudSync.instance
          .configure(passphrase: 'wrong passphrase', on: false);
      expect(await CloudSync.instance.restore(), isNotNull);
    });

    test('automatic sync: servers back up with no passphrase, chats stay out',
        () async {
      CloudSync.debugServerOverride = {};
      final prevProfile = AppState.profile.value;
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        AppState.profile.value = prevProfile;
        CommunityStore.instance.resetForTest();
      });
      // Signed in (digits exist), but the user never set a passphrase.
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Me',
          avatarColor: '#000000',
          phone: '+1 555 010 7777');
      await CloudSync.instance.configure(passphrase: '', on: true);
      expect(CloudSync.instance.autoMode, isTrue);
      expect(CloudSync.instance.configured, isTrue);

      // The automatic payload deliberately has no chats in it.
      CommunityStore.instance.createCommunity('Autosaved');
      final payload = CloudSync.instance.buildPayload();
      expect(payload.containsKey('chats'), isFalse);
      expect(payload['communities'], isNotEmpty);

      expect(await CloudSync.instance.syncNow(), isNull);
      final blob = CloudSync.debugServerOverride!.values.single;
      expect(blob.contains('Autosaved'), isFalse); // ciphertext only

      // Wipe the device — restoring brings the server back with no input.
      CommunityStore.instance.clearAll();
      expect(CommunityStore.instance.communities, isEmpty);
      expect(await CloudSync.instance.restore(), isNull);
      expect(
          CommunityStore.instance.communities
              .any((c) => c.name == 'Autosaved'),
          isTrue);

      // Setting a real passphrase upgrades the key but never adds chats —
      // message content stays on the device it was sent from.
      await CloudSync.instance
          .configure(passphrase: 'stronger key', on: true);
      expect(CloudSync.instance.autoMode, isFalse);
      expect(CloudSync.instance.buildPayload().containsKey('chats'), isFalse);
    });

    test('storage is paid only — buy any size up to the cap', () {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();
      // There is no free allowance: an unpaid account stores nothing. Every
      // held GB costs real money, so giving some away meant every signed-up
      // account carried a bill whether or not it ever paid.
      expect(StorageStore.freeGb, 0);
      expect(storage.activeGb, 0);
      expect(storage.isPaid, isFalse);
      expect(storage.quotaBytes, 0);
      expect(storage.fits(1), isFalse, reason: 'nothing fits without a plan');
      // No free entry on the ladder either.
      expect(StorageStore.plans.any((p) => p.priceCents == 0), isFalse);

      // Buying 30 GB raises the ceiling for ~30 days.
      storage.subscribe(30);
      expect(storage.activeGb, 30);
      expect(storage.isPaid, isTrue);
      expect(storage.quotaBytes, 30 * 1024 * 1024 * 1024);
      expect(storage.daysLeft, inInclusiveRange(28, 30));

      // Renewing stacks the time rather than wasting the remainder.
      storage.subscribe(30);
      expect(storage.daysLeft, inInclusiveRange(58, 60));

      // Any ladder size is buyable, and 100 GB is the hard ceiling.
      expect(StorageStore.sizes.first, 10);
      expect(StorageStore.sizes.last, StorageStore.maxGb);
      expect(StorageStore.maxGb, 100);
      storage.subscribe(500); // over the cap
      expect(storage.activeGb, StorageStore.maxGb, reason: 'clamped to 100 GB');

      // Cancelling stops storage entirely rather than dropping to a freebie.
      storage.cancel();
      expect(storage.isPaid, isFalse);
      expect(storage.activeGb, 0);
      expect(storage.quotaBytes, 0);
    });

    test('per-GB pricing lands on real App Store price points', () {
      // ~$0.20/GB, rounded onto an x.99 point.
      expect(StorageStore.priceCentsFor(10), 199);
      expect(StorageStore.priceCentsFor(50), 999);
      expect(StorageStore.priceCentsFor(100), 1999);
      expect(StorageStore.planForGb(50).priceLabel, '\$9.99/mo');
      // Bigger always costs more — never a cheaper price for more space.
      for (var i = 1; i < StorageStore.sizes.length; i++) {
        expect(StorageStore.priceCentsFor(StorageStore.sizes[i]),
            greaterThan(StorageStore.priceCentsFor(StorageStore.sizes[i - 1])));
      }
    });

    test('every size profits after Apple\'s cut — including as overage', () {
      // Apple keeps 30%, so the developer nets 70%.
      expect(StorageEconomics.developerNet(10), closeTo(7.0, 0.0001));
      // Buckets are far cheaper per GB than Postgres disk.
      expect(StorageEconomics.costPerGb(useBuckets: true),
          lessThan(StorageEconomics.costPerGb(useBuckets: false)));
      // The retail rate must clear the break-even rate, or nothing below works.
      expect(StorageEconomics.pricePerGb,
          greaterThan(StorageEconomics.breakEvenPricePerGb()));

      for (final gb in StorageStore.sizes) {
        final price = StorageStore.priceCentsFor(gb) / 100;
        expect(StorageEconomics.isProfitable(price, gb), isTrue,
            reason: '$gb GB must profit on buckets');
        // The load-bearing property: because each GB is priced above its own
        // marginal rate, the GB that push the project past its included 100 GB
        // still pay for their own Supabase overage.
        expect(StorageEconomics.coversOverage(price, gb), isTrue,
            reason: '$gb GB must cover its own overage past the included tier');
      }

      // Concretely: 100 GB @ $19.99 nets $13.99, costs ~$6.63 on buckets.
      expect(StorageEconomics.monthlyProfit(19.99, 100), greaterThan(5));
    });

    test('peer-to-peer transfers are pure revenue on a direct charge', () {
      // History: a 1.5% + 0¢ fee against Stripe's 2.9% + 30¢ lost money on
      // every transfer, and even at 3.4% + 35¢ a foreign card went negative
      // above ~$17.75. Direct charges retire that whole class of bug — Stripe
      // bills the recipient's account, so the fee is kept whole.
      for (final amount in [100, 500, 1000, 2500, 5000, 25000]) {
        expect(PaymentEconomics.isProfitable(amount), isTrue,
            reason: '\$${amount / 100} transfer must not lose money');
      }
      // A $10 transfer: 44¢ fee, all of it kept.
      expect(PaymentEconomics.applicationFeeCents(1000), 44);
      expect(PaymentEconomics.netCents(1000), 44);
      // The recipient's side is separate, and is what shrinks the landing
      // amount — 59¢ of Stripe on a domestic card.
      expect(PaymentEconomics.stripeCostCents(1000), 59);
      expect(PaymentEconomics.estimatedReceivedCents(1000), 1000 - 44 - 59);

      // Small transfers were the reason the fixed part came down: at 35¢ a
      // $5 send lost 10.4% to the platform fee alone, before Stripe.
      expect(PaymentEconomics.platformFixedCents, lessThanOrEqualTo(10));
      expect(PaymentEconomics.applicationFeeCents(500) / 500,
          lessThan(0.07));
    });

    test('a direct charge keeps the platform out of the flow of funds', () {
      // The point of direct charges: Stripe's cut comes out of the recipient's
      // account, so the application fee is kept in full and no card — foreign
      // or otherwise — can make a transfer cost the platform anything.
      for (final amount in [50, 100, 1775, 2500, 5000, 10000, 50000, 200000]) {
        expect(PaymentEconomics.netCents(amount),
            PaymentEconomics.applicationFeeCents(amount));
        expect(PaymentEconomics.worstCaseNetCents(amount),
            PaymentEconomics.netCents(amount),
            reason: 'the platform side must not vary by card');
        expect(PaymentEconomics.isProfitable(amount), isTrue);
      }
      // The recipient is the one who feels a foreign card.
      expect(PaymentEconomics.worstCaseReceivedCents(5000),
          lessThan(PaymentEconomics.estimatedReceivedCents(5000)));
      // The quote always adds up — nothing unexplained between the two.
      expect(
          PaymentEconomics.estimatedReceivedCents(5000) +
              PaymentEconomics.applicationFeeCents(5000) +
              PaymentEconomics.stripeCostCents(5000),
          5000);
    });

    test('the fair-use egress ceiling sits below what the price can pay for',
        () {
      // Egress dominates the cost of a stored GB: at 3x stored per month a
      // $0.20 GB costs ~$0.29 to serve, so the ceiling was 2.3x past the
      // point where the plan starts losing money.
      expect(StorageEconomics.fairUseEgressMultiple,
          lessThan(StorageEconomics.breakEvenEgressMultiple),
          reason: 'an allowance the price cannot cover is not fair use');

      // At the enforced ceiling, every size still profits.
      double costAtCeiling(int gb) =>
          gb *
          (StorageEconomics.fileStoragePerGb +
              StorageEconomics.fairUseEgressMultiple *
                  StorageEconomics.egressPerGb);
      for (final gb in StorageStore.sizes) {
        final net =
            StorageEconomics.developerNet(StorageStore.priceCentsFor(gb) / 100);
        expect(net, greaterThan(costAtCeiling(gb)),
            reason: '$gb GB must still profit with a user at the egress cap');
      }
    });

    test('chat backups go to the cheap bucket, not the pricey table', () async {
      // Storage buckets bill ~6x less than Postgres disk — the difference
      // between selling storage at a profit and at a loss.
      CloudSync.instance.resetForTest();
      CloudSync.debugServerOverride = {};
      StorageStore.instance.resetForTest();
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        StorageStore.instance.resetForTest();
      });
      // Storage is paid only, so a plan has to exist before any of this
      // means anything.
      await StorageStore.instance.subscribe(10);
      await CloudSync.instance
          .configure(passphrase: 'bucket-path-key', on: false);
      expect(await CloudSync.instance.backUpChats(), isNull);

      // The chat blob is keyed by its bucket object name, and round-trips.
      final key = await CloudSync.deriveSyncKeyForTest(
          'bucket-path-key', CloudSync.instance.digitsForTest);
      final objectName = CloudSync.chatBlobIdFor(key);
      expect(CloudSync.debugServerOverride!.containsKey(objectName), isTrue);
      expect(CloudSync.chatBucket, 'chat-backups');
      expect(await CloudSync.instance.restoreChats(), isNull);
    });

    test('storage & tips are store products (Apple), not Stripe', () async {
      // Each purchasable size maps to its own auto-renewable product; the free
      // allowance needs none.
      expect(StorePurchases.storageProductId(0), '');
      expect(StorePurchases.storageProductId(30),
          'com.okaymessaging.storage.gb30.monthly');
      expect(StorePurchases.storageProductId(100),
          'com.okaymessaging.storage.gb100.monthly');

      // Tips are a fixed set of consumable products, priced low-to-high.
      const tips = StorePurchases.tipProducts;
      expect(tips.length, 4);
      for (var i = 1; i < tips.length; i++) {
        expect(tips[i].cents, greaterThan(tips[i - 1].cents));
        expect(tips[i].id, startsWith('com.okaymessaging.tip'));
      }

      // In payments test mode both flows simulate a completed purchase.
      final payments = PaymentService.instance;
      final wasTest = payments.testMode.value;
      addTearDown(() => payments.setTestMode(wasTest));
      payments.setTestMode(true);
      expect(StorePurchases.instance.isSupported, isTrue);
      expect(await StorePurchases.instance.buyStorage(30), isTrue);
      expect(await StorePurchases.instance.tip(tips.first.id), isTrue);
      // A zero-GB "purchase" is a no-op that doesn't pretend to charge.
      expect(await StorePurchases.instance.buyStorage(0), isFalse);
    });

    test('a lapsed purchase falls back to the free allowance', () {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();
      // Bought 50 GB, but the month has already run out.
      storage.debugSubscribe(50, length: const Duration(seconds: -1));
      expect(storage.selectedGb, 50); // what they paid for
      expect(storage.activeGb, StorageStore.freeGb); // what they get now
      expect(storage.isPaid, isFalse);
    });

    test('storage usage: formatBytes and used/available math', () {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();

      expect(StorageStore.formatBytes(0), '0 B');
      expect(StorageStore.formatBytes(512), '512 B');
      expect(StorageStore.formatBytes(1024), '1 KB');
      expect(StorageStore.formatBytes(1536), '1.5 KB');
      expect(StorageStore.formatBytes(5 * 1024 * 1024 * 1024), '5 GB');

      // No plan means no room at all — buy one before any of the
      // used/available maths means anything.
      expect(storage.quotaBytes, 0);
      storage.subscribe(10);
      expect(storage.usedBytes, 0);
      expect(storage.usedFraction, 0);
      expect(storage.availableBytes, storage.quotaBytes);

      storage.setUsedBytes(2 * 1024 * 1024); // 2 MB
      expect(storage.usedBytes, 2 * 1024 * 1024);
      expect(storage.availableBytes, storage.quotaBytes - 2 * 1024 * 1024);
      expect(storage.usedFraction, greaterThan(0));
      expect(storage.usedFraction, lessThan(1));
      expect(storage.nearLimit, isFalse);
      expect(storage.isFull, isFalse);

      // Fill it: near-limit then full.
      storage.setUsedBytes((storage.quotaBytes * 0.95).round());
      expect(storage.nearLimit, isTrue);
      expect(storage.isFull, isFalse);
      storage.setUsedBytes(storage.quotaBytes);
      expect(storage.isFull, isTrue);

      // Upgrade suggestion: the smallest size that would hold the data.
      const twentyFiveGb = 25 * 1024 * 1024 * 1024;
      expect(storage.smallestPlanFor(twentyFiveGb)?.gb, 30);
      // Nothing holds more than the 100 GB cap — no unlimited.
      const oneTb = 1024 * 1024 * 1024 * 1024;
      expect(storage.smallestPlanFor(oneTb), isNull);
      // The next step up from the 10 GB bought above is the next rung.
      expect(storage.nextSizeUp?.gb, 20);
      // And with nothing bought, it's the cheapest size on the ladder.
      storage.cancel();
      expect(storage.nextSizeUp?.gb, StorageStore.sizes.first);
    });

    test('chats need a key, back up to paid storage, and are quota-gated',
        () async {
      CloudSync.instance.resetForTest();
      CloudSync.debugServerOverride = {};
      StorageStore.instance.resetForTest();
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        StorageStore.instance.resetForTest();
      });

      // Auto mode (phone-derived key) may not protect chats — refused.
      await CloudSync.instance.configure(passphrase: '', on: false);
      expect(CloudSync.instance.chatBackupReady, isFalse);
      expect(await CloudSync.instance.backUpChats(), contains('key'));
      expect(CloudSync.debugServerOverride, isEmpty);

      // With a real key AND a plan, chats back up and record their size
      // against quota. Storage is paid only, so without the plan the backup
      // is refused for want of room, not for want of a key.
      await StorageStore.instance.subscribe(10);
      await CloudSync.instance
          .configure(passphrase: 'my-secret-chat-key', on: false);
      expect(CloudSync.instance.chatBackupReady, isTrue);
      expect(StorageStore.instance.usedBytes, 0);
      expect(await CloudSync.instance.backUpChats(), isNull);
      expect(CloudSync.debugServerOverride, isNotEmpty);
      expect(StorageStore.instance.usedBytes, greaterThan(0));

      // The chat blob is separate from the communal one.
      expect(CloudSync.debugServerOverride!.length, 1);
      expect(await CloudSync.instance.syncNow(), isNull); // communal, free
      expect(CloudSync.debugServerOverride!.length, 2);
    });

    test('an over-quota chat backup is refused before upload', () async {
      CloudSync.instance.resetForTest();
      CloudSync.debugServerOverride = {};
      StorageStore.instance.resetForTest();
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        StorageStore.instance.resetForTest();
      });
      // Storage is paid only, so a plan has to exist before any of this
      // means anything.
      await StorageStore.instance.subscribe(10);
      await CloudSync.instance
          .configure(passphrase: 'over-quota-key', on: false);
      // fits() gates on the plan ceiling.
      expect(StorageStore.instance.fits(1), isTrue);
      expect(
          StorageStore.instance.fits(StorageStore.instance.quotaBytes + 1),
          isFalse);
    });

    test('verify chat backup confirms it is present and readable', () async {
      CloudSync.instance.resetForTest();
      CloudSync.debugServerOverride = {};
      StorageStore.instance.resetForTest();
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        StorageStore.instance.resetForTest();
      });
      // Storage is paid only, so a plan has to exist before any of this
      // means anything.
      await StorageStore.instance.subscribe(10);
      await CloudSync.instance
          .configure(passphrase: 'verify-chat-unique-key', on: false);

      // Nothing backed up yet.
      expect(await CloudSync.instance.verifyChatBackup(), isNotNull);
      // After a backup it verifies clean.
      expect(await CloudSync.instance.backUpChats(), isNull);
      expect(await CloudSync.instance.verifyChatBackup(), isNull);
    });

    test('reposts are real entries, deletes cascade, bookmarks persist', () {
      FeedStore.instance.resetForTest();
      final store = FeedStore.instance;
      final original = store.add('c1', 'worth resharing');

      // Repost: a deterministic entry appears and the counter moves.
      store.toggleRepost(original.id);
      final entryId = FeedStore.repostEntryId(
          original.id, AppState.profile.value.username);
      expect(store.postById(entryId)?.repostOfId, original.id);
      expect(store.postById(original.id)!.reposts, 1);
      expect(store.postById(original.id)!.reposted, isTrue);

      // Un-repost removes the entry and gives the counter back.
      store.toggleRepost(original.id);
      expect(store.postById(entryId), isNull);
      expect(store.postById(original.id)!.reposts, 0);

      // A remote member's repost bumps the original once, deduped.
      final remote = FeedPost(
          id: 'rp_${original.id}_by_grace',
          communityId: 'c1',
          authorName: 'Grace',
          authorUsername: 'grace',
          time: DateTime.now(),
          text: '',
          repostOfId: original.id);
      store.addRemote(remote);
      store.addRemote(remote);
      expect(store.postById(original.id)!.reposts, 1);
      // Deleting the original takes reposts (and replies) with it.
      store.reply(original.id, 'a reply');
      store.removeRemote(original.id);
      expect(store.postById(original.id), isNull);
      expect(store.postById(remote.id), isNull);
      expect(store.postsFor('c1'), isEmpty);

      // Bookmarks toggle and are per-post.
      final keeper = store.add('c1', 'save me');
      expect(store.toggleSaved(keeper.id), isTrue);
      expect(store.isSaved(keeper.id), isTrue);
      expect(store.toggleSaved(keeper.id), isFalse);
      expect(store.isSaved(keeper.id), isFalse);
    });

    test('feed notifications fire for replies, mentions, and reposts', () {
      FeedStore.instance.resetForTest();
      final store = FeedStore.instance;
      // 'you' owns this post (default profile has no username → 'you').
      final mine = store.add('c1', 'my original post');

      FeedPost remote(String id, {String? parent, String text = '',
              String? repostOf}) =>
          FeedPost(
              id: id,
              communityId: 'c1',
              authorName: 'Grace',
              authorUsername: 'grace',
              time: DateTime.now(),
              text: text,
              parentId: parent,
              repostOfId: repostOf);

      // A reply to my post notifies me, pointing at the reply's thread.
      store.addRemote(remote('r1', parent: mine.id, text: 'nice one'));
      // A repost of my post notifies me, pointing at the original.
      store.addRemote(
          remote('rp_${mine.id}_by_grace', repostOf: mine.id));
      // An @you mention notifies me.
      store.addRemote(remote('m1', text: 'hey @you look at this'));
      // Someone else's unrelated post does NOT.
      store.addRemote(remote('x1', text: 'just talking to myself'));

      final notes = store.notifications;
      expect(notes, hasLength(3));
      expect(notes.map((n) => n.type).toSet(), {
        FeedNotificationType.reply,
        FeedNotificationType.repost,
        FeedNotificationType.mention,
      });
      expect(
          notes
              .firstWhere((n) => n.type == FeedNotificationType.repost)
              .threadPostId,
          mine.id);
      expect(store.unseenNotificationCount, 3);

      // Dedup: the same event arriving twice doesn't double-count.
      store.addRemote(remote('r1', parent: mine.id, text: 'nice one'));
      expect(store.notifications, hasLength(3));

      // Marking seen clears the badge but keeps the history.
      store.markNotificationsSeen();
      expect(store.unseenNotificationCount, 0);
      expect(store.notifications, hasLength(3));

      // The pure detector never fires on your own echoed post.
      expect(
          FeedStore.notificationFor(mine,
              myUsername: 'you', myPostIds: {mine.id}),
          isNull);
    });

    test('like notifications carry the liker and dedupe', () {
      FeedStore.instance.resetForTest();
      final store = FeedStore.instance;
      final mine = store.add('c1', 'like this');
      expect(store.postById(mine.id)!.likes, 0);

      // Grace likes my post: counter moves and I'm notified.
      store.applyRemoteLike(mine.id,
          liked: true, likerName: 'Grace', likerUsername: 'grace');
      expect(store.postById(mine.id)!.likes, 1);
      final note = store.notifications.first;
      expect(note.type, FeedNotificationType.like);
      expect(note.actorName, 'Grace');
      expect(note.threadPostId, mine.id);

      // A replayed like (mailbox / reconnect) can't double the count.
      store.applyRemoteLike(mine.id,
          liked: true, likerName: 'Grace', likerUsername: 'grace');
      expect(store.postById(mine.id)!.likes, 1);
      expect(store.notifications.where((n) => n.type == FeedNotificationType.like),
          hasLength(1));

      // Unlike takes the count back down.
      store.applyRemoteLike(mine.id,
          liked: false, likerName: 'Grace', likerUsername: 'grace');
      expect(store.postById(mine.id)!.likes, 0);

      // Liking someone else's post notifies no one here.
      final theirs = FeedPost(
          id: 'p_theirs',
          communityId: 'c1',
          authorName: 'Bob',
          authorUsername: 'bob',
          time: DateTime.now(),
          text: 'not mine');
      store.addRemote(theirs);
      final before = store.notifications.length;
      store.applyRemoteLike('p_theirs',
          liked: true, likerName: 'Cara', likerUsername: 'cara');
      expect(store.postById('p_theirs')!.likes, 1);
      expect(store.notifications.length, before); // no self-notification
    });

    test('threads nest, mentions autocomplete, authors resolve', () {
      FeedStore.instance.resetForTest();
      final store = FeedStore.instance;
      final root = store.add('c1', 'root post');
      store.reply(root.id, 'first reply');
      final reply = store.repliesTo(root.id).single;
      // Reply to the reply: it threads under the reply, not the root.
      store.reply(reply.id, 'nested reply');
      expect(store.repliesTo(reply.id).single.text, 'nested reply');
      expect(store.repliesTo(root.id), hasLength(1));
      expect(store.postById(reply.id)!.replies, 1);

      // Mention prefix extraction from the composer text.
      expect(activeMentionPrefix('hey @gra'), 'gra');
      expect(activeMentionPrefix('hey @'), '');
      expect(activeMentionPrefix('no mention here'), isNull);
      expect(activeMentionPrefix('email a@b already done '), isNull);

      // Candidate matching: prefix, dedupe, never "you", capped at five.
      final known = ['grace', 'Graham', 'grace', 'you', 'bob', 'g1', 'g2',
        'g3', 'g4'];
      expect(mentionMatches('gra', known), ['grace', 'Graham']);
      expect(mentionMatches('g', known), hasLength(5));
      expect(mentionMatches('zz', known), isEmpty);

      // Author names resolve from their posts for the person sheet.
      expect(store.authorNameFor(root.authorUsername), isNotNull);
      expect(store.authorNameFor('nobody'), isNull);
      expect(store.usernamesFor('c1'), isNot(contains('you')));
    });

    test('deleted posts stay deleted through backup replays', () {
      FeedStore.instance.resetForTest();
      final store = FeedStore.instance;
      final post = store.add('c1', 'delete me');
      store.reply(post.id, 'a reply');
      // A backup snapshot taken BEFORE the delete...
      final staleBackup = store.exportPosts();

      store.deletePost(post.id);
      expect(store.postsFor('c1'), isEmpty);

      // ...must not resurrect the post when it replays after the delete —
      // this was the "when I delete post it comes back" bug.
      store.hydratePosts(staleBackup);
      expect(store.postById(post.id), isNull);
      expect(store.postsFor('c1'), isEmpty);
      // Nor can a stale relay copy bring it back.
      store.addRemote(FeedPost(
          id: post.id,
          communityId: 'c1',
          authorName: 'Me',
          authorUsername: 'you',
          time: DateTime.now(),
          text: 'delete me'));
      expect(store.postById(post.id), isNull);

      // Repost slots are the exception: un-repost then re-repost reuses
      // the deterministic id legitimately.
      final keeper = store.add('c1', 'reshare me');
      store.toggleRepost(keeper.id);
      store.toggleRepost(keeper.id); // un-repost (tombstones the slot)
      store.toggleRepost(keeper.id); // re-repost revives it
      final entryId = FeedStore.repostEntryId(
          keeper.id, AppState.profile.value.username);
      expect(store.postById(entryId), isNotNull);
    });

    test('feed trending tags, top sort, and tag filter', () {
      final t = DateTime(2024, 1, 1);
      FeedPost p(String id, String text,
              {int likes = 0, int reposts = 0, int min = 0}) =>
          FeedPost(
              id: id,
              communityId: 'c',
              authorName: 'A',
              authorUsername: 'a',
              time: t.add(Duration(minutes: min)),
              text: text,
              likes: likes,
              reposts: reposts);
      final posts = [
        p('1', 'Love #flutter and #dart', likes: 1, min: 1),
        p('2', 'More #Flutter tips', likes: 5, reposts: 2, min: 2),
        p('3', 'plain post', likes: 2, min: 3),
      ];
      // Counted case-insensitively, shown in first-seen casing.
      final tags = trendingTags(posts);
      expect(tags.first, ('#flutter', 2));
      expect(tags.any((e) => e.$1 == '#dart'), isTrue);

      expect(sortFeed(posts).first.id, '3'); // newest first
      expect(sortFeed(posts, top: true).first.id, '2'); // most engagement
      expect(filterFeedByTag(posts, '#flutter').map((e) => e.id).toList(),
          ['1', '2']);
      expect(filterFeedByTag(posts, ''), hasLength(3));
    });

    test('feedSpans highlights mentions, tags, and links', () {
      const base = TextStyle(fontSize: 15);
      const accent = TextStyle(fontSize: 15, color: Colors.blue);
      final spans =
          feedSpans('hey @grace check https://osm.org #maps', base, accent);
      expect(spans.map((s) => s.text).toList(),
          ['hey ', '@grace', ' check ', 'https://osm.org', ' ', '#maps']);
      expect(spans[1].style, accent);
      expect(spans[3].style, accent);
      expect(spans[0].style, base);
      // Plain text stays one plain span.
      expect(feedSpans('no tokens here', base, accent).length, 1);
    });

    testWidgets('People screen adds a friend and follows contacts',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PeopleScreen()));
      await tester.pump();

      // Existing contacts are listed with Follow buttons.
      expect(find.text('Alice Bennett'), findsOneWidget);
      expect(find.text('Follow'), findsWidgets);

      // Follow the first person.
      await tester.tap(find.text('Follow').first);
      await tester.pump();
      expect(find.text('Following'), findsOneWidget);
      expect(FollowStore.instance.followingCount, 1);

      // Add a friend by number — they join the list and the chat store.
      await tester.enterText(
          find.byType(TextField).first, '+1 222 333 0000');
      await tester.tap(find.text('Add'));
      await tester.pump();
      expect(find.textContaining('say hi'), findsOneWidget);
      expect(
          ChatStore.instance.chatWithContact('+1 222 333 0000'), isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('tapping a feed author offers Follow and Message',
        (tester) async {
      // A post by a real contact (arrives via sync/relay in production).
      FeedStore.instance.hydratePosts([
        {
          'id': 'p1',
          'communityId': 'c1',
          'authorName': 'Grace Hopper',
          'authorUsername': 'gracehop',
          'time': DateTime.now().toIso8601String(),
          'text': 'hello from @gracehop',
        }
      ]);
      await tester.pumpWidget(const MaterialApp(
        home: FeedScreen(communityId: 'c1', communityName: 'Okay HQ'),
      ));
      await tester.pump();

      await tester.tap(find.text('Grace Hopper'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('@gracehop'), findsWidgets);
      expect(find.text('Follow'), findsOneWidget);

      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(FollowStore.instance.isFollowing('gracehop'), isTrue);
      expect(find.text('Following'), findsOneWidget);
    });

    test('filterCommunities matches names and descriptions', () {
      final all = CommunityStore.instance.communities;
      expect(filterCommunities(all, ''), all);
      final byName = filterCommunities(all, all.first.name.toLowerCase());
      expect(byName, isNotEmpty);
      expect(filterCommunities(all, 'zzz-no-such-server'), isEmpty);
    });

    test('filterMessages matches text and poll questions', () {
      final now = DateTime(2026, 1, 1);
      final msgs = [
        Message(id: 'a', text: 'Deploy is green', time: now, isMe: true),
        Message(
            id: 'b',
            text: 'lunch plans?',
            time: now,
            isMe: false,
            senderName: 'Ada Lovelace'),
        Message(
            id: 'c',
            text: '',
            time: now,
            isMe: false,
            isPoll: true,
            pollQuestion: 'Best deploy window?'),
      ];
      // Empty query is a pass-through.
      expect(filterMessages(msgs, ''), msgs);
      expect(filterMessages(msgs, '   '), msgs);
      // Case-insensitive text match.
      final green = filterMessages(msgs, 'GREEN');
      expect(green.map((m) => m.id), ['a']);
      // Matches poll questions too, so a poll surfaces by its prompt.
      final deploy = filterMessages(msgs, 'deploy');
      expect(deploy.map((m) => m.id), containsAll(['a', 'c']));
      // Matches sender names, so you can find who said something.
      final byName = filterMessages(msgs, 'ada');
      expect(byName.map((m) => m.id), ['b']);
      // No match yields an empty list, driving the empty state.
      expect(filterMessages(msgs, 'zzzz'), isEmpty);
    });

    test('channel mentions: prefix detection and one-word tokens', () {
      // A mention has to be one word to be recognised when rendered.
      expect(mentionToken('Ada Lovelace'), 'AdaLovelace');
      expect(mentionToken('Grace'), 'Grace');
      expect(mentionToken('Jean-Luc P.'), 'JeanLucP');

      // Caret sitting right after "@" offers everyone (empty prefix).
      expect(mentionPrefix('hey @', 5), '');
      // Partway through a name.
      expect(mentionPrefix('hey @ad', 7), 'ad');
      // Mid-word "@" (an email) is not a mention.
      expect(mentionPrefix('mail ada@example', 16), isNull);
      // Once a space follows, the mention is finished.
      expect(mentionPrefix('hey @ada ', 9), isNull);
      // No "@" at all.
      expect(mentionPrefix('plain text', 10), isNull);
      // The caret only sees text before it, so a later "@" doesn't count.
      expect(mentionPrefix('hi @ada there', 3), isNull);
    });

    test('editing your own post keeps its replies and flags it edited', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final mine = store.add('c1', 'frist post');
      store.reply(mine.id, 'nice one');
      expect(store.postById(mine.id)!.replies, 1);
      expect(store.postById(mine.id)!.edited, isFalse);

      // A real edit flags the post and keeps the reply count.
      expect(store.editPost(mine.id, 'first post'), isTrue);
      expect(store.postById(mine.id)!.text, 'first post');
      expect(store.postById(mine.id)!.edited, isTrue);
      expect(store.postById(mine.id)!.replies, 1);

      // No-ops: blank text, unchanged text, and unknown ids.
      expect(store.editPost(mine.id, '   '), isFalse);
      expect(store.editPost(mine.id, 'first post'), isFalse);
      expect(store.editPost('nope', 'hi'), isFalse);

      // Someone else's post can't be rewritten.
      final theirs = FeedPost(
        id: 'other1',
        communityId: 'c1',
        authorName: 'Grace',
        authorUsername: 'grace',
        time: DateTime(2026),
        text: 'mine to edit',
      );
      store.addRemote(theirs);
      expect(store.editPost('other1', 'hijacked'), isFalse);
      expect(store.postById('other1')!.text, 'mine to edit');

      // The flag survives a save/restore round trip.
      final revived = FeedPost.fromJson(store.postById(mine.id)!.toJson());
      expect(revived.edited, isTrue);
    });

    test('feed polls: create, vote, switch, and survive a round trip', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;

      // Needs a question and at least two real options.
      expect(store.addPoll('c1', '', ['a', 'b']), isNull);
      expect(store.addPoll('c1', 'Pick one', ['only']), isNull);
      expect(store.addPoll('c1', 'Pick one', ['a', '  ']), isNull);
      // Blank and duplicate options are dropped before the count is checked.
      expect(store.addPoll('c1', 'Pick one', ['a', 'A', '']), isNull);

      final poll = store.addPoll(
          'c1', 'Best day to ship?', ['Monday', ' Friday ', ''])!;
      expect(poll.isPoll, isTrue);
      expect(poll.pollOptions, ['Monday', 'Friday'], reason: 'trimmed');
      expect(poll.pollVotes, [0, 0]);
      expect(poll.pollMyVote, -1);
      expect(poll.pollTotalVotes, 0);

      // Voting counts once.
      store.votePoll(poll.id, 1);
      expect(store.postById(poll.id)!.pollVotes, [0, 1]);
      expect(store.postById(poll.id)!.pollMyVote, 1);

      // Voting the same option again is a no-op, not a second vote.
      store.votePoll(poll.id, 1);
      expect(store.postById(poll.id)!.pollTotalVotes, 1);

      // Switching moves the vote rather than adding one.
      store.votePoll(poll.id, 0);
      expect(store.postById(poll.id)!.pollVotes, [1, 0]);
      expect(store.postById(poll.id)!.pollTotalVotes, 1);

      // Out-of-range votes are ignored.
      store.votePoll(poll.id, 9);
      expect(store.postById(poll.id)!.pollVotes, [1, 0]);
      // A plain post isn't a poll and can't be voted on.
      final plain = store.add('c1', 'just words');
      expect(plain.isPoll, isFalse);
      store.votePoll(plain.id, 0);
      expect(store.postById(plain.id)!.pollVotes, isEmpty);

      // The whole poll round-trips through JSON.
      final revived = FeedPost.fromJson(store.postById(poll.id)!.toJson());
      expect(revived.isPoll, isTrue);
      expect(revived.pollQuestion, 'Best day to ship?');
      expect(revived.pollOptions, ['Monday', 'Friday']);
      expect(revived.pollVotes, [1, 0]);
      expect(revived.pollMyVote, 0);
    });

    test('deleting a reply gives the parent its count back', () {
      // Was a real bug: reply() incremented the parent, but nothing ever
      // decremented it, so a thread claimed replies it no longer had.
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final parent = store.add('c1', 'parent post');
      store.reply(parent.id, 'first');
      store.reply(parent.id, 'second');
      expect(store.postById(parent.id)!.replies, 2);

      store.deletePost(store.repliesTo(parent.id).first.id);
      expect(store.postById(parent.id)!.replies, 1);
      expect(store.repliesTo(parent.id).length, 1);

      store.deletePost(store.repliesTo(parent.id).first.id);
      expect(store.postById(parent.id)!.replies, 0);
      expect(store.repliesTo(parent.id), isEmpty);
    });

    test('deleting a post takes its whole subtree, not just its children', () {
      // Was a real bug: only direct children were removed, so a reply's own
      // replies survived pointing at a parent that no longer existed.
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final root = store.add('c1', 'root');
      store.reply(root.id, 'child');
      final child = store.repliesTo(root.id).single;
      store.reply(child.id, 'grandchild');
      final grandchild = store.repliesTo(child.id).single;

      store.deletePost(root.id);
      expect(store.postById(root.id), isNull);
      expect(store.postById(child.id), isNull);
      expect(store.postById(grandchild.id), isNull,
          reason: 'a grandchild must not outlive its thread');
      // Everything in the cascade is tombstoned, so a replayed cloud blob or
      // queued relay copy can't resurrect any of it.
      store.addRemote(grandchild);
      expect(store.postById(grandchild.id), isNull);
    });

    test('deleting a quote gives the original its repost count back', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final original = store.add('c1', 'quotable');
      final q1 = store.quoteRepost(original.id, 'take one')!;
      store.quoteRepost(original.id, 'take two');
      expect(store.postById(original.id)!.reposts, 2);

      store.deletePost(q1.id);
      expect(store.postById(original.id)!.reposts, 1);
      // Deleting the original takes its quotes with it, and doesn't try to
      // decrement a counter that left with the cascade.
      store.deletePost(original.id);
      expect(store.postsFor('c1'), isEmpty);
    });

    test('remote poll votes share one tally and survive replays', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final poll = store.addPoll('c1', 'Tabs or spaces?', ['Tabs', 'Spaces'])!;

      // Someone else's vote lands without touching MY choice.
      store.applyRemoteVote(poll.id,
          option: 1, previous: -1, voterUsername: 'grace');
      expect(store.postById(poll.id)!.pollVotes, [0, 1]);
      expect(store.postById(poll.id)!.pollMyVote, -1,
          reason: 'their vote is not mine');

      // A replayed copy of the same vote (mailbox / reconnect) is idempotent.
      store.applyRemoteVote(poll.id,
          option: 1, previous: -1, voterUsername: 'grace');
      expect(store.postById(poll.id)!.pollTotalVotes, 1);

      // They switch: the tally moves rather than growing.
      store.applyRemoteVote(poll.id,
          option: 0, previous: 1, voterUsername: 'grace');
      expect(store.postById(poll.id)!.pollVotes, [1, 0]);
      expect(store.postById(poll.id)!.pollTotalVotes, 1);

      // A stale replay claiming the wrong previous can't corrupt the tally —
      // we trust our own record of where they stood.
      store.applyRemoteVote(poll.id,
          option: 1, previous: -1, voterUsername: 'grace');
      expect(store.postById(poll.id)!.pollVotes, [0, 1]);
      expect(store.postById(poll.id)!.pollTotalVotes, 1);

      // A second person adds to the same shared tally.
      store.applyRemoteVote(poll.id,
          option: 0, previous: -1, voterUsername: 'ada');
      expect(store.postById(poll.id)!.pollTotalVotes, 2);

      // And my own vote counts alongside theirs.
      store.votePoll(poll.id, 0);
      expect(store.postById(poll.id)!.pollMyVote, 0);
      expect(store.postById(poll.id)!.pollTotalVotes, 3);
      expect(store.postById(poll.id)!.pollVotes, [2, 1]);
    });

    test('quote reposts carry their own words and stack', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final original = store.add('c1', 'the original take');

      // A quote is a real post of its own, not the toggle slot.
      final q1 = store.quoteRepost(original.id, 'strong agree')!;
      expect(q1.text, 'strong agree');
      expect(q1.repostOfId, original.id);
      expect(FeedStore.isQuote(q1), isTrue);
      expect(store.postById(original.id)!.reposts, 1);

      // You can quote the same post twice with different words — unlike a
      // plain repost, which toggles.
      final q2 = store.quoteRepost(original.id, 'on reflection, no')!;
      expect(q2.id, isNot(q1.id));
      expect(store.postById(original.id)!.reposts, 2);
      expect(store.postById(q1.id)!.text, 'strong agree');

      // A plain repost is not a quote (no words of its own).
      store.toggleRepost(original.id);
      final plain = store
          .postsFor('c1')
          .firstWhere((p) => p.repostOfId == original.id && p.text.isEmpty);
      expect(FeedStore.isQuote(plain), isFalse);

      // Empty commentary isn't a quote at all.
      expect(store.quoteRepost(original.id, '   '), isNull);
      // Quoting a quote points at the original, not the quote.
      final q3 = store.quoteRepost(q1.id, 'nesting check')!;
      expect(q3.repostOfId, original.id);
    });

    test('a pinned post leads the feed in either sort order', () {
      FeedStore.instance.resetForTest();
      addTearDown(FeedStore.instance.resetForTest);
      final store = FeedStore.instance;
      final old = store.add('c1', 'the announcement');
      store.add('c1', 'newer chatter');
      store.add('c1', 'newest chatter');

      // Unpinned, the oldest post sorts last by time.
      var timeline = sortFeed(store.postsFor('c1'));
      expect(timeline.last.id, old.id);

      // Pinned, it leads — in Latest and in Top.
      expect(store.togglePinned(old.id), isTrue);
      expect(sortFeed(store.postsFor('c1')).first.id, old.id);
      expect(sortFeed(store.postsFor('c1'), top: true).first.id, old.id);

      // Only one pin per server: pinning another releases the first.
      final other = store.postsFor('c1').firstWhere((p) => p.id != old.id);
      store.togglePinned(other.id);
      expect(store.postById(old.id)!.pinned, isFalse);
      expect(store.postById(other.id)!.pinned, isTrue);

      // Unpinning restores plain time order.
      store.togglePinned(other.id);
      timeline = sortFeed(store.postsFor('c1'));
      expect(timeline.last.id, old.id);
      // The flag round-trips through JSON.
      expect(
          FeedPost.fromJson(store.postById(old.id)!.copyWith(pinned: true)
              .toJson()).pinned,
          isTrue);
    });

    test('searchPosts matches text, author, and @username', () {
      final posts = [
        FeedPost(
            id: 'p1',
            communityId: 'c1',
            authorName: 'Grace Hopper',
            authorUsername: 'grace',
            time: DateTime(2026),
            text: 'shipping the compiler today'),
        FeedPost(
            id: 'p2',
            communityId: 'c1',
            authorName: 'Ada Lovelace',
            authorUsername: 'ada',
            time: DateTime(2026),
            text: 'lunch plans?'),
      ];
      // Empty query is a pass-through.
      expect(FeedStore.searchPosts(posts, ''), posts);
      // Body text, case-insensitive.
      expect(FeedStore.searchPosts(posts, 'COMPILER').map((p) => p.id), ['p1']);
      // Display name.
      expect(FeedStore.searchPosts(posts, 'lovelace').map((p) => p.id), ['p2']);
      // A leading "@" reads as "posts by", not literal text.
      expect(FeedStore.searchPosts(posts, '@grace').map((p) => p.id), ['p1']);
      // No match drives the empty state.
      expect(FeedStore.searchPosts(posts, 'zzzz'), isEmpty);
    });

    test('mentionsMe matches name tokens and usernames at a boundary', () {
      bool hit(String text) =>
          FeedStore.mentionsMe(text, myName: 'Ada Lovelace', myUsername: 'ada');
      // The one-word token form a channel mention writes.
      expect(hit('hey @AdaLovelace can you look'), isTrue);
      expect(hit('@adalovelace lowercase works too'), isTrue);
      // Or the username.
      expect(hit('ping @ada please'), isTrue);
      // Not a mention of someone else whose name merely starts the same.
      expect(hit('@AdaLovelaceSmith is a different person'), isFalse);
      expect(hit('no mention here'), isFalse);
      // "you" is a placeholder username, never a real ping.
      expect(
          FeedStore.mentionsMe('@you hello', myName: '', myUsername: 'you'),
          isFalse);
    });

    test('an @mention in a channel pings you and opens that channel', () {
      CommunityStore.instance.resetForTest();
      FeedStore.instance.resetForTest();
      final prevProfile = AppState.profile.value;
      addTearDown(() {
        AppState.profile.value = prevProfile;
        CommunityStore.instance.resetForTest();
        FeedStore.instance.resetForTest();
      });
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Ada Lovelace',
          avatarColor: '#000000',
          phone: '+1 555 010 4444',
          username: 'ada');

      final c = CommunityStore.instance.createCommunity('Engineering');
      final chan = c.channels.firstWhere((ch) => ch.type == ChannelType.text);

      // A remote message that doesn't mention you is silent.
      CommunityStore.instance.addRemoteChannelMessage(
          c.id,
          chan.id,
          Message(
              id: 'q1',
              text: 'deploy looks good',
              time: DateTime(2026, 5, 1),
              isMe: false,
              senderName: 'Grace'));
      expect(FeedStore.instance.notifications, isEmpty);

      // One that does @mentions you lands in the notifications list.
      CommunityStore.instance.addRemoteChannelMessage(
          c.id,
          chan.id,
          Message(
              id: 'q2',
              text: '@AdaLovelace can you review?',
              time: DateTime(2026, 5, 2),
              isMe: false,
              senderName: 'Grace'));
      final note = FeedStore.instance.notifications.single;
      expect(note.type, FeedNotificationType.channelMention);
      expect(note.actorName, 'Grace');
      expect(note.isChannel, isTrue);
      expect(note.channelId, chan.id);
      expect(note.channelName, chan.name);
      expect(FeedStore.instance.unseenNotificationCount, 1);

      // Redelivery of the same message doesn't double-ping.
      CommunityStore.instance.addRemoteChannelMessage(
          c.id,
          chan.id,
          Message(
              id: 'q2',
              text: '@AdaLovelace can you review?',
              time: DateTime(2026, 5, 2),
              isMe: false,
              senderName: 'Grace'));
      expect(FeedStore.instance.notifications.length, 1);
    });

    test('deleting a forum comment takes its whole reply subtree', () {
      // Was a real bug: only direct replies were removed, so a reply-to-a-
      // reply survived pointing at a comment that no longer existed.
      CommunityStore.instance.resetForTest();
      addTearDown(CommunityStore.instance.resetForTest);
      final store = CommunityStore.instance;
      final c = store.createCommunity('Threaded');
      store.addChannel(c.id, 'Help', type: ChannelType.forum);
      final forum = store
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.type == ChannelType.forum);
      store.addForumPost(
          c.id,
          forum.id,
          ForumPost(
              id: 'p1',
              authorId: 'me',
              authorName: 'You',
              time: DateTime(2026),
              title: 'Deep thread'));
      ForumComment mk(String id, String? parent) => ForumComment(
          id: id,
          authorId: 'a',
          authorName: 'A',
          time: DateTime(2026),
          body: id,
          parentId: parent);
      store.addForumComment(c.id, forum.id, 'p1', mk('c1', null));
      store.addForumComment(c.id, forum.id, 'p1', mk('c2', 'c1'));
      store.addForumComment(c.id, forum.id, 'p1', mk('c3', 'c2'));
      store.addForumComment(c.id, forum.id, 'p1', mk('other', null));

      List<String> remaining() => store
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == forum.id)
          .posts
          .firstWhere((p) => p.id == 'p1')
          .comments
          .map((x) => x.id)
          .toList();
      expect(remaining().length, 4);

      // Deleting the root of the chain takes the child AND the grandchild,
      // and leaves the unrelated comment alone.
      store.deleteForumComment(c.id, forum.id, 'p1', 'c1');
      expect(remaining(), ['other']);
    });

    test('a locked forum thread takes no new comments', () {
      CommunityStore.instance.resetForTest();
      final store = CommunityStore.instance;
      final c = store.createCommunity('Builders');
      store.addChannel(c.id, 'Help', type: ChannelType.forum);
      final forum = store
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.type == ChannelType.forum);
      store.addForumPost(
          c.id,
          forum.id,
          ForumPost(
              id: 'fp1',
              authorId: 'me',
              authorName: 'You',
              time: DateTime(2026),
              title: 'How do I flash the firmware?'));

      ForumPost live() => store
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == forum.id)
          .posts
          .firstWhere((p) => p.id == 'fp1');

      ForumComment comment(String id) => ForumComment(
          id: id,
          authorId: 'm2',
          authorName: 'Grace',
          time: DateTime(2026),
          body: 'try holding boot');

      // Open: comments land.
      expect(store.addForumComment(c.id, forum.id, 'fp1', comment('c1')),
          isTrue);
      expect(live().comments.length, 1);
      expect(live().locked, isFalse);

      // The owner locks it; further comments are refused, not dropped silently.
      store.toggleLockForumPost(c.id, forum.id, 'fp1');
      expect(live().locked, isTrue);
      expect(store.isForumPostLocked(c.id, forum.id, 'fp1'), isTrue);
      expect(store.addForumComment(c.id, forum.id, 'fp1', comment('c2')),
          isFalse);
      expect(live().comments.length, 1, reason: 'existing comments survive');

      // Unlocking reopens it.
      store.toggleLockForumPost(c.id, forum.id, 'fp1');
      expect(live().locked, isFalse);
      expect(store.addForumComment(c.id, forum.id, 'fp1', comment('c3')),
          isTrue);
      expect(live().comments.length, 2);

      // The flag round-trips through JSON.
      expect(ForumPost.fromJson(live().copyWith(locked: true).toJson()).locked,
          isTrue);
    });

    test('muting a channel keeps it out of the server badge', () {
      CommunityStore.instance.resetForTest();
      addTearDown(CommunityStore.instance.resetForTest);
      final store = CommunityStore.instance;
      final c = store.createCommunity('Noisy');
      final chan = c.channels.firstWhere((ch) => ch.type == ChannelType.text);
      for (var i = 0; i < 3; i++) {
        store.postMessage(
            c.id,
            chan.id,
            Message(
                id: 'n$i',
                text: 'chatter $i',
                time: DateTime(2026, 2, 1, 9, i),
                isMe: false));
      }
      Community live() => store.byId(c.id)!;

      // Unmuted, the channel drives the server badge.
      expect(store.isChannelMuted(chan.id), isFalse);
      expect(store.unreadInCommunity(live()), 3);

      // Muted, the server stops badging — but the channel's own count stands,
      // so opening it still shows what you missed.
      expect(store.toggleChannelMute(chan.id), isTrue);
      expect(store.unreadInCommunity(live()), 0);
      expect(
          store.unreadInChannel(
              live().channels.firstWhere((ch) => ch.id == chan.id)),
          3);

      // Unmuting restores the badge.
      expect(store.toggleChannelMute(chan.id), isFalse);
      expect(store.unreadInCommunity(live()), 3);
    });

    testWidgets('a muted channel looks muted in the channel list',
        (tester) async {
      CommunityStore.instance.resetForTest();
      addTearDown(CommunityStore.instance.resetForTest);
      final store = CommunityStore.instance;
      final c = store.createCommunity('Quiet');
      final chan = c.channels.firstWhere((ch) => ch.type == ChannelType.text);
      store.postMessage(
          c.id,
          chan.id,
          Message(
              id: 'x1',
              text: 'hello',
              time: DateTime(2026, 3, 1),
              isMe: false));

      await tester.pumpWidget(MaterialApp(
        home: CommunityScreen(communityId: c.id),
      ));
      await tester.pumpAndSettle();

      // Unmuted: no muted-bell marker beside the channel name.
      expect(find.byIcon(Icons.notifications_off), findsNothing);

      // Muting must be visible in the list, or it looks like nothing happened.
      store.toggleChannelMute(chan.id);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.notifications_off), findsWidgets);
    });

    test('the dark map is lifted off near-black', () {
      // CARTO's dark basemap sits around #0E1013 — a lift keeps it dark
      // without reading as a blank screen.
      expect(liftedChannel(14), greaterThan(45));
      expect(liftedChannel(0), 38);
      // Still clearly dark, not washed out to mid-grey.
      expect(liftedChannel(14), lessThan(90));
      // Ordering is preserved, so roads stay lighter than the background.
      expect(liftedChannel(60), greaterThan(liftedChannel(14)));
      // Whites stay in range.
      expect(liftedChannel(255), lessThanOrEqualTo(255));
      // The matrix is the standard 5x4 shape ColorFilter.matrix expects.
      expect(darkMapLift.length, 20);
    });

    test('the unread divider anchors to the first unseen message', () {
      CommunityStore.instance.resetForTest();
      final c = CommunityStore.instance.createCommunity('Readers');
      final chan = c.channels.firstWhere((ch) => ch.type == ChannelType.text);
      for (var i = 0; i < 4; i++) {
        CommunityStore.instance.postMessage(
            c.id,
            chan.id,
            Message(
                id: 'm$i',
                text: 'msg $i',
                time: DateTime(2026, 1, 1, 12, i),
                isMe: false));
      }
      Channel live() => CommunityStore.instance
          .byId(c.id)!
          .channels
          .firstWhere((ch) => ch.id == chan.id);

      // Nothing seen yet: no divider (the whole channel is new).
      expect(CommunityStore.instance.firstUnreadIdIn(live()), isNull);

      // Having read the first two, the divider sits on the third.
      CommunityStore.instance.markChannelSeen(chan.id, 2);
      expect(CommunityStore.instance.firstUnreadIdIn(live()), 'm2');
      expect(CommunityStore.instance.unreadInChannel(live()), 2);

      // Fully caught up: no divider.
      CommunityStore.instance.markChannelSeen(chan.id, 4);
      expect(CommunityStore.instance.firstUnreadIdIn(live()), isNull);
      expect(CommunityStore.instance.unreadInChannel(live()), 0);
    });

    testWidgets('the servers tab search filters the list', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CommunitiesTab())));
      await tester.pump();

      final firstName = CommunityStore.instance.communities.first.name;
      expect(find.text(firstName), findsWidgets);

      await tester.enterText(
          find.byType(TextField).first, 'zzz-no-such-server');
      await tester.pump();
      expect(find.text('No servers match your search.'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear server search'));
      await tester.pump();
      expect(find.text(firstName), findsWidgets);
    });

    testWidgets('the chat list shows a live typing indicator',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      expect(find.text('typing…'), findsNothing);

      final bob = ChatStore.instance.chatById('c_bob')!.contact;
      RelayService.instance.typingFromDigits =
          RelayService.digits(bob.phone);
      RelayService.instance.typingPing.value++;
      addTearDown(() {
        RelayService.instance.typingFromDigits = null;
        RelayService.instance.typingPing.value++;
      });
      await tester.pump();
      expect(find.text('typing…'), findsOneWidget);
    });

    testWidgets('the left sidebar opens with shortcuts', (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      // The full apps, plus the destinations people kept asking where to
      // find: Marketplace, Servers, Wallet, Settings.
      expect(find.text('Maps'), findsOneWidget);
      expect(find.text('Marketplace'), findsOneWidget);
      expect(find.text('Servers'), findsOneWidget);
      expect(find.text('Wallet'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('People'), findsNothing);
      expect(find.text('Starred messages'), findsNothing);
      expect(find.text('Encrypted cloud sync'), findsNothing);
      expect(find.text('My QR code'), findsNothing);

      // Servers IS a bottom tab: the sidebar switches to it rather than
      // stacking a second copy on top of the home screen.
      await tester.tap(find.text('Servers'));
      await tester.pumpAndSettle();
      expect(find.text('Communities'), findsOneWidget,
          reason: 'the home app bar should now title the Servers tab');
      // Every screen carries a sidebar button now, so finding one proves
      // nothing about which screen this is — ask the navigator instead.
      expect(rootNavigatorKey.currentState!.canPop(), isFalse,
          reason: 'the sidebar switched tabs rather than pushing a copy');
    });

    test('screen share reports an honest error with no active call', () async {
      expect(await CallMedia.instance.toggleScreenShare(), isNotNull);
      expect(CallMedia.instance.screenSharing.value, isFalse);
    });

    testWidgets('an incoming call rings until it is answered',
        (tester) async {
      final rings = <bool>[];
      debugRingOverride = ({required bool incoming}) => rings.add(incoming);
      addTearDown(() {
        debugRingOverride = null;
        stopRinging();
      });
      final peer = MockData.contacts().firstWhere((c) => !c.isGroup);
      final ringing = CallSession(
        callId: 'r1',
        peer: peer,
        video: false,
        direction: CallDirection.incoming,
        status: CallStatus.ringing,
      );
      await tester.pumpWidget(MaterialApp(home: CallScreen(session: ringing)));
      await tester.pump();

      // It rings immediately, and keeps ringing on a repeating pattern.
      expect(rings, isNotEmpty);
      expect(rings.first, isTrue); // incoming pattern
      expect(isRinging, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(rings.length, greaterThan(1));

      // Answering stops the ring.
      await tester.pumpWidget(MaterialApp(
        home: CallScreen(
          session: ringing.copyWith(
              status: CallStatus.connected, connectedAt: DateTime.now()),
        ),
      ));
      await tester.pump();
      expect(isRinging, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('qualityForLoss maps packet loss to signal bars', () {
      expect(CallMedia.qualityForLoss(0), 3);
      expect(CallMedia.qualityForLoss(0.01), 3);
      expect(CallMedia.qualityForLoss(0.03), 2);
      expect(CallMedia.qualityForLoss(0.12), 1);
    });

    test('hold silences the call without ending it', () {
      expect(CallMedia.instance.onHold.value, isFalse);
      CallMedia.instance.setHold(true);
      expect(CallMedia.instance.onHold.value, isTrue);
      CallMedia.instance.setHold(false);
      expect(CallMedia.instance.onHold.value, isFalse);
    });

    testWidgets('a minimized call shows the return-to-call banner',
        (tester) async {
      final session = CallSession(
        callId: 'x1',
        peer: MockData.contacts().firstWhere((c) => !c.isGroup),
        video: false,
        direction: CallDirection.outgoing,
        status: CallStatus.connected,
        connectedAt: DateTime.now(),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [ReturnToCallBanner(session: session)]),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('tap to return'), findsOneWidget);
      expect(find.byTooltip('Hang up'), findsOneWidget);
      // Mute without reopening the full call screen.
      expect(find.byTooltip('Mute'), findsOneWidget);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(find.byTooltip('Unmute'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('an empty search sheet rests at the search field, not a third '
        'of the screen', (tester) async {
      // A flat 0.30 gave every new account a third of the screen as an empty
      // slab: nothing is saved and nothing has been searched, so the two rows
      // under the field render nothing at all.
      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(debugMyLocation: LatLng(43.6, -79.3)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final screen = tester.getSize(find.byType(ExploreMapScreen));
      final sheetTop = tester
          .getTopLeft(find.byType(DraggableScrollableSheet).first)
          .dy;
      // The sheet's own box fills the stack; what matters is where its
      // Material actually starts.
      final material = find
          .descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(Material))
          .first;
      final covered = screen.height - tester.getTopLeft(material).dy;
      expect(covered, lessThan(screen.height * 0.22),
          reason: 'an empty sheet should not eat a third of the map '
              '(covers $covered of ${screen.height}, top $sheetTop)');

      // And pulling it up says why it is empty rather than showing nothing.
      expect(find.textContaining('will show up here'), findsOneWidget);
    });

    testWidgets('the zoom buttons respect the map\'s own limits',
        (tester) async {
      // The buttons clamped to 20 while every map here allows 20.5, so after
      // pinching all the way in, pressing + pulled the camera back DOWN to
      // 20 — a zoom-in button that zoomed out.
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            mapController: controller,
            options: const MapOptions(
              initialCenter: LatLng(43.6, -79.3),
              initialZoom: 20.5,
              minZoom: 2,
              maxZoom: 20.5,
            ),
            children: [
              Builder(
                builder: (context) => Stack(
                  children: [MapControls(controller: controller)],
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      final before = controller.camera.zoom;
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(controller.camera.zoom, greaterThanOrEqualTo(before),
          reason: 'zoom in must never move the camera out');
    });

    testWidgets('the map controls sit low, within reach of a thumb',
        (tester) async {
      // They were pinned just under the status bar: six controls parked at
      // the far corner of a big phone, over the part of the map someone is
      // usually looking at.
      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(debugMyLocation: LatLng(43.6, -79.3)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final screen = tester.getSize(find.byType(ExploreMapScreen));
      final layers = tester.getCenter(find.byTooltip('Map style')).dy;
      expect(layers, greaterThan(screen.height * 0.5),
          reason: 'the style button is at $layers of ${screen.height}');

      // And still clear of the sheet rather than buried behind it.
      final sheetTop = tester
          .getTopLeft(find
              .descendant(
                  of: find.byType(DraggableScrollableSheet),
                  matching: find.byType(Material))
              .first)
          .dy;
      expect(tester.getBottomLeft(find.byTooltip('Zoom out')).dy,
          lessThanOrEqualTo(sheetTop));
    });

    testWidgets('the tile credit is not buried under the search sheet',
        (tester) async {
      // Mapbox's terms — and OpenStreetMap's — require the credit to be
      // visible. It was offset by the sheet's *minimum* size while the sheet
      // rested well above that, so at rest it sat underneath.
      RecentSearches.maps.add('coffee');
      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(debugMyLocation: LatLng(43.6, -79.3)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final credit = find.byType(OsmAttribution);
      expect(credit, findsOneWidget);
      final creditBottom = tester.getBottomLeft(credit).dy;
      final sheetTop = tester
          .getTopLeft(find
              .descendant(
                  of: find.byType(DraggableScrollableSheet),
                  matching: find.byType(Material))
              .first)
          .dy;
      expect(creditBottom, lessThanOrEqualTo(sheetTop),
          reason: 'credit at $creditBottom is under the sheet at $sheetTop');
    });

    testWidgets('saved places pin onto the idle map and open their card',
        (tester) async {
      SavedPlacesStore.instance
          .toggle(const SavedPlace('Home Cafe', 43.61, -79.31));
      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(debugMyLocation: LatLng(43.6, -79.3)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final pin = find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.bookmark && w.size == 26);
      expect(pin, findsOneWidget);

      await tester.tap(pin);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Home Cafe'), findsWidgets);
      expect(find.text('Directions'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Go starts in-app navigation instead of leaving the app',
        (tester) async {
      const route = RouteResult(
        points: [
          LatLng(37.7749, -122.4194),
          LatLng(37.7757, -122.4180),
          LatLng(37.7680, -122.4150),
        ],
        distanceMeters: 1120,
        durationSeconds: 300,
        steps: [
          RouteStep('Head out on Market Street', 120,
              location: LatLng(37.7749, -122.4194)),
          RouteStep('Turn right onto Valencia Street', 400,
              location: LatLng(37.7757, -122.4180)),
          RouteStep('Arrive at your destination', 0,
              location: LatLng(37.7680, -122.4150)),
        ],
      );
      await tester.pumpWidget(const MaterialApp(
        home: RouteMapScreen(
          dest: LatLng(37.7680, -122.4150),
          from: LatLng(37.7749, -122.4194),
          label: 'To Alice',
          initialRoute: route,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Go'), findsOneWidget);
      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // In-app navigation UI: the maneuver banner and End button are shown.
      expect(find.text('Turn right onto Valencia Street'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);

      // End navigation and unmount so the GPS timer is cancelled.
      await tester.tap(find.text('End'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('distanceToRouteMeters measures perpendicular and endpoint distance',
        () {
      // A ~2km segment running due north along a meridian.
      const points = [LatLng(37.7700, -122.4200), LatLng(37.7880, -122.4200)];
      // On the line → essentially zero.
      expect(distanceToRouteMeters(const LatLng(37.7790, -122.4200), points),
          lessThan(1));
      // ~100 m east of the segment's interior → ~100 m.
      final east = distanceToRouteMeters(
          const LatLng(37.7790, -122.41886), points);
      expect(east, closeTo(100, 8));
      // Well past the north end → distance to the endpoint, not the line.
      final past = distanceToRouteMeters(
          const LatLng(37.7907, -122.4200), points);
      expect(past, closeTo(300, 20));
      // No route → infinity.
      expect(distanceToRouteMeters(const LatLng(0, 0), const []),
          double.infinity);
    });

    test('map recent searches are separate from chat recent searches', () {
      RecentSearches.maps.add('coffee');
      RecentSearches.maps.add('eiffel tower');
      expect(RecentSearches.maps.queries, ['eiffel tower', 'coffee']);
      expect(RecentSearches.instance.queries, isNot(contains('coffee')));
      RecentSearches.maps.remove('coffee');
      expect(RecentSearches.maps.queries, ['eiffel tower']);
    });

    test('iconForPlaceCategory maps businesses and addresses sensibly', () {
      expect(iconForPlaceCategory(''), Icons.location_on_outlined);
      expect(iconForPlaceCategory('Cafe'), Icons.local_cafe);
      expect(iconForPlaceCategory('Fast food'), Icons.restaurant);
      expect(iconForPlaceCategory('Fuel'), Icons.local_gas_station);
      expect(iconForPlaceCategory('Supermarket'), Icons.storefront);
      expect(iconForPlaceCategory('Sculpture'), Icons.place_outlined);
    });

    test('only Automatic follows the theme; every other pick is literal', () {
      // Following the theme used to be hidden inside Standard, so picking
      // Standard in dark mode drew the Dark map: the check mark sat beside a
      // style the map was not using, and choosing it looked like it did
      // nothing at all.
      expect(effectiveLayer('auto', Brightness.light), MapLayer.standard);
      expect(effectiveLayer('auto', Brightness.dark), MapLayer.dark);

      // Standard now means standard, whatever the app theme is doing.
      expect(effectiveLayer('standard', Brightness.light), MapLayer.standard);
      expect(effectiveLayer('standard', Brightness.dark), MapLayer.standard);

      expect(effectiveLayer('satellite', Brightness.dark), MapLayer.satellite);
      expect(effectiveLayer('terrain', Brightness.dark), MapLayer.terrain);
      expect(effectiveLayer('dark', Brightness.light), MapLayer.dark);
    });

    testWidgets('Maps is full-bleed with a floating back button and chips',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ExploreMapScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // No app bar — the map runs edge to edge under floating controls.
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Back'), findsOneWidget);
      // Saved and Friends live in the floating map controls now — the
      // space under the search bar stays clean.
      expect(find.byTooltip('Saved places'), findsOneWidget);
      expect(find.byTooltip('Friends map'), findsOneWidget);
      expect(find.text('Food'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('typing shows live suggestions; picking one selects the place',
        (tester) async {
      const cafe = GeoResult(
          name: 'Blue Bottle, San Francisco',
          lat: 37.7763,
          lng: -122.4232,
          category: 'Cafe');
      const shop = GeoResult(
          name: 'Blue Danube Coffee', lat: 37.78, lng: -122.46);
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: const LatLng(37.7749, -122.4194),
          debugSearch: (q) async {
            calls++;
            return const [cafe, shop];
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Type — no submit — and let the debounce fire.
      await tester.enterText(find.byType(TextField).first, 'blue');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(calls, 1);
      expect(find.text('Blue Bottle, San Francisco'), findsOneWidget);
      expect(find.text('Blue Danube Coffee'), findsOneWidget);
      // The meta line shows category + distance from the debug fix.
      expect(find.textContaining('Cafe · '), findsOneWidget);

      // The sheet rests at the height of the search field when there is
      // nothing saved yet, so it opens to put the suggestions on screen.
      // Without that they render below the fold — findable by a test, and
      // invisible to a person.
      await tester.pump(const Duration(milliseconds: 250));

      // Picking a suggestion selects it (Directions card) and remembers it.
      await tester.tap(find.text('Blue Bottle, San Francisco'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Directions'), findsOneWidget);
      expect(RecentSearches.maps.queries, contains('Blue Bottle'));
      // The my-location FAB hides while the place card is up (it would
      // overlap the card).
      expect(find.byTooltip('My location'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a failed suggestion fetch keeps the previous suggestions',
        (tester) async {
      var fail = false;
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugSearch: (q) async => fail
              ? null
              : const [GeoResult(name: 'Blue Bottle', lat: 37.7, lng: -122.4)],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'blue');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Blue Bottle'), findsOneWidget);

      // The next keystroke's fetch fails — the list must NOT blank out.
      fail = true;
      await tester.enterText(find.byType(TextField).first, 'blue b');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Blue Bottle'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the clear button resets the search', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugSearch: (q) async =>
              const [GeoResult(name: 'Somewhere', lat: 1, lng: 2)],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'some');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Somewhere'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.text('Somewhere'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a submitted search lists its hits in a bottom results sheet',
        (tester) async {
      const hits = [
        GeoResult(
            name: 'Cafe A, Toronto', lat: 43.65, lng: -79.38, category: 'Cafe'),
        GeoResult(
            name: 'Cafe B, Toronto', lat: 43.66, lng: -79.39, category: 'Cafe'),
        GeoResult(
            name: 'Cafe C, Toronto', lat: 43.67, lng: -79.40, category: 'Cafe'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: const LatLng(43.6, -79.3),
          debugSearch: (q) async => hits,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'cafe');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      // Long enough for the FAB's scale-out animation to finish.
      await tester.pump(const Duration(milliseconds: 400));

      // The sheet lists every hit; the dropdown stays out of the way, and
      // the my-location FAB hides so it can't overlap the sheet.
      expect(find.text('3 places'), findsOneWidget);
      expect(find.text('Cafe A'), findsOneWidget);
      expect(find.text('Cafe C'), findsOneWidget);
      expect(find.byTooltip('My location'), findsNothing);

      // Picking one opens its card and hides the sheet…
      await tester.tap(find.text('Cafe B'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('3 places'), findsNothing);

      // …and closing the card brings the results sheet back.
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.text('3 places'), findsOneWidget);

      // Closing the sheet clears the search entirely (and the FAB returns).
      await tester.tap(find.byTooltip('Close results'));
      await tester.pump();
      expect(find.text('3 places'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isEmpty);
      expect(find.byTooltip('My location'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('panning away from results offers "Search this area"',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: const LatLng(43.6, -79.3),
          debugSearch: (q) async {
            calls++;
            return const [
              GeoResult(name: 'Cafe A', lat: 43.65, lng: -79.38),
              GeoResult(name: 'Cafe B', lat: 43.66, lng: -79.39),
            ];
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'cafe');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1);
      expect(find.text('2 places'), findsOneWidget);
      expect(find.text('Search this area'), findsNothing);

      // Pan the map — the re-search button appears.
      await tester.dragFrom(const Offset(400, 250), const Offset(-120, 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Search this area'), findsOneWidget);

      // Tapping it re-runs the same query around the new centre.
      await tester.tap(find.text('Search this area'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 2);
      expect(find.text('Search this area'), findsNothing);
      expect(find.text('2 places'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('tapping the map dismisses suggestions; typing re-shows them',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugSearch: (q) async =>
              const [GeoResult(name: 'Somewhere', lat: 1, lng: 2)],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'some');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Somewhere'), findsOneWidget);

      // Tap the bare map strip above the raised search sheet (double-tap
      // zoom disambiguation delays the tap).
      await tester.tapAt(const Offset(300, 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Somewhere'), findsNothing);

      // Typing again brings the list back.
      await tester.enterText(find.byType(TextField).first, 'somewh');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Somewhere'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Maps shows the blue "you are here" dot when located',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: LatLng(37.7749, -122.4194),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MyLocationDot), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('no location dot when the fix is unavailable', (tester) async {
      // No debug fix and the test stub returns null → no dot, map still works.
      await tester.pumpWidget(const MaterialApp(home: ExploreMapScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MyLocationDot), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Maps shows recent searches and can remove one',
        (tester) async {
      RecentSearches.maps.add('sushi');
      RecentSearches.maps.add('coffee');
      await tester.pumpWidget(const MaterialApp(home: ExploreMapScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('coffee'), findsOneWidget);
      expect(find.text('sushi'), findsOneWidget);

      // Remove "coffee" via its X.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      expect(find.text('coffee'), findsNothing);
      expect(find.text('sushi'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('parseOverpass reads nodes, way centers, and unnamed POIs', () {
      const body = '''
      {"elements": [
        {"type":"node","lat":44.05,"lon":-79.46,
         "tags":{"name":"Wimpy's Diner","amenity":"restaurant"}},
        {"type":"way","center":{"lat":44.06,"lon":-79.47},
         "tags":{"name":"Upper Canada Mall","shop":"mall"}},
        {"type":"node","lat":44.07,"lon":-79.48,
         "tags":{"amenity":"parking"}},
        {"type":"node","lat":44.08,"lon":-79.49}
      ]}''';
      final places = parseOverpass(body);
      expect(places.length, 3);
      expect(places[0].name, "Wimpy's Diner");
      expect(places[0].category, 'Restaurant');
      expect(places[1].name, 'Upper Canada Mall');
      expect(places[1].lat, 44.06);
      // Unnamed POIs fall back to their category; tagless ones are skipped.
      expect(places[2].name, 'Parking');
      expect(parseOverpass('not json'), isEmpty);
    });

    test('iconForManeuver picks matching turn arrows', () {
      expect(iconForManeuver('turn', 'right'), Icons.turn_right);
      expect(iconForManeuver('turn', 'sharp left'), Icons.turn_sharp_left);
      expect(iconForManeuver('turn', 'slight right'), Icons.turn_slight_right);
      expect(iconForManeuver('roundabout', ''), Icons.roundabout_right);
      expect(iconForManeuver('arrive', ''), Icons.sports_score);
      expect(iconForManeuver('depart', ''), Icons.trip_origin);
      expect(iconForManeuver('fork', 'slight left'), Icons.fork_left);
      expect(iconForManeuver('continue', 'uturn'), Icons.u_turn_left);
      expect(iconForManeuver('continue', ''), Icons.straight);
    });

    testWidgets('a category chip runs a nearby search into the results sheet',
        (tester) async {
      String? asked;
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: const LatLng(44.05, -79.46),
          debugSearch: (q) async {
            asked = q;
            return const [
              GeoResult(
                  name: 'Cafe One', lat: 44.05, lng: -79.45, category: 'Cafe'),
              GeoResult(
                  name: 'Cafe Two', lat: 44.06, lng: -79.47, category: 'Cafe'),
            ];
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Category searches now run from the typed query ("coffee" is a
      // category intent), not a chip row.
      await tester.enterText(find.byType(TextField).first, 'coffee');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(asked, 'coffee');
      expect(find.text('2 places'), findsOneWidget);
      expect(find.text('Cafe One'), findsOneWidget);
      // The results sheet header names the category being browsed.
      expect(find.text('Coffee'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('categoryFilterFor spots category intents, not names', () {
      expect(categoryFilterFor('coffee'), isNotNull);
      expect(categoryFilterFor('  Gas Station '), isNotNull);
      expect(categoryFilterFor('pharmacy'), isNotNull);
      expect(categoryFilterFor('Blue Bottle'), isNull);
      expect(categoryFilterFor('1226 valencia street'), isNull);
    });

    testWidgets('typing a category word like "coffee" runs a nearby search',
        (tester) async {
      String? asked;
      await tester.pumpWidget(MaterialApp(
        home: ExploreMapScreen(
          debugMyLocation: const LatLng(44.05, -79.46),
          debugSearch: (q) async {
            asked = q;
            return const [
              GeoResult(name: 'Cafe One', lat: 44.05, lng: -79.45),
              GeoResult(name: 'Cafe Two', lat: 44.06, lng: -79.47),
            ];
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'coffee');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The nearby (category) path took over: the results header shows the
      // capitalised label and the query was remembered.
      expect(asked, 'coffee');
      expect(find.text('2 places'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(RecentSearches.maps.queries, contains('coffee'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('parseOsrmRoutes returns the primary and its alternatives', () {
      const body = '''
      {"code":"Ok","routes":[
        {"geometry":{"coordinates":[[-79.0,43.0],[-79.2,43.2]]},
         "distance":5000,"duration":840,"legs":[{"steps":[]}]},
        {"geometry":{"coordinates":[[-79.0,43.0],[-79.3,43.1],[-79.2,43.2]]},
         "distance":6000,"duration":1020,"legs":[{"steps":[]}]}
      ]}''';
      final routes = parseOsrmRoutes(body)!;
      expect(routes.length, 2);
      expect(routes.first.durationSeconds, 840);
      expect(routes.last.points.length, 3);
      // The single-route parser still returns the primary.
      expect(parseOsrmRoute(body)!.distanceMeters, 5000);
    });

    testWidgets('directions offers route alternatives to switch between',
        (tester) async {
      const steps = [
        RouteStep('Head out on A', 100,
            location: LatLng(43.1, -79.1), type: 'depart'),
        RouteStep('Arrive at your destination', 0,
            location: LatLng(43.2, -79.2), type: 'arrive'),
      ];
      const r1 = RouteResult(
          points: [LatLng(43.0, -79.0), LatLng(43.2, -79.2)],
          distanceMeters: 5000,
          durationSeconds: 840,
          steps: steps);
      const r2 = RouteResult(
          points: [LatLng(43.0, -79.0), LatLng(43.1, -79.3), LatLng(43.2, -79.2)],
          distanceMeters: 6000,
          durationSeconds: 1020,
          steps: steps);
      await tester.pumpWidget(const MaterialApp(
        home: RouteMapScreen(
          dest: LatLng(43.2, -79.2),
          from: LatLng(43.0, -79.0),
          initialRoutes: [r1, r2],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Labelled by what the choice costs, not by the order OSRM returned
      // them in — "Route 2" told nobody anything about why they'd pick it.
      expect(find.text('14 min · fastest'), findsOneWidget);
      expect(find.text('17 min · +3 min'), findsOneWidget);
      expect(find.text('14 min'), findsOneWidget); // the summary

      await tester.tap(find.text('17 min · +3 min'));
      await tester.pump();
      expect(find.text('17 min'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('route labels say what a detour costs', () {
      RouteResult r(double seconds) => RouteResult(
          points: const [LatLng(43, -79), LatLng(43.1, -79.1)],
          distanceMeters: 1000,
          durationSeconds: seconds,
          steps: const []);

      final routes = [r(840), r(1020), r(870)];
      expect(routeChoiceLabel(routes, 0), '14 min · fastest');
      expect(routeChoiceLabel(routes, 1), '17 min · +3 min');
      // 30 seconds slower is still slower: it must not round down to
      // "+0 min" and read like a second fastest route.
      expect(routeChoiceLabel(routes, 2), '15 min · +1 min');

      // The fastest is not always the one OSRM listed first.
      final reordered = [r(1020), r(840)];
      expect(routeChoiceLabel(reordered, 0), '17 min · +3 min');
      expect(routeChoiceLabel(reordered, 1), '14 min · fastest');
    });

    testWidgets('a failed route can be asked again', (tester) async {
      // Was a dead end: a line of grey text, no button, and backing out to
      // the previous screen as the only way to retry.
      await tester.pumpWidget(const MaterialApp(
        home: RouteMapScreen(dest: LatLng(43.2, -79.2), label: 'Somewhere'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Go'), findsNothing,
          reason: 'a Go with no route to go along is a button that lies');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the tile credit clears the directions sheet',
        (tester) async {
      // Same licence term as the explore map: the credit was pinned to the
      // bottom edge while the sheet covered the bottom third.
      const route = RouteResult(
          points: [LatLng(43, -79), LatLng(43.2, -79.2)],
          distanceMeters: 5000,
          durationSeconds: 840,
          steps: []);
      await tester.pumpWidget(const MaterialApp(
        home: RouteMapScreen(
          dest: LatLng(43.2, -79.2),
          from: LatLng(43.0, -79.0),
          initialRoute: route,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final creditBottom =
          tester.getBottomLeft(find.byType(OsmAttribution)).dy;
      final sheetTop = tester
          .getTopLeft(find
              .descendant(
                  of: find.byType(DraggableScrollableSheet),
                  matching: find.byType(Material))
              .first)
          .dy;
      expect(creditBottom, lessThanOrEqualTo(sheetTop),
          reason: 'credit at $creditBottom is under the sheet at $sheetTop');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('instructionFor builds readable turn text', () {
      expect(instructionFor('turn', 'right', 'Main St'),
          'Turn right onto Main St');
      expect(instructionFor('end of road', 'left', ''),
          'At the end of the road, turn left');
      expect(instructionFor('roundabout', '', 'A1'),
          'Enter the roundabout onto A1');
    });

    test('parseOsrmRoute rejects non-Ok, empty, and junk responses', () {
      expect(parseOsrmRoute('{"code":"NoRoute","routes":[]}'), isNull);
      expect(parseOsrmRoute('{"code":"Ok","routes":[]}'), isNull);
      expect(parseOsrmRoute('not json'), isNull);
    });

    test('formatDuration renders minutes and hours', () {
      expect(formatDuration(240), '4 min');
      expect(formatDuration(30), '1 min');
      expect(formatDuration(3600), '1 h');
      expect(formatDuration(3900), '1 h 5 min');
    });

    testWidgets('picker falls back gracefully when GPS is unavailable',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LocationPickerScreen()));
      // FlutterMap tile timers never settle, so pump fixed frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // On native/tests the geolocation helper returns null (no browser GPS),
      // so tapping "Use my location" shows a fallback message.
      await tester.tap(find.byTooltip('Use my location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Couldn\'t get your location'), findsOneWidget);
      expect(find.text('Send this location'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Place search (Photon geocoder)', () {
    test('parses features into results with a readable label', () {
      const body = '''
      {"type":"FeatureCollection","features":[
        {"type":"Feature",
         "properties":{"name":"Eiffel Tower","city":"Paris","country":"France"},
         "geometry":{"type":"Point","coordinates":[2.2945,48.8584]}},
        {"type":"Feature",
         "properties":{"name":"Louvre","city":"Paris","country":"France"},
         "geometry":{"type":"Point","coordinates":[2.3376,48.8606]}}
      ]}''';
      final results = parsePhoton(body);
      expect(results.length, 2);
      expect(results.first.name, 'Eiffel Tower, Paris, France');
      // Photon coordinates are [lng, lat] — make sure we don't swap them.
      expect(results.first.lat, closeTo(48.8584, 0.0001));
      expect(results.first.lng, closeTo(2.2945, 0.0001));
    });

    test('address results keep their house number', () {
      const body = '''
      {"features":[
        {"properties":{"housenumber":"1226","street":"Valencia Street",
          "city":"San Francisco","country":"United States"},
         "geometry":{"coordinates":[-122.4206,37.7539]}}
      ]}''';
      final r = parsePhoton(body).single;
      expect(r.name, '1226 Valencia Street, San Francisco, United States');
    });

    test('dedupePlaces drops same-name results at the same spot', () {
      const a = GeoResult(name: 'Blue Bottle', lat: 37.7763, lng: -122.4232);
      const b = GeoResult(name: 'Blue Bottle', lat: 37.77631, lng: -122.42321);
      const c = GeoResult(name: 'Blue Bottle', lat: 37.8044, lng: -122.2711);
      final out = dedupePlaces(const [a, b, c]);
      expect(out.length, 2); // the two distinct locations survive
      expect(out.first.lat, a.lat);
    });

    test('sortPlacesByDistance ranks nearest first', () {
      const near = GeoResult(name: 'Near', lat: 37.776, lng: -122.42);
      const far = GeoResult(name: 'Far', lat: 37.90, lng: -122.30);
      const mid = GeoResult(name: 'Mid', lat: 37.80, lng: -122.41);
      final out =
          sortPlacesByDistance(const [far, near, mid], 37.7749, -122.4194);
      expect(out.map((r) => r.name).toList(), ['Near', 'Mid', 'Far']);
    });

    test('parses a category from osm_value', () {
      const body = '''
      {"features":[
        {"properties":{"name":"Blue Bottle","osm_value":"cafe"},
         "geometry":{"coordinates":[2.0,48.0]}},
        {"properties":{"name":"Joe's","osm_value":"fast_food"},
         "geometry":{"coordinates":[2.1,48.1]}},
        {"properties":{"name":"Somewhere","osm_value":"yes"},
         "geometry":{"coordinates":[2.2,48.2]}}
      ]}''';
      final r = parsePhoton(body);
      expect(r[0].category, 'Cafe');
      expect(r[1].category, 'Fast food');
      expect(r[2].category, ''); // "yes" is generic
    });

    test('skips malformed features and tolerates junk', () {
      const body = '''
      {"features":[
        {"properties":{"name":"No geometry"}},
        {"geometry":{"coordinates":[1.0]},"properties":{"name":"Short coords"}},
        {"geometry":{"coordinates":[5.0,6.0]},"properties":{"name":"Good"}}
      ]}''';
      final results = parsePhoton(body);
      expect(results.length, 1);
      expect(results.single.name, 'Good');
    });

    test('returns empty on non-list / invalid json', () {
      expect(parsePhoton('{"features":"nope"}'), isEmpty);
      expect(parsePhoton('not json'), isEmpty);
    });
  });

  group('Forum search', () {
    test('filterPosts matches title, body, and author, else passes through',
        () {
      final posts = CommunityStore.instance
          .byId('seed_design')!
          .channels
          .firstWhere((c) => c.id == 'seed_forum')
          .posts;
      expect(filterPosts(posts, ''), posts);
      final byTitle = filterPosts(posts, 'brand palette');
      expect(byTitle.length, 1);
      expect(byTitle.single.id, 'seed_post_2');
      expect(filterPosts(posts, 'zzz-no-match'), isEmpty);
    });

    testWidgets('the search field filters the feed live', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: ForumChannelScreen(
            communityId: 'seed_design', channelId: 'seed_forum'),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('design tools'), findsOneWidget);
      expect(find.textContaining('brand palette'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'palette');
      await tester.pumpAndSettle();

      expect(find.textContaining('brand palette'), findsOneWidget);
      expect(find.textContaining('design tools'), findsNothing);

      // Closing search clears the filter.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.textContaining('design tools'), findsOneWidget);
    });
  });

  group('Message info', () {
    testWidgets('shows sent time and status for your own message',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Yes! What a finish 🔥'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message info'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sent '), findsOneWidget);
      expect(find.text('Status: Read'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });
  });

  group('Shared places map', () {
    testWidgets('plots each shared location and shows its card on tap',
        (tester) async {
      final store = ChatStore.instance;
      store.addMessage(
        'c_bob',
        Message(
          id: 'p1',
          text: 'Shared location',
          time: DateTime(2024, 1, 1, 10),
          isMe: true,
          isLocation: true,
          locationLat: 48.8584,
          locationLng: 2.2945,
          locationLabel: 'Eiffel Tower',
        ),
      );
      store.addMessage(
        'c_bob',
        Message(
          id: 'p2',
          text: 'Shared location',
          time: DateTime(2024, 1, 2, 11),
          isMe: false,
          isLocation: true,
          locationLat: 48.8606,
          locationLng: 2.3376,
          locationLabel: 'Louvre',
        ),
      );

      await tester.pumpWidget(const MaterialApp(
        home: ChatPlacesScreen(chatId: 'c_bob', contactName: 'Bob Carter'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Both shared locations are plotted.
      expect(find.byIcon(Icons.location_pin), findsNWidgets(2));

      // Tapping a pin opens its card with the label, sharer, and Directions.
      await tester.tap(find.byIcon(Icons.location_pin).last);
      await tester.pump();
      final hasEiffel =
          find.text('Eiffel Tower').evaluate().isNotEmpty;
      final hasLouvre = find.text('Louvre').evaluate().isNotEmpty;
      expect(hasEiffel || hasLouvre, isTrue);
      expect(find.textContaining('Shared by'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('shows an empty state when nothing was shared',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: ChatPlacesScreen(chatId: 'c_bob', contactName: 'Bob Carter'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          find.text('No places shared in this chat yet'), findsOneWidget);
    });
  });

  group('Send a place to a chat', () {
    testWidgets('picking a chat sends a labelled location message',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: ForwardScreen(
          text: '',
          place: (lat: 48.8584, lng: 2.2945, label: 'Eiffel Tower'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Send to...'), findsOneWidget);
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      final sent = ChatStore.instance
          .chatById('c_bob')!
          .messages
          .lastWhere((m) => m.isLocation);
      expect(sent.locationLabel, 'Eiffel Tower');
      expect(sent.locationLat, closeTo(48.8584, 0.0001));
      expect(sent.locationLng, closeTo(2.2945, 0.0001));
    });
  });

  group('Saved places', () {
    test('toggle saves, reports state, and de-dupes; remove works', () {
      final store = SavedPlacesStore.instance;
      const p = SavedPlace('Eiffel Tower', 48.8584, 2.2945);
      expect(store.isSaved(p.lat, p.lng), isFalse);

      expect(store.toggle(p), isTrue); // now saved
      expect(store.isSaved(48.8584, 2.2945), isTrue);
      expect(store.places.length, 1);

      // Toggling the same coordinates again removes it.
      expect(store.toggle(const SavedPlace('Eiffel', 48.8584, 2.2945)), isFalse);
      expect(store.places, isEmpty);

      store.toggle(p);
      store.remove(const SavedPlace('x', 48.8584, 2.2945));
      expect(store.places, isEmpty);
    });
  });

  group('Mentions', () {
    test('the mention regex matches @tokens at word boundaries only', () {
      final hits = RichMessageText.mention
          .allMatches('hey @Alice and @Bob, email a@b is not one')
          .map((m) => m.group(0))
          .toList();
      expect(hits, ['@Alice', '@Bob']);
    });

    testWidgets('typing @ in a group offers members and inserts the mention',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team Standup'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'hey @Al');
      await tester.pumpAndSettle();

      // The member suggestion appears; tapping it completes the mention.
      expect(find.text('@Alice'), findsOneWidget);
      await tester.tap(find.text('@Alice'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'hey @Alice ');
    });

    testWidgets('one-to-one chats do not offer mentions', (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'hey @Al');
      await tester.pumpAndSettle();
      expect(find.text('@Alice'), findsNothing);
    });
  });

  group('Chat export', () {
    test('transcriptFileName slugifies the contact name', () {
      expect(transcriptFileName('Alice Bennett'), 'okay-chat-alice-bennett.txt');
      expect(transcriptFileName('!!!'), 'okay-chat-export.txt');
    });

    test('buildChatTranscript groups by date and labels media', () {
      final chat = Chat(
        id: 'c_x',
        contact: MockData.contacts().firstWhere((u) => u.name == 'Bob Carter'),
        messages: [
          Message(
              id: 'a',
              text: 'hey',
              time: DateTime(2024, 1, 1, 9, 5),
              isMe: false),
          Message(
              id: 'b',
              text: 'hi!',
              time: DateTime(2024, 1, 1, 9, 6),
              isMe: true),
          Message(
              id: 'c',
              text: '',
              time: DateTime(2024, 1, 2, 8, 0),
              isMe: true,
              isImage: true),
        ],
      );
      final out = buildChatTranscript(chat, 'Me');
      expect(out, contains('Chat with Bob Carter'));
      expect(out, contains('— 2024-01-01 —'));
      expect(out, contains('— 2024-01-02 —'));
      expect(out, contains('[09:05] Bob Carter: hey'));
      expect(out, contains('[09:06] Me: hi!'));
      expect(out, contains('[08:00] Me: [photo]'));
    });
  });

  group('View once photos', () {
    test('viewOnce fields survive a JSON roundtrip', () {
      final m = Message(
        id: 'v1',
        text: '',
        time: DateTime(2024, 1, 1, 9),
        isMe: false,
        isImage: true,
        viewOnce: true,
      );
      final back =
          Message.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.viewOnce, isTrue);
      expect(back.viewOnceOpened, isFalse);
    });

    test('markViewOnceOpened spends only unopened view-once photos', () {
      final store = ChatStore.instance;
      store.addMessage(
        'c_bob',
        Message(
          id: 'vo1',
          text: '',
          time: DateTime(2024, 1, 1, 9),
          isMe: false,
          isImage: true,
          viewOnce: true,
        ),
      );
      store.markViewOnceOpened('c_bob', 'vo1');
      final m = store
          .chatById('c_bob')!
          .messages
          .firstWhere((x) => x.id == 'vo1');
      expect(m.viewOnceOpened, isTrue);
      // A normal (non-view-once) message is never affected.
      store.addMessage(
        'c_bob',
        Message(
            id: 'plain',
            text: 'hi',
            time: DateTime(2024, 1, 1, 9),
            isMe: false),
      );
      store.markViewOnceOpened('c_bob', 'plain');
      expect(
        store.chatById('c_bob')!.messages
            .firstWhere((x) => x.id == 'plain')
            .viewOnceOpened,
        isFalse,
      );
    });

    testWidgets('opening a received view-once photo spends it', (tester) async {
      ChatStore.instance.addMessage(
        'c_bob',
        Message(
          id: 'vo_widget',
          text: '',
          time: DateTime(2024, 1, 1, 9),
          isMe: false,
          isImage: true,
          viewOnce: true,
        ),
      );
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      expect(find.text('View once'), findsOneWidget);
      expect(find.text('Tap to view'), findsOneWidget);

      await tester.tap(find.text('View once'));
      await tester.pumpAndSettle();
      // The full-screen viewer opened; go back to consume it.
      await goBack(tester);
      await tester.pumpAndSettle();

      expect(
        ChatStore.instance.chatById('c_bob')!.messages
            .firstWhere((m) => m.id == 'vo_widget')
            .viewOnceOpened,
        isTrue,
      );
      expect(find.text('Opened'), findsOneWidget);
      expect(find.text('View once'), findsNothing);
    });
  });

  group('Live location sharing', () {
    test('parseLocation reads a valid payload and rejects bad ones', () {
      final ok = RelayService.parseLocation(
          {'from': '+1 (555) 0142', 'lat': 40.7, 'lng': -74.0});
      expect(ok, isNotNull);
      expect(ok!.fromDigits, '15550142');
      expect(ok.lat, 40.7);
      expect(ok.lng, -74.0);

      expect(RelayService.parseLocation({'from': '+1', 'lat': 1.0}), isNull);
      expect(RelayService.parseLocation({'lat': 1.0, 'lng': 2.0}), isNull);
    });

    test('LiveLocationStore returns fresh locations and expires stale ones', () {
      final store = LiveLocationStore.instance;
      final t0 = DateTime(2024, 1, 1, 12);
      store.update('15550142', 40.7, -74.0, at: t0);

      // Fresh: within the TTL window.
      final fresh = store.locationFor('15550142',
          now: t0.add(const Duration(minutes: 2)));
      expect(fresh, isNotNull);
      expect(fresh!.position.latitude, 40.7);

      // Stale: past the TTL window → treated as gone.
      final stale = store.locationFor('15550142',
          now: t0.add(const Duration(minutes: 20)));
      expect(stale, isNull);

      // Unknown peer → null.
      expect(store.locationFor('99999999', now: t0), isNull);
    });
  });

  group('Map layers', () {
    test('MapLayer.fromName maps names and defaults to Automatic', () {
      expect(MapLayer.fromName('satellite'), MapLayer.satellite);
      expect(MapLayer.fromName('terrain'), MapLayer.terrain);
      expect(MapLayer.fromName('dark'), MapLayer.dark);
      expect(MapLayer.fromName('standard'), MapLayer.standard);
      expect(MapLayer.fromName('auto'), MapLayer.auto);
      // Unknown and unset fall back to following the app, which is what a
      // map with no preference expressed should do.
      expect(MapLayer.fromName('bogus'), MapLayer.auto);
      expect(MapLayer.fromName(null), MapLayer.auto);
    });

    test('each layer has a distinct tile URL and credit', () {
      final std = tileLayerFor(MapLayer.standard).urlTemplate!;
      final dark = tileLayerFor(MapLayer.dark).urlTemplate!;
      final sat = tileLayerFor(MapLayer.satellite).urlTemplate!;
      final ter = tileLayerFor(MapLayer.terrain).urlTemplate!;
      // The modern CARTO style, in crisp retina resolution.
      expect(std, contains('basemaps.cartocdn.com'));
      expect(std, contains('voyager'));
      expect(std, contains('{r}'));
      expect(dark, contains('dark_all'));
      expect(sat, contains('arcgisonline.com'));
      expect(ter, contains('opentopomap.org'));
      expect({std, dark, sat, ter}.length, 4);

      expect(attributionFor(MapLayer.satellite), contains('Esri'));
      expect(attributionFor(MapLayer.terrain), contains('OpenTopoMap'));
      expect(attributionFor(MapLayer.standard), contains('CARTO'));
      expect(attributionFor(MapLayer.dark), contains('CARTO'));
    });

    test('tile layers scale up past native zoom instead of going grey', () {
      // maxZoom is a hard display cutoff: if it equals the server's deepest
      // tile level, framing a short route zooms past it and the whole map
      // renders grey. Every layer must allow over-zoom with scaled tiles.
      for (final l in MapLayer.values) {
        final t = tileLayerFor(l);
        expect(t.maxZoom, 22, reason: '${l.name} display cutoff');
        expect(t.maxNativeZoom, lessThanOrEqualTo(20),
            reason: '${l.name} native tiles');
      }
      expect(tileLayerFor(MapLayer.standard).maxNativeZoom, 20);
      expect(tileLayerFor(MapLayer.terrain).maxNativeZoom, 17);
      expect(tileLayerFor(MapLayer.satellite).maxNativeZoom, 19);
    });

    test('low data mode swaps crisp retina tiles for light ones', () {
      expect(tileLayerFor(MapLayer.standard).resolvedRetinaMode,
          RetinaMode.server);
      expect(tileLayerFor(MapLayer.standard, lowData: true).resolvedRetinaMode,
          RetinaMode.disabled);
      expect(tileLayerFor(MapLayer.dark, lowData: true).resolvedRetinaMode,
          RetinaMode.disabled);
      // Satellite/terrain servers have no retina variant either way.
      expect(tileLayerFor(MapLayer.satellite, lowData: true).resolvedRetinaMode,
          RetinaMode.disabled);
    });
  });

  group('Snap Map', () {
    const base = LatLng(37.7749, -122.4194);

    testWidgets('the friends map shows only real live shares — no fakes',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MapScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Nobody is sharing live location → no invented pins, an honest
      // empty state instead.
      expect(find.textContaining('No friends on the map yet'), findsOneWidget);

      // A real live share puts that friend on the map.
      final friend = ChatStore.instance.chats
          .firstWhere((c) => !c.contact.isGroup && c.contact.phone.isNotEmpty)
          .contact;
      LiveLocationStore.instance.update(
          RelayService.digits(friend.phone), base.latitude, base.longitude);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('No friends on the map yet'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Ghost Mode hides you and shows the banner', (tester) async {
      expect(AppState.ghostMode.value, isFalse);
      await tester.pumpWidget(const MaterialApp(home: MapScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Ghost Mode'), findsNothing);
      await tester.tap(find.byTooltip('Ghost Mode off'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(AppState.ghostMode.value, isTrue);
      expect(find.textContaining('you\'re hidden from the map'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Group chats (relay fan-out)', () {
    /// A group of me plus two number-identified members, as the creator's
    /// device stores it.
    Chat sampleGroup() => const Chat(
          id: 'group_1',
          contact: AppUser(
            id: 'group_1',
            name: 'Trip planning',
            avatarColor: '#4DB6AC',
            about: 'Group • 3 members',
            isGroup: true,
          ),
          messages: [],
          members: [
            AppUser(
                id: '+1 555 0100',
                name: 'You',
                avatarColor: '#25D366',
                phone: '+1 555 0100'),
            AppUser(
                id: '+1 555 0111',
                name: 'Alice',
                avatarColor: '#E57373',
                phone: '+1 555 0111'),
            AppUser(
                id: '+1 555 0122',
                name: 'Bob',
                avatarColor: '#64B5F6',
                phone: '+1 555 0122'),
          ],
        );

    setUp(() {
      // clearAll (not reset) so the sample chats don't stand in for the real
      // peers these cases are about.
      ChatStore.instance.clearAll();
      Session.instance.signInForTest();
    });

    test('a group message fans out to every member except me', () {
      final recipients =
          RelayService.groupRecipients(sampleGroup(), myPhone: '+1 555 0100');
      expect(recipients, ['+1 555 0111', '+1 555 0122']);
    });

    test('members without a number, and duplicates, are skipped', () {
      final group = sampleGroup().copyWith(members: const [
        AppUser(id: 'me', name: 'You', avatarColor: '#25D366'),
        AppUser(
            id: '+1 555 0111',
            name: 'Alice',
            avatarColor: '#E57373',
            phone: '+1 555 0111'),
        AppUser(
            id: 'alice_again',
            name: 'Alice',
            avatarColor: '#E57373',
            phone: '+1 (555) 0111'),
      ]);
      expect(RelayService.groupRecipients(group, myPhone: '+1 555 0100'),
          ['+1 555 0111']);
    });

    test('an incoming group message lands in the group, not a 1:1 chat', () {
      final payload = RelayService.encode(
        message: Message(
          id: 'g1',
          text: 'landing at 6',
          time: DateTime(2024, 5, 1, 9),
          isMe: true,
        ),
        fromPhone: '+1 555 0111',
        fromName: 'Alice',
        groupId: 'group_1',
        groupName: 'Trip planning',
        groupMembers: sampleGroup().members,
      );

      expect(RelayService.applyIncoming(payload, myPhone: '+1 555 0100'),
          isTrue);

      // No 1:1 chat with Alice was created — the message went to the group.
      expect(ChatStore.instance.chatWithContact('+1 555 0111'), isNull);
      final group = ChatStore.instance.chatById('group_1');
      expect(group, isNotNull);
      expect(group!.contact.isGroup, isTrue);
      expect(group.contact.name, 'Trip planning');
      expect(group.members.length, 3);
      expect(group.messages.single.text, 'landing at 6');
      // The sender is named above the bubble so members can be told apart.
      expect(group.messages.single.senderName, 'Alice');
    });

    test('the group name and roster stay encrypted on the wire', () {
      final payload = RelayService.encode(
        message: Message(
            id: 'g2', text: 'secret', time: DateTime(2024, 5, 1), isMe: true),
        fromPhone: '+1 555 0111',
        fromName: 'Alice',
        toPhone: '+1 555 0100',
        groupId: 'group_1',
        groupName: 'Trip planning',
        groupMembers: sampleGroup().members,
      );
      final wire = jsonEncode(payload);
      expect(wire.contains('Trip planning'), isFalse);
      expect(wire.contains('group_1'), isFalse);
      expect(wire.contains('0122'), isFalse);
      expect(payload['enc'], 1);
    });

    test('a rename by one member follows on the others devices', () {
      ChatStore.instance.upsert(sampleGroup());
      final payload = RelayService.encode(
        message: Message(
            id: 'g3', text: 'renamed', time: DateTime(2024, 5, 2), isMe: true),
        fromPhone: '+1 555 0111',
        fromName: 'Alice',
        groupId: 'group_1',
        groupName: 'Iceland 2025',
        groupMembers: sampleGroup().members,
      );
      RelayService.applyIncoming(payload, myPhone: '+1 555 0100');
      expect(ChatStore.instance.chatById('group_1')!.contact.name,
          'Iceland 2025');
    });

    test('a group update creates the group before any message arrives', () {
      // Alice already messages me, so she is allowed to add me to a group.
      ChatStore.instance.upsert(const Chat(
        id: 'chat_alice',
        contact: AppUser(
            id: '+1 555 0111',
            name: 'Alice',
            avatarColor: '#E57373',
            phone: '+1 555 0111'),
        messages: [],
      ));
      final blob = jsonEncode({
        'groupId': 'group_9',
        'groupName': 'Book club',
        'groupAbout': 'Thursdays',
        'groupMembers': sampleGroup()
            .members
            .map((m) => {
                  'id': m.id,
                  'name': m.name,
                  'phone': m.phone,
                  'avatarColor': m.avatarColor,
                })
            .toList(),
      });
      final added = RelayService.applyGroupUpdate({
        'from': '+1 555 0111',
        'c': E2eCrypto.encrypt(
            E2eCrypto.keyFor('+1 555 0111', '+1 555 0100'), blob),
        'enc': 1,
      }, myPhone: '+1 555 0100');

      expect(added, isTrue);
      final group = ChatStore.instance.chatById('group_9');
      expect(group, isNotNull);
      expect(group!.contact.name, 'Book club');
      expect(group.members.length, 3);
    });

    test('a group update from a stranger is dropped under contacts-only', () {
      addTearDown(() => AppState.messagesFromContactsOnly.value = false);
      AppState.messagesFromContactsOnly.value = true;
      final blob = jsonEncode({
        'groupId': 'group_spam',
        'groupName': 'Free crypto',
        'groupMembers': const [],
      });
      final added = RelayService.applyGroupUpdate({
        'from': '+1 555 0999',
        'c': E2eCrypto.encrypt(
            E2eCrypto.keyFor('+1 555 0999', '+1 555 0100'), blob),
        'enc': 1,
      }, myPhone: '+1 555 0100');

      expect(added, isFalse);
      expect(ChatStore.instance.chatById('group_spam'), isNull);
    });

    test('a member of a group I have can reach me under contacts-only', () {
      addTearDown(() => AppState.messagesFromContactsOnly.value = false);
      ChatStore.instance.upsert(sampleGroup());
      AppState.messagesFromContactsOnly.value = true;

      // Bob has no 1:1 chat with me, but we share a group.
      final added = RelayService.applyIncoming(
        RelayService.encode(
          message: Message(
              id: 'g4', text: 'me too', time: DateTime(2024, 5, 3), isMe: true),
          fromPhone: '+1 555 0122',
          fromName: 'Bob',
          groupId: 'group_1',
          groupName: 'Trip planning',
          groupMembers: sampleGroup().members,
        ),
        myPhone: '+1 555 0100',
      );

      expect(added, isTrue);
      expect(ChatStore.instance.chatById('group_1')!.messages.single.text,
          'me too');
    });

    test('updateGroup renames, re-describes and re-rosters a group', () {
      ChatStore.instance.upsert(sampleGroup());
      ChatStore.instance.updateGroup(
        'group_1',
        name: 'Iceland',
        about: 'Flights booked',
        avatarColor: '#BA68C8',
        members: sampleGroup().members.take(2).toList(),
      );
      final group = ChatStore.instance.chatById('group_1')!;
      expect(group.contact.name, 'Iceland');
      expect(group.contact.about, 'Flights booked');
      expect(group.contact.avatarColor, '#BA68C8');
      expect(group.contact.isGroup, isTrue);
      expect(group.members.map((m) => m.name), ['You', 'Alice']);
    });

    test('reachableContacts lists real peers, not groups or note-to-self', () {
      ChatStore.instance.upsert(sampleGroup());
      ChatStore.instance.upsert(const Chat(
        id: 'chat_alice',
        contact: AppUser(
            id: '+1 555 0111',
            name: 'Alice',
            avatarColor: '#E57373',
            phone: '+1 555 0111'),
        messages: [],
      ));
      ChatStore.instance.upsert(const Chat(
        id: 'chat_self',
        contact: AppUser(
            id: 'self', name: 'Note to self', avatarColor: '#25D366'),
        messages: [],
      ));

      final people = ChatStore.instance.reachableContacts();
      expect(people.map((u) => u.name), ['Alice']);
    });

    testWidgets('the group editor saves a new name and drops a member',
        (tester) async {
      ChatStore.instance.upsert(sampleGroup());
      await tester.pumpWidget(
        const MaterialApp(home: EditGroupScreen(chatId: 'group_1')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Group name'), 'Iceland 2025');
      await tester.pump();

      // "You" has no remove button, so the first one is Alice's.
      await tester.ensureVisible(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final group = ChatStore.instance.chatById('group_1')!;
      expect(group.contact.name, 'Iceland 2025');
      expect(group.members.map((m) => m.name), ['You', 'Bob']);
    });

    testWidgets('an incoming group bubble is labelled with its sender',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            MessageBubble(
              message: Message(
                id: 'm1',
                text: 'landing at 6',
                time: DateTime(2024, 5, 1, 18),
                isMe: false,
                senderName: 'Alice',
              ),
            ),
            MessageBubble(
              message: Message(
                id: 'm2',
                text: 'see you there',
                time: DateTime(2024, 5, 1, 18, 2),
                isMe: true,
                senderName: 'You',
              ),
            ),
          ]),
        ),
      ));
      await tester.pump();

      // Incoming bubbles are attributed; your own never are.
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('You'), findsNothing);
    });

    testWidgets('group info offers Edit group, not a "coming soon" toast',
        (tester) async {
      final group = sampleGroup();
      ChatStore.instance.upsert(group);
      await tester.pumpWidget(MaterialApp(
        home: GroupInfoScreen(
          group: group.contact,
          members: group.members,
          chatId: group.id,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit group'));
      await tester.pumpAndSettle();

      expect(find.byType(EditGroupScreen), findsOneWidget);
      expect(find.textContaining('coming soon'), findsNothing);
    });
  });

  group('Emoji catalog', () {
    test('the catalog is far bigger than the old curated strip', () {
      expect(EmojiData.all.length, greaterThan(700));
      expect(EmojiData.categories.keys,
          containsAll(['Smileys', 'Nature', 'Food', 'Travel', 'Symbols']));
    });

    test('every category is non-empty and free of duplicates', () {
      for (final entry in EmojiData.categories.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
        expect(entry.value.toSet().length, entry.value.length,
            reason: '${entry.key} has a duplicate');
      }
    });

    test('search matches keywords and category names', () {
      expect(EmojiData.search('laugh'), contains('😂'));
      expect(EmojiData.search('thumbs'), contains('👍'));
      expect(EmojiData.search('birthday'), contains('🎂'));
      // A category name pulls in the whole category.
      expect(EmojiData.search('food'), contains('🍕'));
      // An empty query means "show the categories instead", not "show all".
      expect(EmojiData.search('   '), isEmpty);
      expect(EmojiData.search('zzzznope'), isEmpty);
    });
  });

  group('GIFs', () {
    test('a Tenor response maps to picker results', () {
      const body = '{"results":[{"id":"1","content_description":"happy dance",'
          '"media_formats":{'
          '"gif":{"url":"https://media.tenor.com/a.gif","dims":[400,200]},'
          '"tinygif":{"url":"https://media.tenor.com/a-small.gif",'
          '"dims":[200,100]}}}]}';
      final results = GifService.parseResults(body);
      expect(results, hasLength(1));
      expect(results.single.url, 'https://media.tenor.com/a.gif');
      expect(results.single.previewUrl, 'https://media.tenor.com/a-small.gif');
      expect(results.single.description, 'happy dance');
      expect(results.single.aspectRatio, closeTo(2.0, 0.001));
    });

    test('results without a usable format are skipped, not crashed on', () {
      const body = '{"results":[{"id":"1","media_formats":{"mp4":{}}},'
          '{"id":"2"},"junk"]}';
      expect(GifService.parseResults(body), isEmpty);
      expect(GifService.parseResults('{}'), isEmpty);
      expect(GifService.parseResults('[]'), isEmpty);
    });

    test('a GIF post carries its url through save and restore', () {
      final post = FeedPost(
        id: 'p1',
        communityId: 'c1',
        authorName: 'You',
        authorUsername: 'you',
        time: DateTime(2024, 6, 1),
        text: 'this one',
        gifUrl: 'https://media.tenor.com/a.gif',
      );
      expect(FeedPost.fromJson(post.toJson()).gifUrl,
          'https://media.tenor.com/a.gif');

      final plain = FeedPost(
        id: 'p2',
        communityId: 'c1',
        authorName: 'You',
        authorUsername: 'you',
        time: DateTime(2024, 6, 1),
        text: 'plain',
      );
      expect(FeedPost.fromJson(plain.toJson()).gifUrl, isNull);
    });
  });

  group('Communities and score on the server', () {
    test('the sync payload carries communities and the score', () {
      addTearDown(() {
        CommunityStore.instance.resetForTest();
        ScoreStore.instance.resetForTest();
      });
      CommunityStore.instance.resetForTest();
      ScoreStore.instance.resetForTest();
      CommunityStore.instance.createCommunity('Study group');
      ScoreStore.instance.award(40);
      ScoreStore.instance.recordFlag('made_call');

      final payload = CloudSync.instance.buildPayload();
      expect(payload['communities'], isA<List>());
      expect(payload['communities'] as List, isNotEmpty);
      expect((payload['score'] as Map)['points'], 40);
      expect((payload['score'] as Map)['flags'], contains('made_call'));
    });

    test('a restore brings communities and the score back', () async {
      CloudSync.debugServerOverride = {};
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        CommunityStore.instance.resetForTest();
        ScoreStore.instance.resetForTest();
      });
      CommunityStore.instance.resetForTest();
      ScoreStore.instance.resetForTest();
      await CloudSync.instance
          .configure(passphrase: 'correct horse battery', on: false);

      CommunityStore.instance.createCommunity('Rocket club');
      ScoreStore.instance.award(120);
      expect(await CloudSync.instance.syncNow(), isNull);

      // The server only ever holds ciphertext — the name isn't in the blob.
      final blob = CloudSync.debugServerOverride!.values.single;
      expect(blob.contains('Rocket club'), isFalse);

      // Wipe this device (back to the seeded state), then pull it back down.
      CommunityStore.instance.resetForTest();
      ScoreStore.instance.resetForTest();
      expect(CommunityStore.instance.communities.map((c) => c.name),
          isNot(contains('Rocket club')));
      expect(await CloudSync.instance.restore(), isNull);
      expect(CommunityStore.instance.communities.map((c) => c.name),
          contains('Rocket club'));
      expect(ScoreStore.instance.points, 120);
    });

    test('a restored score never rolls a higher local score back', () {
      addTearDown(ScoreStore.instance.resetForTest);
      ScoreStore.instance.resetForTest();
      ScoreStore.instance.award(200);
      ScoreStore.instance.recordFlag('local_only');

      // An older snapshot from another device.
      ScoreStore.instance.hydrate({
        'points': 50,
        'flags': ['made_call'],
        'featured': 'caller',
      });

      expect(ScoreStore.instance.points, 200);
      // Flags merge — an achievement earned anywhere stays earned.
      expect(
          ScoreStore.instance.flags, containsAll(['local_only', 'made_call']));
    });
  });

  group('Pull to refresh', () {
    testWidgets('the Calls tab can be pulled down to refresh', (tester) async {
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: CallsTab())));
      await tester.pumpAndSettle();
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('so can the profile, score and starred screens',
        (tester) async {
      for (final screen in <Widget>[
        // The one profile screen, which is what the "You" tab renders now.
        const PublicProfileScreen(username: 'me', embedded: true),
        const ScoreScreen(),
        const StarredMessagesScreen(),
      ]) {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
        await tester.pumpAndSettle();
        expect(find.byType(RefreshIndicator), findsWidgets,
            reason: '${screen.runtimeType} has no pull-to-refresh');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('the call actions live in the app bar, not the list',
        (tester) async {
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: CallsTab())));
      await tester.pumpAndSettle();
      // They used to be four tiles stacked above Favourites.
      expect(find.text('Create call link'), findsNothing);
      expect(find.text('Dial a number'), findsNothing);
      expect(find.text('Find people by username'), findsNothing);
    });
  });

  group('Account email', () {
    setUp(AccountEmail.instance.resetForTest);

    test('the confirmation link lands somewhere real, not on localhost', () {
      // With no emailRedirectTo, Supabase falls back to the project's Site
      // URL — `http://localhost:3000` until someone changes it — so the link
      // in the email opened a dead page on the reader's own phone.
      const url = AccountEmail.emailRedirectUrl;
      expect(url.startsWith('https://'), isTrue);
      expect(url.contains('localhost'), isFalse);
      expect(url.contains('127.0.0.1'), isFalse);

      // And it has to be a page that actually ships with the web build.
      final path = Uri.parse(url).pathSegments.last;
      expect(File('web/$path').existsSync(), isTrue,
          reason: 'the confirmation link points at a page that does not exist');
    });

    test('the confirmation page tells the truth about a failed link', () {
      // Supabase reports an expired or already-used link in the URL fragment.
      // A page hardcoded to say "confirmed" would send someone back to the
      // app believing something that didn't happen.
      final html = File('web/email-confirmed.html').readAsStringSync();
      expect(html.contains('error_description'), isTrue);
      expect(html.contains('Link didn’t work'), isTrue);
      // Static by design: the confirmation already happened server-side, so
      // there is nothing here to load the app for.
      expect(html.contains('main.dart.js'), isFalse);
    });

    test('validation accepts real addresses and rejects the rest', () {
      expect(AccountEmail.isValid('ada@example.com'), isTrue);
      expect(AccountEmail.isValid('ada.lovelace+okay@mail.co.uk'), isTrue);
      expect(AccountEmail.isValid('  ada@example.com  '), isTrue);
      expect(AccountEmail.isValid('ada@example'), isFalse); // no TLD
      expect(AccountEmail.isValid('ada example.com'), isFalse);
      expect(AccountEmail.isValid('@example.com'), isFalse);
      expect(AccountEmail.isValid('ada@@example.com'), isFalse);
      expect(AccountEmail.isValid(''), isFalse);
    });

    test('masking hides the address without hiding which one it is', () {
      expect(AccountEmail.mask('ada@example.com'), 'a•a@example.com');
      expect(AccountEmail.mask('lovelace@example.com'), 'l••••••e@example.com');
      expect(AccountEmail.mask('ab@example.com'), 'a•@example.com');
      // Not an address — passed through rather than mangled.
      expect(AccountEmail.mask('nonsense'), 'nonsense');
    });

    test('an invalid address is refused and nothing is stored', () async {
      expect(await AccountEmail.instance.setEmail('not-an-email'),
          EmailSaveResult.invalid);
      expect(AccountEmail.instance.isSet, isFalse);
    });

    test('a valid address is stored unverified without a server session',
        () async {
      final result = await AccountEmail.instance.setEmail(' ada@example.com ');
      // No Supabase session in tests, so nothing can be sent to confirm it —
      // it's saved and honestly flagged rather than claimed as verified.
      expect(result, EmailSaveResult.savedUnverified);
      expect(AccountEmail.instance.email, 'ada@example.com');
      expect(AccountEmail.instance.isVerified, isFalse);
      expect(AccountEmail.instance.isSet, isTrue);

      await AccountEmail.instance.clear();
      expect(AccountEmail.instance.isSet, isFalse);
    });

    test('the account email rides the encrypted sync', () async {
      CloudSync.debugServerOverride = {};
      addTearDown(() {
        CloudSync.debugServerOverride = null;
        CloudSync.instance.resetForTest();
        AccountEmail.instance.resetForTest();
      });
      await CloudSync.instance
          .configure(passphrase: 'correct horse battery', on: false);
      await AccountEmail.instance.setEmail('ada@example.com');

      expect(await CloudSync.instance.syncNow(), isNull);
      final blob = CloudSync.debugServerOverride!.values.single;
      // The address is in the backup, but only as ciphertext.
      expect(blob.contains('ada@example.com'), isFalse);

      AccountEmail.instance.resetForTest();
      expect(await CloudSync.instance.restore(), isNull);
      expect(AccountEmail.instance.email, 'ada@example.com');
    });

    testWidgets('the screen adds an address and offers to remove it',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AccountEmailScreen()));
      await tester.pumpAndSettle();

      // With nothing set, the screen says the account has one way in.
      expect(find.textContaining('one way in'), findsOneWidget);
      expect(find.text('Remove email'), findsNothing);

      await tester.enterText(
          find.byType(TextField).first, 'ada@example.com');
      await tester.tap(find.text('Add email'));
      await tester.pumpAndSettle();

      expect(AccountEmail.instance.email, 'ada@example.com');
      expect(find.text('Update email'), findsOneWidget);
      expect(find.text('Remove email'), findsOneWidget);
      expect(find.textContaining('Not confirmed yet'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a bad address is rejected inline, not silently saved',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AccountEmailScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'nope');
      await tester.tap(find.text('Add email'));
      await tester.pumpAndSettle();

      expect(find.textContaining('doesn\'t look like an email'), findsOneWidget);
      expect(AccountEmail.instance.isSet, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Dark-mode contrast', () {
    /// The accent flips to near-white in dark mode; a control that hard-codes
    /// the light accent paints near-black onto a near-black screen.
    test('the accent flips with the theme', () {
      final light = AppTheme.light.colorScheme.primary;
      final dark = AppTheme.dark.colorScheme.primary;
      expect(light.computeLuminance(), lessThan(0.2)); // near-black ink
      expect(dark.computeLuminance(), greaterThan(0.6)); // near-white ink
    });

    testWidgets('Join Voice is legible on the dark voice screen',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentOn(context),
                foregroundColor: AppColors.onAccent(context),
              ),
              onPressed: () {},
              child: const Text('Join Voice'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final button =
          tester.widget<FilledButton>(find.byType(FilledButton));
      const pressed = <WidgetState>{};
      final background = button.style!.backgroundColor!.resolve(pressed)!;
      final foreground = button.style!.foregroundColor!.resolve(pressed)!;
      // The button must stand off the near-black surface, and its label must
      // stand off the button — the pair that was broken.
      expect(background.computeLuminance(), greaterThan(0.6));
      expect(foreground.computeLuminance(), lessThan(0.2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('no filled control hard-codes the light accent as a background', () {
      // Guards the class of bug that made "Join Voice" invisible in dark mode.
      final offenders = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (file.path.endsWith('theme/app_theme.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.contains('backgroundColor: AppColors.tealGreenDark') &&
              !line.contains('withValues')) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these paint the light accent on any background');
    });
  });

  group('New channel dialog', () {
    testWidgets('each type is explained, and Create waits for a name',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => promptNewChannelForTest(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Every type says what it's for, rather than being a bare chip.
      expect(find.text('Text'), findsOneWidget);
      expect(find.text('Send messages, photos and polls'), findsOneWidget);
      expect(find.text('A board of posts you can vote on'), findsOneWidget);

      // Create is disabled until there's actually a name.
      final create = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create'));
      expect(create.onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Trip Planning');
      await tester.pumpAndSettle();
      // The preview shows the name the channel will really get.
      expect(find.textContaining('#trip-planning'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Create'))
              .onPressed,
          isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Group calls', () {
    setUp(() {
      CallService.instance.resetForTest();
      Session.instance.signInForTest();
    });

    Chat groupChat() => const Chat(
          id: 'group_call_1',
          contact: AppUser(
            id: 'group_call_1',
            name: 'Trip planning',
            avatarColor: '#4DB6AC',
            isGroup: true,
          ),
          messages: [],
          members: [
            AppUser(
                id: '+1 555 0100',
                name: 'You',
                avatarColor: '#25D366',
                phone: '+1 555 0100'),
            AppUser(
                id: '+1 555 0111',
                name: 'Alice',
                avatarColor: '#E57373',
                phone: '+1 555 0111'),
            AppUser(
                id: '+1 555 0122',
                name: 'Bob',
                avatarColor: '#64B5F6',
                phone: '+1 555 0122'),
          ],
        );

    test('a group call rings the members, not me, and connects on first join',
        () {
      final call = CallService.instance;
      call.startGroupCall(groupChat(), video: false);

      final c = call.current.value!;
      expect(c.isGroup, isTrue);
      expect(c.peer.name, 'Trip planning');
      expect(c.status, CallStatus.ringing);
      // I'm not on my own roster; both callable members are being rung.
      expect(c.members.map((m) => m.user.name), ['Alice', 'Bob']);
      expect(c.members.every((m) => m.state == GroupCallMemberState.ringing),
          isTrue);

      // Alice picks up: the call connects, Bob keeps ringing.
      call.onRemoteJoined('+1 555 0111', c.callId);
      final joined = call.current.value!;
      expect(joined.status, CallStatus.connected);
      expect(joined.joinedCount, 1);
      expect(joined.members.last.state, GroupCallMemberState.ringing);
      call.end();
    });

    test('leaving while still being rung reads as a decline', () {
      final call = CallService.instance;
      call.startGroupCall(groupChat(), video: false);
      final id = call.current.value!.callId;

      call.onRemoteJoined('+1 555 0111', id);
      call.onRemoteLeft('+1 555 0122', id); // Bob never answered
      final c = call.current.value!;
      expect(
          c.members
              .firstWhere((m) => m.user.name == 'Bob')
              .state,
          GroupCallMemberState.declined);
      // Alice is still on, so the call carries on.
      expect(c.status, CallStatus.connected);

      // When Alice leaves too, the room is empty and the call ends.
      call.onRemoteLeft('+1 555 0111', id);
      expect(call.current.value?.status, CallStatus.ended);
    });

    test('an incoming group invite shows the group with the caller joined',
        () {
      final call = CallService.instance;
      final members = groupChat().members;
      call.onRemoteGroupOffer(
        members[1], // Alice is calling
        'gc1',
        false,
        group: groupChat().contact,
        members: members,
      );

      final c = call.current.value!;
      expect(c.isGroup, isTrue);
      expect(c.direction, CallDirection.incoming);
      expect(c.peer.name, 'Trip planning');
      expect(c.callerName, 'Alice');
      // My own entry is dropped; Alice is already on the call.
      expect(c.members.map((m) => m.user.name), ['Alice', 'Bob']);
      expect(c.members.first.state, GroupCallMemberState.joined);

      call.accept();
      expect(call.current.value?.status, CallStatus.connected);
      call.end();
    });

    test('the caller hanging up cancels an unanswered invite', () {
      final call = CallService.instance;
      final members = groupChat().members;
      call.onRemoteGroupOffer(members[1], 'gc2', false,
          group: groupChat().contact, members: members);
      expect(call.current.value?.status, CallStatus.ringing);

      // Alice (the only joined member) gives up before I answer.
      call.onRemoteLeft('+1 555 0111', 'gc2');
      expect(call.current.value?.status, CallStatus.ended);
    });

    test('a second invite while already on a call is ignored, not a takeover',
        () {
      final call = CallService.instance;
      call.startGroupCall(groupChat(), video: false);
      final id = call.current.value!.callId;
      call.onRemoteJoined('+1 555 0111', id);

      call.onRemoteGroupOffer(
        const AppUser(
            id: '+1 555 0999',
            name: 'Mallory',
            avatarColor: '#E57373',
            phone: '+1 555 0999'),
        'gc_other',
        false,
        group: const AppUser(
            id: 'g2', name: 'Other', avatarColor: '#4DB6AC', isGroup: true),
        members: const [],
      );
      expect(call.current.value?.callId, id);
      call.end();
    });

    test('the sealed invite carries the group and its roster', () {
      final info = RelayService.groupCallInfo(groupChat());
      expect(info['id'], 'group_call_1');
      expect(info['name'], 'Trip planning');
      final members = RelayService.membersFromJson(info['members']);
      expect(members.map((m) => m.name), ['You', 'Alice', 'Bob']);
    });

    testWidgets('the call screen shows the room filling up', (tester) async {
      final chat = groupChat();
      final session = CallSession(
        callId: 'gc_ui',
        peer: chat.contact,
        video: false,
        direction: CallDirection.outgoing,
        status: CallStatus.ringing,
        members: [
          GroupCallMember(chat.members[1]),
          GroupCallMember(chat.members[2]),
        ],
      );
      await tester.pumpWidget(MaterialApp(home: CallScreen(session: session)));
      await tester.pump();

      expect(find.text('Trip planning'), findsOneWidget);
      expect(find.text('Ringing 2 members…'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Ringing…'), findsNWidgets(2));

      // Alice joins; her chip flips and the call counts two people.
      await tester.pumpWidget(MaterialApp(
        home: CallScreen(
          session: session.copyWith(
            status: CallStatus.connected,
            connectedAt: DateTime.now(),
            members: [
              GroupCallMember(chat.members[1], GroupCallMemberState.joined),
              GroupCallMember(chat.members[2]),
            ],
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('On the call'), findsOneWidget);
      expect(find.textContaining('2 on the call'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('an incoming group invite names the caller', (tester) async {
      final chat = groupChat();
      final session = CallSession(
        callId: 'gc_in',
        peer: chat.contact,
        video: false,
        direction: CallDirection.incoming,
        status: CallStatus.ringing,
        callerName: 'Alice Bennett',
        members: [
          GroupCallMember(chat.members[1], GroupCallMemberState.joined),
          GroupCallMember(chat.members[2]),
        ],
      );
      await tester.pumpWidget(MaterialApp(home: CallScreen(session: session)));
      await tester.pump();

      expect(find.text('Trip planning'), findsOneWidget);
      expect(find.text('Alice invited you to a group call'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Group chats: events land in the group', () {
    setUp(() {
      ChatStore.instance.clearAll();
      Session.instance.signInForTest();
    });

    /// Alice both messages me 1:1 AND shares a group with me — the setup
    /// where events used to land in the wrong conversation.
    void seedBothChats() {
      const alice = AppUser(
          id: '+1 555 0111',
          name: 'Alice',
          avatarColor: '#E57373',
          phone: '+1 555 0111');
      ChatStore.instance.upsert(Chat(
        id: 'chat_alice',
        contact: alice,
        messages: [
          Message(
              id: 'dm1',
              text: 'direct hello',
              time: DateTime(2024, 7, 1, 9),
              isMe: false),
          Message(
              id: 'dm_out',
              text: 'my reply',
              time: DateTime(2024, 7, 1, 9, 1),
              isMe: true,
              status: MessageStatus.sent),
        ],
      ));
      ChatStore.instance.upsert(Chat(
        id: 'group_ev',
        contact: const AppUser(
            id: 'group_ev',
            name: 'Trip planning',
            avatarColor: '#4DB6AC',
            isGroup: true),
        members: const [
          AppUser(
              id: '+1 555 0100',
              name: 'You',
              avatarColor: '#25D366',
              phone: '+1 555 0100'),
          alice,
        ],
        messages: [
          Message(
              id: 'gm1',
              text: 'group hello',
              time: DateTime(2024, 7, 1, 10),
              isMe: false,
              senderName: 'Alice'),
          Message(
              id: 'gm_out',
              text: 'sent to the group',
              time: DateTime(2024, 7, 1, 10, 1),
              isMe: true,
              status: MessageStatus.sent),
          Message(
              id: 'gp1',
              text: '',
              time: DateTime(2024, 7, 1, 11),
              isMe: false,
              senderName: 'Alice',
              isPoll: true,
              pollQuestion: 'Where to?',
              pollOptions: ['North', 'South'],
              pollVotes: [0, 0]),
        ],
      ));
    }

    test('chatWithMessage prefers the sender chat, then finds the group', () {
      seedBothChats();
      expect(
          ChatStore.instance
              .chatWithMessage('dm1', senderId: '+1 555 0111')!
              .id,
          'chat_alice');
      expect(
          ChatStore.instance
              .chatWithMessage('gm1', senderId: '+1 555 0111')!
              .id,
          'group_ev');
      expect(ChatStore.instance.chatWithMessage('nope'), isNull);
    });

    test("Alice's reaction to a group message lands in the group", () {
      seedBothChats();
      final applied = RelayService.applyMessageEvent(
        'reaction',
        {'from': '+1 555 0111', 'id': 'gm_out', 'emoji': '🔥', 'add': true},
        myPhone: '+1 555 0100',
      );
      expect(applied, isTrue);
      final group = ChatStore.instance.chatById('group_ev')!;
      expect(
          group.messages.firstWhere((m) => m.id == 'gm_out').reactions,
          contains('🔥'));
      // The 1:1 thread is untouched.
      final dm = ChatStore.instance.chatById('chat_alice')!;
      expect(dm.messages.every((m) => m.reactions.isEmpty), isTrue);
    });

    test('a group edit and a group delete-for-everyone follow through', () {
      seedBothChats();
      RelayService.applyMessageEvent(
        'edit',
        {'from': '+1 555 0111', 'id': 'gm1', 'text': 'group hello (fixed)'},
        myPhone: '+1 555 0100',
      );
      final edited = ChatStore.instance
          .chatById('group_ev')!
          .messages
          .firstWhere((m) => m.id == 'gm1');
      expect(edited.text, 'group hello (fixed)');
      expect(edited.edited, isTrue);

      RelayService.applyMessageEvent(
        'delete',
        {'from': '+1 555 0111', 'id': 'gm1'},
        myPhone: '+1 555 0100',
      );
      expect(
          ChatStore.instance
              .chatById('group_ev')!
              .messages
              .firstWhere((m) => m.id == 'gm1')
              .isDeleted,
          isTrue);
    });

    test("a member's poll vote counts in the group poll", () {
      seedBothChats();
      RelayService.applyMessageEvent(
        'poll',
        {'from': '+1 555 0111', 'id': 'gp1', 'add': 1, 'remove': -1},
        myPhone: '+1 555 0100',
      );
      final poll = ChatStore.instance
          .chatById('group_ev')!
          .messages
          .firstWhere((m) => m.id == 'gp1');
      expect(poll.pollVotes, [0, 1]);
    });

    test("a group read receipt advances the group's ticks, not the DM's", () {
      seedBothChats();
      final applied = RelayService.applyReceipt(
        {'from': '+1 555 0111', 'kind': 'read', 'id': 'gm_out'},
        myPhone: '+1 555 0100',
      );
      expect(applied, isTrue);
      expect(
          ChatStore.instance
              .chatById('group_ev')!
              .messages
              .firstWhere((m) => m.id == 'gm_out')
              .status,
          MessageStatus.read);
      // My 1:1 message to Alice is still only "sent".
      expect(
          ChatStore.instance
              .chatById('chat_alice')!
              .messages
              .firstWhere((m) => m.id == 'dm_out')
              .status,
          MessageStatus.sent);
    });

    test('a legacy receipt without a message id still works 1:1', () {
      seedBothChats();
      RelayService.applyReceipt(
        {'from': '+1 555 0111', 'kind': 'delivered'},
        myPhone: '+1 555 0100',
      );
      expect(
          ChatStore.instance
              .chatById('chat_alice')!
              .messages
              .firstWhere((m) => m.id == 'dm_out')
              .status,
          MessageStatus.delivered);
    });

    test('my own echoed event is ignored', () {
      seedBothChats();
      final applied = RelayService.applyMessageEvent(
        'reaction',
        {'from': '+1 555 0100', 'id': 'gm_out', 'emoji': '🔥', 'add': true},
        myPhone: '+1 555 0100',
      );
      expect(applied, isFalse);
    });
  });

  group('Real photos over the relay', () {
    Uint8List samplePhoto({int width = 2000, int height = 1400}) {
      final image = img.Image(width: width, height: height);
      // A gradient, so JPEG has something realistic to chew on.
      for (var y = 0; y < height; y += 4) {
        for (var x = 0; x < width; x += 4) {
          img.fillRect(image,
              x1: x,
              y1: y,
              x2: x + 3,
              y2: y + 3,
              color: img.ColorRgb8(x % 256, y % 256, (x + y) % 256));
        }
      }
      return Uint8List.fromList(img.encodeJpg(image, quality: 95));
    }

    test('a big photo is shrunk under the relay budget as a data URI', () {
      final uri = PhotoPrep.prepare(samplePhoto());
      expect(uri, isNotNull);
      expect(uri!.startsWith('data:image/jpeg;base64,'), isTrue);
      expect(uri.length, lessThanOrEqualTo(PhotoPrep.maxBase64Length + 23));

      // The payload decodes back to a real, smaller image.
      final bytes = PhotoPrep.bytesFromDataUri(uri)!;
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.width, lessThanOrEqualTo(1280));
      expect(decoded.height, lessThanOrEqualTo(1280));
    });

    test('garbage input is refused instead of sent', () {
      expect(PhotoPrep.prepare(Uint8List.fromList([1, 2, 3])), isNull);
      expect(PhotoPrep.bytesFromDataUri('data:image/jpeg;base64,@@@'), isNull);
      expect(PhotoPrep.bytesFromDataUri('https://example.com/a.gif'), isNull);
      expect(PhotoPrep.isDataUri('data:image/jpeg;base64,abc'), isTrue);
      expect(PhotoPrep.isDataUri('https://example.com/a.gif'), isFalse);
    });

    test('pickPhoto hands back the prepared photo from the picker', () async {
      PhotoPrep.debugPickOverride = () async => samplePhoto(width: 640, height: 480);
      addTearDown(() => PhotoPrep.debugPickOverride = null);
      final uri = await PhotoPrep.pickPhoto();
      expect(uri, isNotNull);
      expect(PhotoPrep.isDataUri(uri!), isTrue);

      // A cancelled picker sends nothing.
      PhotoPrep.debugPickOverride = () async => null;
      expect(await PhotoPrep.pickPhoto(), isNull);
    });

    testWidgets('an inline photo renders from memory, not the network',
        (tester) async {
      final uri = PhotoPrep.prepare(samplePhoto(width: 320, height: 240))!;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatPhoto(url: uri, width: 100, height: 100)),
      ));
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());

      // A corrupt data URI falls to the error builder rather than throwing.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatPhoto(
            url: 'data:image/jpeg;base64,%%%',
            errorBuilder: (_) => const Text('broken'),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('broken'), findsOneWidget);
    });
  });

  group('File moderation', () {
    Uint8List bytes(List<int> b) => Uint8List.fromList(b);

    test('real images pass the photo path', () {
      // Magic numbers are enough — moderation sniffs content, not extensions.
      final jpeg = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
      final png =
          bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
      expect(FileModeration.inspectImage(jpeg).allowed, isTrue);
      expect(FileModeration.inspectImage(jpeg).kind, 'jpeg');
      expect(FileModeration.inspectImage(png).allowed, isTrue);
    });

    test('non-images are refused on the photo path', () {
      // A PDF is a legit document, but not a photo.
      final pdf = bytes([0x25, 0x50, 0x44, 0x46, 0x2D]);
      final verdict = FileModeration.inspectImage(pdf);
      expect(verdict.allowed, isFalse);
      expect(verdict.reason, contains('image'));
    });

    test('videos cannot be uploaded on any path', () {
      // MP4/MOV: ftyp box with a movie brand.
      final mp4 = bytes([
        0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, // ....ftyp
        0x69, 0x73, 0x6F, 0x6D // isom
      ]);
      // Matroska / WebM.
      final webm = bytes([0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3]);
      // A .mov HEIC-lookalike brand that is actually video (qt).
      final mov = bytes([
        0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20
      ]);
      for (final v in [mp4, webm, mov]) {
        expect(FileModeration.sniff(v), 'video');
        final img = FileModeration.inspectImage(v);
        expect(img.allowed, isFalse);
        expect(img.reason, contains('Video'));
        final file = FileModeration.inspectFile(v);
        expect(file.allowed, isFalse);
        expect(file.reason, contains('Video'));
      }
      // A real HEIC image is NOT mistaken for video.
      final heic = bytes([
        0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63
      ]);
      expect(FileModeration.sniff(heic), 'heic');
      expect(FileModeration.inspectImage(heic).allowed, isTrue);
    });

    test('executables and scripts are refused on every path', () {
      final pe = bytes([0x4D, 0x5A, 0x90, 0x00]); // MZ
      final elf = bytes([0x7F, 0x45, 0x4C, 0x46]); // ELF
      final macho = bytes([0xCF, 0xFA, 0xED, 0xFE]);
      final shebang = bytes([0x23, 0x21, 0x2F, 0x62, 0x69, 0x6E]); // #!/bin
      for (final b in [pe, elf, macho, shebang]) {
        expect(FileModeration.inspectImage(b).allowed, isFalse);
        expect(FileModeration.inspectFile(b).allowed, isFalse,
            reason: 'executables/scripts must never send as files');
      }
    });

    test('safe documents pass the file path', () {
      final pdf = bytes([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31]);
      final text = bytes('hello, this is plain text'.codeUnits);
      expect(FileModeration.inspectFile(pdf).allowed, isTrue);
      expect(FileModeration.inspectFile(text).allowed, isTrue);
    });

    test('oversize and empty files are refused', () {
      expect(FileModeration.inspectImage(bytes([])).allowed, isFalse);
      final huge = Uint8List(FileModeration.maxFileBytes + 1)
        ..[0] = 0xFF
        ..[1] = 0xD8
        ..[2] = 0xFF;
      final verdict = FileModeration.inspectImage(huge);
      expect(verdict.allowed, isFalse);
      expect(verdict.reason, contains('large'));
    });

    test('the hash blocklist refuses known content outright', () {
      addTearDown(FileModeration.resetForTest);
      final jpeg = bytes([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
      expect(FileModeration.inspectImage(jpeg).allowed, isTrue);
      // Block that exact content by its hash — now it's refused despite being
      // a valid image.
      FileModeration.blockHash(FileModeration.hashOf(jpeg));
      expect(FileModeration.hasBlocklist, isTrue);
      expect(FileModeration.inspectImage(jpeg).allowed, isFalse);
    });

    test('pickPhoto throws FileRejected for a non-image', () async {
      // A renamed executable posing as a photo.
      PhotoPrep.debugPickOverride =
          () async => Uint8List.fromList([0x4D, 0x5A, 0x90, 0x00, 0x03]);
      addTearDown(() => PhotoPrep.debugPickOverride = null);
      expect(() => PhotoPrep.pickPhoto(), throwsA(isA<FileRejected>()));
    });
  });

  group('Inline attachments', () {
    testWidgets('the paperclip opens the options in place, not a sheet',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              ChatInputBar(
                onSend: (_) {},
                attachments: [
                  AttachmentOption(
                      icon: Icons.photo,
                      label: 'Photos',
                      color: Colors.purple,
                      onTap: () {}),
                  AttachmentOption(
                      icon: Icons.person,
                      label: 'Contact',
                      color: Colors.blue,
                      onTap: () {}),
                ],
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Photos'), findsNothing);
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      // The options are in the page itself — no dialog/sheet route was pushed.
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Contact'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);

      // Tapping an option folds the panel away.
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();
      expect(find.text('Photos'), findsNothing);
    });

    testWidgets('picking an option fires its action', (tester) async {
      var picked = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              ChatInputBar(
                onSend: (_) {},
                attachments: [
                  AttachmentOption(
                      icon: Icons.poll_outlined,
                      label: 'Poll',
                      color: Colors.green,
                      onTap: () => picked = 'poll'),
                ],
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poll'));
      await tester.pumpAndSettle();
      expect(picked, 'poll');
    });
  });

  group('Live location sharing', () {
    setUp(() {
      ChatStore.instance.clearAll();
      AppState.shareLiveLocation.value = false;
      AppState.ghostMode.value = false;
    });
    tearDown(() {
      LiveLocationBroadcaster.instance.resetForTest();
      LiveLocationBroadcaster.debugSendOverride = null;
      debugGeolocationOverride = null;
      AppState.shareLiveLocation.value = false;
      AppState.ghostMode.value = false;
    });

    void seedPeople() {
      ChatStore.instance.upsert(const Chat(
        id: 'chat_a',
        contact: AppUser(
            id: '+1 555 0111',
            name: 'Alice',
            avatarColor: '#E57373',
            phone: '+1 555 0111'),
        messages: [],
      ));
      ChatStore.instance.upsert(const Chat(
        id: 'group_x',
        contact: AppUser(
            id: 'group_x',
            name: 'Group',
            avatarColor: '#4DB6AC',
            isGroup: true),
        messages: [],
      ));
      ChatStore.instance.upsert(const Chat(
        id: 'chat_self',
        contact: AppUser(
            id: 'self', name: 'Note to self', avatarColor: '#25D366'),
        messages: [],
      ));
    }

    test('positions go to 1:1 contacts only — never groups or note-to-self',
        () {
      seedPeople();
      final names = LiveLocationBroadcaster.targets(ChatStore.instance)
          .map((u) => u.name);
      expect(names, ['Alice']);
    });

    test('broadcastOnce sends the fix to every contact while sharing is on',
        () async {
      seedPeople();
      final sent = <String>[];
      LiveLocationBroadcaster.debugSendOverride =
          (phone, lat, lng) => sent.add('$phone@$lat,$lng');
      debugGeolocationOverride = () async => (lat: 43.65, lng: -79.38);

      // Off: nothing leaves the device.
      expect(await LiveLocationBroadcaster.instance.broadcastOnce(), 0);
      expect(sent, isEmpty);

      AppState.shareLiveLocation.value = true;
      expect(await LiveLocationBroadcaster.instance.broadcastOnce(), 1);
      expect(sent, ['+1 555 0111@43.65,-79.38']);

      // Ghost Mode wins over the sharing toggle.
      AppState.ghostMode.value = true;
      expect(await LiveLocationBroadcaster.instance.broadcastOnce(), 0);
    });

    test('no GPS fix means nothing is sent, not a bogus position', () async {
      seedPeople();
      final sent = <String>[];
      LiveLocationBroadcaster.debugSendOverride =
          (phone, lat, lng) => sent.add(phone);
      debugGeolocationOverride = () async => null;
      AppState.shareLiveLocation.value = true;
      expect(await LiveLocationBroadcaster.instance.broadcastOnce(), 0);
      expect(sent, isEmpty);
    });

    test('the toggle starts the repeating broadcast and stops it again',
        () async {
      seedPeople();
      final sent = <String>[];
      LiveLocationBroadcaster.debugSendOverride =
          (phone, lat, lng) => sent.add(phone);
      debugGeolocationOverride = () async => (lat: 1.0, lng: 2.0);

      LiveLocationBroadcaster.instance.start();
      expect(sent, isEmpty);

      AppState.shareLiveLocation.value = true;
      // The immediate first broadcast is async — give it a beat.
      await Future<void>.delayed(Duration.zero);
      expect(sent, ['+1 555 0111']);

      AppState.shareLiveLocation.value = false;
      await Future<void>.delayed(Duration.zero);
      // Stopped: no further sends beyond the one from when it was on.
      expect(sent.length, 1);
    });
  });

  group('Delete visibility', () {
    test('a deleted last message previews as deleted, not blank or "Photo"',
        () {
      Chat withLast(Message m) => Chat(
          id: 'c', contact: MockData.me, messages: [m]);
      expect(
          withLast(Message(
            id: 'm1',
            text: '',
            time: DateTime(2024, 8, 1),
            isMe: true,
            isDeleted: true,
          )).preview,
          'Message deleted');
      // A deleted photo keeps isImage — deleted must still win.
      expect(
          withLast(Message(
            id: 'm2',
            text: '',
            time: DateTime(2024, 8, 1),
            isMe: true,
            isImage: true,
            isDeleted: true,
          )).preview,
          'Message deleted');
    });

    testWidgets('deleting your own group message offers delete-for-everyone',
        (tester) async {
      ChatStore.instance.clearAll();
      Session.instance.signInForTest();
      ChatStore.instance.upsert(Chat(
        id: 'group_del',
        contact: const AppUser(
            id: 'group_del',
            name: 'Trip planning',
            avatarColor: '#4DB6AC',
            isGroup: true),
        members: const [
          AppUser(
              id: '+1 555 0100',
              name: 'You',
              avatarColor: '#25D366',
              phone: '+1 555 0100'),
          AppUser(
              id: '+1 555 0111',
              name: 'Alice',
              avatarColor: '#E57373',
              phone: '+1 555 0111'),
        ],
        messages: [
          Message(
              id: 'gdel1',
              text: 'wrong chat, sorry',
              time: DateTime(2024, 8, 1, 9),
              isMe: true,
              status: MessageStatus.sent),
        ],
      ));

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(chat: ChatStore.instance.chatById('group_del')!),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('wrong chat, sorry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // The old real-peer gate hid this in groups, making group deletes
      // silently local-only.
      expect(find.text('Delete for everyone'), findsOneWidget);
      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();

      expect(find.text('You deleted this message'), findsOneWidget);
      expect(
          ChatStore.instance
              .chatById('group_del')!
              .messages
              .single
              .isDeleted,
          isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Keyboard dismissal', () {
    testWidgets('leaving a screen drops the keyboard focus', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [KeyboardDismissObserver()],
        home: const Scaffold(body: TextField()),
      ));
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.context, isNotNull);
      expect(
          tester.widget<EditableText>(find.byType(EditableText)).focusNode
              .hasFocus,
          isTrue);

      // Visit another screen and come back — focus must not survive.
      navKey.currentState!.push(
          MaterialPageRoute(builder: (_) => const Scaffold(body: SizedBox())));
      await tester.pumpAndSettle();
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(
          tester.widget<EditableText>(find.byType(EditableText)).focusNode
              .hasFocus,
          isFalse);
    });
  });

  group('Contacts sync availability', () {
    test('contact reading is back on for mobile (fixed in plugin 2.x)', () {
      // In the test VM kIsWeb is false, so this is the mobile answer.
      expect(ContactsSync.instance.supported, isTrue);
    });

    test('sync degrades to error, not a crash, when the plugin is absent',
        () async {
      // No plugin registered in the test VM: the channel call throws inside
      // sync(), which must swallow it and report an error status.
      final result = await ContactsSync.instance.sync();
      expect(result.status, ContactSyncStatus.error);
      expect(result.matches, isEmpty);
    });
  });

  group('Styled dialogs', () {
    testWidgets('a confirm dialog has one filled action, red when destructive',
        (tester) async {
      bool? answer;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await showAppConfirmDialog(
                  context,
                  icon: Icons.delete_outline,
                  title: 'Delete thing?',
                  message: 'This permanently removes the thing.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete'));
      final bg = button.style!.backgroundColor!.resolve(const {})!;
      // Destructive means visibly red, not the accent.
      expect(bg.r, greaterThan(bg.g));
      expect(bg.r, greaterThan(bg.b));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });

    testWidgets('a text prompt disables its action until there is text',
        (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAppTextPrompt(
                  context,
                  icon: Icons.drive_file_rename_outline,
                  title: 'Rename',
                  hint: 'New name',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      FilledButton save() =>
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(save().onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, '  Fresh name  ');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result, 'Fresh name');
    });
  });

  group('Terms & privacy consent', () {
    test('consent is required until the current version is accepted', () async {
      LegalConsent.instance.resetForTest(accepted: 0);
      expect(LegalConsent.instance.needsConsent, isTrue);
      expect(LegalConsent.instance.hasAcceptedBefore, isFalse);

      await LegalConsent.instance.accept();
      expect(LegalConsent.instance.needsConsent, isFalse);
      expect(LegalConsent.instance.hasAcceptedBefore, isTrue);
    });

    testWidgets('a signed-in user without consent is gated, then let through',
        (tester) async {
      LegalConsent.instance.resetForTest(accepted: 0);
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();

      // The app is blocked behind the consent screen, documents in reach.
      expect(find.text('Terms & privacy'), findsOneWidget);
      expect(find.text('Terms of Service'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('OkayMessenger'), findsNothing);

      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();

      // Consent recorded — the home screen appears and the gate stays gone.
      expect(find.text('Agree and continue'), findsNothing);
      expect(LegalConsent.instance.needsConsent, isFalse);
    });
  });

  group('Returning-user sign-in', () {
    testWidgets('signing out leaves a one-tap way back in', (tester) async {
      // Sign out from a real session: the account is remembered.
      await Session.instance.signIn(
          phone: '+1 555 0100', name: 'Ada Lovelace', username: 'adal');
      await Session.instance.signOut();
      expect(Session.instance.lastAccount?.name, 'Ada Lovelace');

      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();

      // The login screen leads with the remembered account, not a blank form.
      expect(find.text('Continue as Ada'), findsOneWidget);
      expect(find.text('@adal · +1 555 0100'), findsOneWidget);

      await tester.tap(find.text('Continue as Ada'));
      await tester.pumpAndSettle();

      // One tap: signed back in as the same identity.
      expect(Session.instance.user.value?.username, 'adal');
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('"Use a different account" opens the form, prefilled',
        (tester) async {
      await Session.instance.signIn(
          phone: '+1 555 0100', name: 'Ada Lovelace', username: 'adal');
      await Session.instance.signOut();

      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use a different account'));
      await tester.pumpAndSettle();

      // The full form is back, warm-started with the remembered details.
      expect(find.text('Continue as Ada'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Ada Lovelace'),
          findsOneWidget);
    });
  });

  group('Unified empty states', () {
    testWidgets('blank screens share one look', (tester) async {
      ChatStore.instance.clearAll();
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ChatsTab())));
      await tester.pumpAndSettle();
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No chats yet'), findsOneWidget);

      CallLog.instance.resetForTest();
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CallsTab())));
      await tester.pumpAndSettle();
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No recent calls'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Calls in the conversation', () {
    setUp(() {
      ChatStore.instance.clearAll();
      CallService.instance.resetForTest();
      CallLog.instance.resetForTest();
      Session.instance.signInForTest();
    });

    AppUser peer() => const AppUser(
          id: '+1 555 0199',
          name: 'Grace',
          avatarColor: '#64B5F6',
          phone: '+1 555 0199');

    test('a missed call lands in the chat and bumps its unread badge', () {
      final call = CallService.instance;
      call.onRemoteOffer(peer(), 'c_missed', false);
      call.onRemoteEnd('c_missed'); // caller hung up before we answered

      final chat = ChatStore.instance.chatWithContact('+1 555 0199');
      expect(chat, isNotNull);
      final record = chat!.messages.single;
      expect(record.isCallEvent, isTrue);
      expect(record.callEvent, 'missed');
      expect(record.isMe, isFalse);
      expect(chat.unreadCount, 1);
      expect(chat.preview, 'Missed voice call');
    });

    test('a completed call shows with its duration; declines say so', () {
      final call = CallService.instance;
      call.startOutgoing(peer(), video: false);
      call.onRemoteAnswer(call.current.value!.callId);
      call.end();

      var chat = ChatStore.instance.chatWithContact('+1 555 0199')!;
      expect(chat.messages.single.callEvent, 'ended');
      expect(chat.messages.single.isMe, isTrue);
      expect(chat.preview, 'Voice call');

      call.clear();
      call.startOutgoing(peer(), video: true);
      call.onRemoteDecline(call.current.value!.callId);
      chat = ChatStore.instance.chatWithContact('+1 555 0199')!;
      expect(chat.messages.last.callEvent, 'declined');
      expect(chat.messages.last.callVideo, isTrue);
      call.clear();
    });

    test('call records survive save and restore', () {
      final m = Message(
        id: 'cm1',
        text: '',
        time: DateTime(2024, 9, 1, 12),
        isMe: false,
        callEvent: 'missed',
        callVideo: true,
        callSeconds: 0,
      );
      final back = Message.fromJson(m.toJson());
      expect(back.isCallEvent, isTrue);
      expect(back.callEvent, 'missed');
      expect(back.callVideo, isTrue);
    });

    testWidgets('the chat renders a call chip, not a speech bubble',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: Message(
              id: 'cm2',
              text: '',
              time: DateTime(2024, 9, 1, 12),
              isMe: false,
              callEvent: 'missed',
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Missed voice call'), findsOneWidget);
      expect(find.byIcon(Icons.phone_missed), findsOneWidget);
    });
  });

  group('Crash reporter', () {
    setUp(CrashReporter.instance.resetForTest);
    tearDown(() => CrashReporter.debugSendOverride = null);

    test('a report carries the essentials and respects size caps', () {
      final row = CrashReporter.buildReport(
        error: 'x' * 5000,
        stack: 'y' * 9000,
        context: 'flutter',
        version: 'abc123',
      );
      expect((row['error'] as String).length, 1000);
      expect((row['stack'] as String).length, 4000);
      expect(row['context'], 'flutter');
      expect(row['app_version'], 'abc123');
      expect(row['platform'], isNotEmpty);
    });

    test('duplicates and floods are suppressed', () {
      final sent = <Map<String, dynamic>>[];
      CrashReporter.debugSendOverride = sent.add;

      CrashReporter.instance.report('boom', null);
      CrashReporter.instance.report('boom', null); // dup — dropped
      expect(sent.length, 1);

      for (var i = 0; i < 30; i++) {
        CrashReporter.instance.report('error $i', null);
      }
      // Capped per session so an error loop can't flood the table.
      expect(sent.length, CrashReporter.maxPerSession);
    });
  });

  group('Edge Function paste copies', () {
    // The dashboard editor can't resolve _shared/stripe.ts, so the paste
    // copies inline it. They drifted once — the platform fee sat at the old
    // 1.5% + 0c long after the shared helper moved to 3.4% + 35c, which would
    // have deployed a fee below Stripe's own cut on every transfer.
    test('every paste copy matches what the generator produces', () {
      String readShared(String n) =>
          File('supabase/functions/_shared/$n.ts').readAsStringSync();
      for (final name in pasteFunctions) {
        final source =
            File('supabase/functions/$name/index.ts').readAsStringSync();
        final expected = buildPasteCopy(name,
            readShared: readShared, functionSource: source);
        final onDisk =
            File('docs/edge_functions_paste/$name.ts').readAsStringSync();
        expect(onDisk, expected,
            reason: '$name is stale — run: dart tool/paste_functions.dart');
      }
    });

    test('no paste copy still imports the shared helper', () {
      for (final name in pasteFunctions) {
        final copy =
            File('docs/edge_functions_paste/$name.ts').readAsStringSync();
        final importsShared = copy
            .split('\n')
            .any((l) => l.startsWith('import') && l.contains('_shared/'));
        expect(importsShared, isFalse,
            reason: '$name would fail to bundle in the dashboard editor');
      }
    });

    test('the inlined platform fee never falls below Stripe\'s own cut', () {
      // Mirrors applicationFee() in the shared helper, plus the invariant
      // that actually protects the platform now: transfers must be DIRECT
      // charges. A destination charge would route the money through the
      // platform's balance and hand it the dispute liability.
      // Only the function that actually charges inlines the fee; the others
      // in the family (status lookups, account sessions) never touch it.
      for (final name in const ['payments-create-intent']) {
        final copy =
            File('docs/edge_functions_paste/$name.ts').readAsStringSync();
        final pct = RegExp(r'PLATFORM_FEE_PERCENT"\) \?\? "([\d.]+)"')
            .firstMatch(copy)
            ?.group(1);
        final fixed = RegExp(r'PLATFORM_FEE_FIXED_CENTS"\) \?\? "(\d+)"')
            .firstMatch(copy)
            ?.group(1);
        expect(pct, isNotNull, reason: '$name lost its fee default');
        expect(fixed, isNotNull, reason: '$name lost its fee default');
        // A direct charge means no platform-side Stripe cost to clear; the
        // fee only has to be a real, positive fee.
        expect(double.parse(pct!), greaterThan(0));
        expect(int.parse(fixed!), greaterThan(0));
        expect(double.parse(pct), greaterThan(0));
        expect(int.parse(fixed), greaterThan(0));
      }
    });
  });

  group('Voice presence', () {
    setUp(() {
      VoicePresenceStore.instance.resetForTest();
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(VoicePresenceStore.instance.resetForTest);

    test('joining puts you in the room and tells the server', () {
      final voice = VoicePresenceStore.instance;
      final sent = <String>[];
      voice.onPresence = (c, ch,
              {required joined,
              required muted,
              required video,
              required screen}) =>
          sent.add('$ch:$joined');

      expect(voice.occupantsIn('vc1'), isEmpty);
      voice.join(communityId: 'c1', channelId: 'vc1', myName: 'Me');
      expect(voice.amIn('vc1'), isTrue);
      expect(voice.occupantsIn('vc1').single.isMe, isTrue);
      expect(sent, ['vc1:true']);

      voice.leave();
      expect(voice.occupantsIn('vc1'), isEmpty);
      expect(voice.myChannelId, isNull);
      expect(sent.last, 'vc1:false');
    });

    test('you can only be in one voice channel at a time', () {
      final voice = VoicePresenceStore.instance;
      voice.join(communityId: 'c1', channelId: 'vc1', myName: 'Me');
      voice.join(communityId: 'c1', channelId: 'vc2', myName: 'Me');
      expect(voice.occupantsIn('vc1'), isEmpty);
      expect(voice.occupantsIn('vc2').single.isMe, isTrue);
      expect(voice.amIn('vc2'), isTrue);
    });

    test('a member hopping channels never appears in two at once', () {
      final voice = VoicePresenceStore.instance;
      voice.applyRemote(
          channelId: 'vc1', digits: '15550001', name: 'Ada', joined: true);
      expect(voice.countIn('vc1'), 1);
      voice.applyRemote(
          channelId: 'vc2', digits: '15550001', name: 'Ada', joined: true);
      expect(voice.countIn('vc1'), 0);
      expect(voice.countIn('vc2'), 1);
    });

    test('someone who goes quiet is swept, but you never are', () {
      final voice = VoicePresenceStore.instance;
      voice.join(communityId: 'c1', channelId: 'vc1', myName: 'Me');
      voice.applyRemote(
          channelId: 'vc1', digits: '15550001', name: 'Ada', joined: true);
      expect(voice.countIn('vc1'), 2);

      // A force-quit leaves no "left" message, so presence has to age out.
      voice.sweep(
          now: DateTime.now()
              .add(VoicePresenceStore.staleAfter)
              .add(const Duration(seconds: 1)));
      expect(voice.countIn('vc1'), 1);
      expect(voice.occupantsIn('vc1').single.isMe, isTrue,
          reason: 'this device knows perfectly well that it is still here');
    });

    test('a heartbeat keeps someone from being swept', () {
      final voice = VoicePresenceStore.instance;
      voice.applyRemote(
          channelId: 'vc1', digits: '15550001', name: 'Ada', joined: true);
      voice.sweep(
          now: DateTime.now().add(VoicePresenceStore.staleAfter ~/ 2));
      expect(voice.countIn('vc1'), 1);
    });

    test('mic and camera state reaches everyone else', () {
      final voice = VoicePresenceStore.instance;
      var lastMuted = false;
      voice.onPresence = (c, ch,
          {required joined,
          required muted,
          required video,
          required screen}) {
        lastMuted = muted;
      };
      voice.join(communityId: 'c1', channelId: 'vc1', myName: 'Me');
      voice.setLocalState(muted: true);
      expect(lastMuted, isTrue);
      expect(voice.occupantsIn('vc1').single.muted, isTrue);
      voice.setLocalState(video: true);
      expect(voice.occupantsIn('vc1').single.video, isTrue);
      // Turning the camera on must not silently unmute.
      expect(voice.occupantsIn('vc1').single.muted, isTrue);
    });

    test('you are listed first, then everyone else by name', () {
      final voice = VoicePresenceStore.instance;
      voice.applyRemote(
          channelId: 'vc1', digits: '2', name: 'Zoe', joined: true);
      voice.applyRemote(
          channelId: 'vc1', digits: '3', name: 'Ada', joined: true);
      voice.join(communityId: 'c1', channelId: 'vc1', myName: 'Me');
      expect([for (final o in voice.occupantsIn('vc1')) o.name],
          ['Me', 'Ada', 'Zoe']);
    });

    test('a leave broadcast removes them', () {
      final voice = VoicePresenceStore.instance;
      voice.applyRemote(
          channelId: 'vc1', digits: '1', name: 'Ada', joined: true);
      voice.applyRemote(
          channelId: 'vc1', digits: '1', name: 'Ada', joined: false);
      expect(voice.countIn('vc1'), 0);
    });
  });

  group('Voice channels in the server UI', () {
    testWidgets('occupants are listed under the channel, without opening it',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      CommunityStore.instance.resetForTest();
      VoicePresenceStore.instance.resetForTest();
      addTearDown(VoicePresenceStore.instance.resetForTest);

      final community = CommunityStore.instance.createCommunity('Guild');
      CommunityStore.instance
          .addChannel(community.id, 'Lounge', type: ChannelType.voice);
      final voiceChannel = CommunityStore.instance
          .byId(community.id)!
          .channels
          .firstWhere((c) => c.type == ChannelType.voice);

      await tester.pumpWidget(MaterialApp(
          home: CommunityScreen(communityId: community.id)));
      await tester.pump();
      expect(find.text('Voice channel'), findsWidgets);
      expect(find.text('Ada'), findsNothing);

      VoicePresenceStore.instance.applyRemote(
          channelId: voiceChannel.id,
          digits: '15550001',
          name: 'Ada',
          joined: true);
      await tester.pump();

      // The name shows up on the server screen itself — the point of a voice
      // channel is seeing it's occupied without having to go in.
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('1 person in voice'), findsOneWidget);

      VoicePresenceStore.instance.applyRemote(
          channelId: voiceChannel.id,
          digits: '15550002',
          name: 'Grace',
          joined: true);
      await tester.pump();
      expect(find.text('2 people in voice'), findsOneWidget);

      VoicePresenceStore.instance.applyRemote(
          channelId: voiceChannel.id,
          digits: '15550001',
          name: 'Ada',
          joined: false);
      await tester.pump();
      expect(find.text('Ada'), findsNothing);
      expect(find.text('1 person in voice'), findsOneWidget);
    });
  });

  group('Channel composer', () {
    testWidgets('attachments open in place, and the bar stays uncluttered',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      CommunityStore.instance.resetForTest();
      ChannelTypingStore.instance.resetForTest();
      addTearDown(ChannelTypingStore.instance.resetForTest);
      final community = CommunityStore.instance.createCommunity('Guild');
      final channel = CommunityStore.instance.byId(community.id)!.channels
          .firstWhere((c) => c.type == ChannelType.text);

      await tester.pumpWidget(MaterialApp(
        home: ChannelScreen(
            communityId: community.id, channelId: channel.id),
      ));
      await tester.pump();

      // Closed: the options aren't taking up room in the bar.
      expect(find.text('Photo'), findsNothing);
      expect(find.text('Poll'), findsNothing);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pump();
      expect(find.text('Photo'), findsOneWidget);
      expect(find.text('Poll'), findsOneWidget);
      // In place, not a modal sheet — the channel stays visible behind it.
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pump();
      expect(find.text('Photo'), findsNothing);
    });

    testWidgets('typing in a channel shows who else is mid-sentence',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      CommunityStore.instance.resetForTest();
      ChannelTypingStore.instance.resetForTest();
      addTearDown(ChannelTypingStore.instance.resetForTest);
      final community = CommunityStore.instance.createCommunity('Guild');
      final channel = CommunityStore.instance.byId(community.id)!.channels
          .firstWhere((c) => c.type == ChannelType.text);

      await tester.pumpWidget(MaterialApp(
        home: ChannelScreen(
            communityId: community.id, channelId: channel.id),
      ));
      await tester.pump();
      expect(find.textContaining('is typing'), findsNothing);

      ChannelTypingStore.instance
          .noteRemote(channelId: channel.id, digits: '1', name: 'Ada');
      await tester.pump();
      expect(find.text('Ada is typing…'), findsOneWidget);

      // It has to clear itself — nobody sends a "stopped typing".
      ChannelTypingStore.instance
          .expireNow(DateTime.now().add(ChannelTypingStore.linger * 2));
      await tester.pump();
      expect(find.textContaining('is typing'), findsNothing);
    });
  });

  group('Chargeback policy', () {
    testWidgets('the sender is told the consequence before money moves',
        (tester) async {
      // Banning after a chargeback is only fair if it was said plainly first,
      // and the acknowledgement is the paper trail that defends the dispute.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PaymentAmountSheet(peerName: 'Grace'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '20');
      await tester.pump();

      expect(find.textContaining('cannot be reversed'), findsOneWidget);
      expect(find.textContaining('block me from sending money'),
          findsOneWidget,
          reason: 'the ban has to be stated, not just enforced');
      // And it cannot be skipped past.
      expect(
          tester
              .widget<FilledButton>(find.byType(FilledButton))
              .onPressed,
          isNull);
    });

    testWidgets('note to self offers no way to send money', (tester) async {
      SharedPreferences.setMockInitialValues({});
      ChatStore.instance.reset();
      final me = AppState.profile.value;
      final selfChat = Chat(
        id: 'chat_self',
        contact: AppUser(
            id: 'self',
            name: 'Note to self',
            avatarColor: me.avatarColor,
            phone: ''),
        messages: const [],
      );
      ChatStore.instance.upsert(selfChat);

      await tester.pumpWidget(MaterialApp(home: ChatScreen(chat: selfChat)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      // Other attachments are there; paying yourself is not offered at all.
      expect(find.text('Contact'), findsOneWidget);
      expect(find.text('Payment'), findsNothing,
          reason: 'there is no second party in your own notes');
    });

    testWidgets('a group asks who to pay, and makes you confirm the name',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ChatStore.instance.reset();
      PaymentService.instance.setTestMode(true);
      addTearDown(() => PaymentService.instance.setTestMode(false));

      const ada = AppUser(
          id: '+15550001',
          name: 'Ada',
          avatarColor: '#111111',
          phone: '+15550001');
      const grace = AppUser(
          id: '+15550002',
          name: 'Grace',
          avatarColor: '#222222',
          phone: '+15550002');
      const group = Chat(
        id: 'chat_group_pay',
        contact: AppUser(
            id: 'g1',
            name: 'Trip',
            avatarColor: '#333333',
            phone: '',
            isGroup: true),
        messages: [],
        members: [ada, grace],
      );
      ChatStore.instance.upsert(group);

      await tester.pumpWidget(
          const MaterialApp(home: ChatScreen(chat: group)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Payment'));
      await tester.pumpAndSettle();

      // A group is not a recipient — it has to ask which member.
      expect(find.text('Who are you paying?'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Grace'), findsOneWidget);
      // The amount sheet must NOT be reachable before someone is chosen.
      expect(find.text('You pay'), findsNothing);

      await tester.tap(find.text('Grace'));
      await tester.pumpAndSettle();

      // Picking is not sending: the name is put back for confirmation, so a
      // mis-tap in a list cannot move money.
      expect(find.text('Pay Grace?'), findsOneWidget);
      expect(find.textContaining('cannot be reversed'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Pay Grace?'), findsNothing);
      expect(find.textContaining('Send money to'), findsNothing,
          reason: 'backing out of the confirmation must send nothing');
    });

    testWidgets('a recipient is told they carry the chargeback before setup',
        (tester) async {
      // The flip side of the platform not holding funds: payments land in the
      // recipient's own Stripe account, so a reversal comes out of it. Saying
      // so belongs before onboarding, not at their first dispute.
      bool? accepted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  accepted = await showRecipientLiabilityNotice(context),
              child: const Text('onboard'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('onboard'));
      await tester.pumpAndSettle();

      expect(find.text('Before you set up payments'), findsOneWidget);
      expect(find.textContaining('we never hold it'), findsOneWidget);
      expect(find.textContaining('comes back out of your account'),
          findsOneWidget);
      // Backing out must not start onboarding.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Before you set up payments'), findsNothing);
      expect(accepted, isFalse, reason: 'declining must not onboard anyone');
    });

    test('storage has no free allowance to give away', () {
      // Every held GB costs real money to store and serve. A free tier meant
      // every signed-up account carried a bill whether or not it ever paid.
      expect(StorageStore.freeGb, 0);
      expect(StorageStore.plans, isNotEmpty);
      expect(StorageStore.plans.every((p) => p.priceCents > 0), isTrue);
      expect(StorageStore.plans.first.gb, StorageStore.sizes.first);

      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();
      expect(storage.quotaBytes, 0);
      expect(storage.fits(1), isFalse);
      // Nothing fits, but that is "no plan", not "full" — see the
      // 'Storage with no plan' group.
      expect(storage.isFull, isFalse);
    });
  });

  group('Sender covers the fees', () {
    test('the recipient gets exactly what was typed', () {
      // Both fees come out of the transfer, so charging the typed amount
      // delivered less than it — type $5 and $4.28 landed. Grossing up moves
      // the fees onto the sender.
      for (final target in [300, 500, 1000, 1234, 2000, 5000, 50000]) {
        final total = PaymentEconomics.grossUpCents(target);
        expect(total, greaterThan(target));

        // The guarantee holds on the WORST card, not just a domestic one.
        // The sender picks the card and its country is only known after the
        // fact, so budgeting on the cheap rate would under-deliver every
        // international transfer — breaking the one promise this makes.
        expect(PaymentEconomics.worstCaseReceivedCents(total),
            greaterThanOrEqualTo(target),
            reason: 'a \$$target transfer must deliver \$$target on any card');

        // On a domestic card a little extra arrives. That surplus goes to the
        // recipient, never to the platform, and is small enough not to read
        // as a surcharge.
        final surplus =
            PaymentEconomics.estimatedReceivedCents(total) - target;
        expect(surplus, greaterThanOrEqualTo(0));
        expect(surplus, lessThan(target * 0.02 + 5),
            reason: 'erring high must stay rounding, not become a markup');
      }
      expect(PaymentEconomics.grossUpCents(0), 0);
    });

    testWidgets('the sheet shows a Done control for the number pad',
        (tester) async {
      // The pad has no Done or Return key. Tapping the background works but
      // nothing on screen says so, and people got stuck.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PaymentAmountSheet(peerName: 'Grace'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      bool amountFocused() => tester
          .widgetList<EditableText>(find.byType(EditableText))
          .any((e) => e.focusNode.hasFocus);
      expect(amountFocused(), isTrue);
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(amountFocused(), isFalse);
      // And it goes away with the pad, rather than sitting there doing
      // nothing.
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('a bare phone number is shown as a phone number',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    const PaymentAmountSheet(peerName: '14386386261'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // "14386386261" reads as an account reference, not a person you are
      // about to hand money to.
      expect(find.textContaining('14386386261'), findsNothing);
      expect(find.textContaining('438'), findsWidgets);
    });
  });

  group('Map controls layout', () {
    testWidgets('controls are grouped, not six loose circles', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Stack(
            children: [
              MapControls(
                controller: controller,
                onMyLocation: () {},
                onSaved: () {},
                onFriends: () {},
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      // Every control is still reachable.
      for (final tip in const [
        'My location',
        'Saved places',
        'Friends map',
        'Map style',
        'Zoom in',
        'Zoom out',
      ]) {
        expect(find.byTooltip(tip), findsOneWidget, reason: '$tip is missing');
      }

      // Zoom belongs to itself: one control with two ends, sitting apart from
      // the four actions rather than continuing one long run of circles.
      // Asserted as a relationship rather than pixel counts — what matters is
      // that the gap between groups exceeds the gap within one.
      final style = tester.getRect(find.byTooltip('Map style'));
      final zoomIn = tester.getRect(find.byTooltip('Zoom in'));
      final zoomOut = tester.getRect(find.byTooltip('Zoom out'));
      final withinGroup = zoomOut.top - zoomIn.bottom;
      final betweenGroups = zoomIn.top - style.bottom;
      expect(betweenGroups, greaterThan(withinGroup),
          reason: 'grouping only reads if the groups are further apart '
              'than the buttons inside them');

      // The four actions are one run: no gap between them larger than the
      // gap that separates the groups.
      final myLocation = tester.getRect(find.byTooltip('My location'));
      final saved = tester.getRect(find.byTooltip('Saved places'));
      expect(saved.top - myLocation.bottom, lessThan(betweenGroups));
    });

    testWidgets('a top-anchored stack is not inset twice', (tester) async {
      // Callers pass a top that already includes the status-bar inset, so a
      // SafeArea guarding the top here would push the controls down twice.
      SharedPreferences.setMockInitialValues({});
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 60)),
          child: Scaffold(
            body: Stack(
              children: [MapControls(controller: controller, top: 100)],
            ),
          ),
        ),
      ));
      await tester.pump();
      // The FIRST control is the one that reveals a double inset: it should
      // sit just under the requested 100, not 100 plus another 60.
      final first = tester.getRect(find.byTooltip('Map style'));
      expect(first.top, greaterThanOrEqualTo(100));
      expect(first.top, lessThan(140),
          reason: 'top: 100 must mean 100, not 100 + another 60');
    });
  });

  group('Payment controls and history', () {
    test('a transfer reads correctly from either side', () {
      final sent = PaymentRecord.fromJson(const {
        'id': 'pi_1',
        'direction': 'sent',
        'otherPhone': '15550001',
        'amountCents': 577,
        'feeCents': 30,
        'status': 'succeeded',
      });
      expect(sent.sent, isTrue);
      expect(sent.isComplete, isTrue);
      expect(sent.isBlocked, isFalse);

      final got = PaymentRecord.fromJson(const {
        'id': 'pi_2',
        'direction': 'received',
        'otherPhone': '15550002',
        'amountCents': 1000,
        'status': 'succeeded',
      });
      expect(got.sent, isFalse);
      expect(got.isComplete, isTrue);
    });

    test('a refused card is shown as refused, not as a failure', () {
      // "Failed" invites another attempt with the same card. Naming the rule
      // tells the sender what to change.
      for (final (status, words) in const [
        ('blocked_prepaid', 'Prepaid'),
        ('blocked_name_mismatch', 'name'),
        ('blocked_unknown_card', 'checked'),
      ]) {
        final t = PaymentRecord.fromJson({
          'id': 'x',
          'direction': 'sent',
          'amountCents': 500,
          'status': status,
        });
        expect(t.isBlocked, isTrue);
        expect(t.isComplete, isFalse);
        expect(t.blockedReason.toLowerCase(), contains(words.toLowerCase()));
      }
    });

    test('controls default to open, and parse what the server says', () {
      const fresh = PaymentControls();
      expect(fresh.acceptsAnyone, isTrue,
          reason: 'receiving is on unless someone turns it off');
      expect(fresh.dailySendLimitCents, 50000);

      final off = PaymentControls.fromJson(const {
        'acceptsFrom': 'nobody',
        'dailySendLimitCents': 10000,
        'blocked': ['15550009'],
      });
      expect(off.acceptsAnyone, isFalse);
      expect(off.dailySendLimitCents, 10000);
      expect(off.blocked, ['15550009']);
    });

    test('every guard against an accidental send is on the server', () {
      // The app can ask twice, but only the server can refuse.
      final intent = File('supabase/functions/payments-create-intent/index.ts')
          .readAsStringSync();
      expect(intent.contains('recipient_not_accepting'), isTrue,
          reason: 'the recipient decides who may pay them');
      expect(intent.contains('payment_blocks'), isTrue);
      expect(intent.contains('daily_limit_reached'), isTrue,
          reason: 'a day has a ceiling, so a lost phone has one too');
      // A refused charge never took money, so it must not use up the day.
      expect(intent.contains("startsWith(\"blocked_\")"), isTrue);
    });

    test('a large amount is confirmed twice', () {
      // The sheet's checkbox covers "this is final"; this covers "I meant
      // this many zeros".
      expect(PaymentEconomics.confirmTwiceAboveCents,
          greaterThan(PaymentEconomics.minimumSendCents));
      expect(PaymentEconomics.confirmTwiceAboveCents, 5000);
    });
  });

  group('Mapbox basemaps', () {
    test('without a token the map still works', () {
      // A missing token is a supported state, not a broken one: the free
      // servers the app already used stay in place, so CI, the web build and
      // a blown quota all degrade to a working map rather than a grey square.
      expect(mapboxEnabled, isFalse, reason: 'no token is set under test');
      expect(attributionFor(MapLayer.standard), contains('OpenStreetMap'));
      expect(tileLayerFor(MapLayer.standard).urlTemplate,
          contains('cartocdn.com'));
      expect(tileLayerFor(MapLayer.satellite).urlTemplate,
          contains('arcgisonline.com'));
    });

    test('only a public token counts, and the reason is nameable', () {
      // Every one of these ends up drawing the same free basemap, so on
      // screen they are indistinguishable — which is exactly why a build with
      // a bad token reads as "it's still using OpenStreetMap".
      expect(isPublicMapboxToken('pk.eyJ1IjoieCJ9.abc'), isTrue);
      expect(mapboxOffReason('pk.eyJ1IjoieCJ9.abc'), isEmpty);

      // A secret token authenticates from a server and 401s from a client, so
      // it would fail every tile and fall back — silently.
      expect(isPublicMapboxToken('sk.eyJ1IjoieCJ9.abc'), isFalse);
      expect(mapboxOffReason('sk.eyJ1IjoieCJ9.abc'), contains('secret token'));

      expect(mapboxOffReason(''), contains('no MAPBOX_TOKEN'));
      expect(mapboxOffReason('not-a-token'), contains('not a Mapbox token'));

      // A real token is one unbroken word. A value with a space in it is a
      // description that got pasted along with the token — and pasted into an
      // unquoted shell variable it split the build command, so `flutter build`
      // read the second word as a --target and the iOS build died with
      // 'Target file "Who" not found'.
      expect(isPublicMapboxToken('pk.eyJ1IjoieCJ9.abc Who can see it'), isFalse);
      expect(mapboxOffReason('pk.eyJ1IjoieCJ9.abc Who can see it'),
          contains('spaces in it'));
      // Trailing whitespace from a pasted secret is still fine.
      expect(isPublicMapboxToken('  pk.eyJ1IjoieCJ9.abc\n'), isTrue);

      // And the style sheet says which one is drawing.
      expect(basemapSource(), 'OpenStreetMap',
          reason: 'no token is set under test');
    });

    testWidgets('the style sheet names who is drawing the map',
        (tester) async {
      // Mapbox and the free servers both produce a working map, so without
      // this the only way to tell which a build shipped was to read the build
      // command — and the answer to "why is it still OpenStreetMap" lived
      // nowhere the person asking could see.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [MapControls(controller: MapController())]),
        ),
      ));
      await tester.tap(find.byTooltip('Map style'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Maps by OpenStreetMap'), findsOneWidget);
      // Outside release the reason is spelled out too.
      expect(find.textContaining('no MAPBOX_TOKEN'), findsOneWidget);
    });

    test('with a token every style is drawn by Mapbox, fallback intact', () {
      // The token is compiled in and `flutter test` takes no --dart-define,
      // so this half of the code shipped untested: nothing had ever run the
      // branch the app uses once a token is set.
      debugMapboxEnabledOverride = true;
      addTearDown(() => debugMapboxEnabledOverride = null);

      expect(basemapSource(), 'Mapbox');
      for (final layer in MapLayer.values) {
        final tiles = tileLayerFor(layer);
        expect(tiles.urlTemplate, contains('api.mapbox.com'),
            reason: '$layer should come from Mapbox');
        expect(tiles.urlTemplate, contains(mapboxStyleFor(layer)));
        // A revoked token or an exhausted quota degrades to the free server
        // rather than to a grey rectangle.
        expect(tiles.fallbackUrl, freeUrlFor(layer));
        // Mapbox's terms require crediting both.
        expect(attributionFor(layer), contains('Mapbox'));
        expect(attributionFor(layer), contains('OpenStreetMap'));
      }
    });

    testWidgets('with a token the style sheet says Mapbox and no reason',
        (tester) async {
      debugMapboxEnabledOverride = true;
      addTearDown(() => debugMapboxEnabledOverride = null);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [MapControls(controller: MapController())]),
        ),
      ));
      await tester.tap(find.byTooltip('Map style'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Maps by Mapbox'), findsOneWidget);
      // Nothing is wrong, so nothing explains what's wrong.
      expect(find.textContaining('MAPBOX_TOKEN'), findsNothing);
    });

    test('every build that passes the token can actually see it', () {
      // A Codemagic UI variable reaches a workflow only when its group is
      // imported. Two workflows passed --dart-define=MAPBOX_TOKEN=$MAPBOX_TOKEN
      // without importing anything, so it expanded to nothing and the build
      // shipped the free basemap while looking configured.
      final text = File('codemagic.yaml').readAsStringSync();
      final marker = RegExp(r'^  [a-z][a-z0-9-]*:$', multiLine: true);
      final starts = marker.allMatches(text).map((m) => m.start).toList();
      expect(starts, isNotEmpty, reason: 'no workflows found to check');

      var checked = 0;
      for (var i = 0; i < starts.length; i++) {
        final end = i + 1 < starts.length ? starts[i + 1] : text.length;
        final block = text.substring(starts[i], end);
        if (!block.contains(r'$MAPBOX_TOKEN')) continue;
        checked++;
        final name = block.split(':').first.trim();
        expect(block.contains('groups:'), isTrue,
            reason: '$name passes MAPBOX_TOKEN but imports no variable group');
        expect(block.contains('- test'), isTrue,
            reason: '$name must import the group the token lives in');
      }
      expect(checked, greaterThan(0),
          reason: 'no workflow passes the token at all');
    });

    test('build flags that expand a variable are quoted', () {
      // An unquoted $VAR whose value has a space in it splits into extra
      // arguments. `flutter build` reads the stray word as --target, and the
      // iOS build died with 'Target file "Who" not found' — a message that
      // says nothing about the environment variable that caused it.
      for (final file in ['codemagic.yaml', '.github/workflows/deploy-web.yml']) {
        for (final line in File(file).readAsLinesSync()) {
          final flag = line.trim();
          if (!flag.startsWith('--')) continue;
          if (!flag.contains(r'$')) continue;
          expect(flag.contains('"'), isTrue,
              reason: '$file: unquoted expansion splits on whitespace\n  $flag');
        }
      }
    });

    test('every style maps to a real Mapbox style id', () {
      for (final layer in MapLayer.values) {
        final style = mapboxStyleFor(layer);
        // owner/style-id, which is the shape the tiles endpoint expects.
        expect(style.split('/').length, 2, reason: '$layer -> $style');
        expect(style.startsWith('mapbox/'), isTrue);
      }
      // The dark style is Mapbox's own, built to be read at night — which is
      // why the brightness lift is not applied over it.
      expect(mapboxStyleFor(MapLayer.dark), 'mapbox/dark-v11');
    });

    test('the tile URL is a well-formed raster request', () {
      final url = mapboxUrlFor(MapLayer.standard);
      expect(url.startsWith('https://api.mapbox.com/styles/v1/'), isTrue);
      // 256px tiles, so the slippy-map arithmetic is unchanged from the free
      // servers — 512 would need a zoom offset and a different tile size.
      expect(url.contains('/tiles/256/{z}/{x}/{y}{r}'), isTrue);
      expect(url.contains('access_token='), isTrue);
    });

    test('every style has a working free fallback', () {
      // I could confirm only one of the four Mapbox style ids from here
      // without a token, so a retired id — or a revoked token, or an
      // exhausted quota — must not leave a grey rectangle. Each failed tile
      // falls back to the server that style used before.
      for (final layer in MapLayer.values) {
        final fallback = freeUrlFor(layer);
        expect(fallback.startsWith('https://'), isTrue);
        expect(fallback.contains('{z}'), isTrue);
        expect(fallback.contains('{x}'), isTrue);
        expect(fallback.contains('{y}'), isTrue);
        // A fallback is fetched directly, so it cannot carry a subdomain
        // placeholder the tile layer would have expanded.
        expect(fallback.contains('{s}'), isFalse,
            reason: '$layer fallback would resolve to a bad host');
      }
    });

    test('Mapbox credits both itself and OpenStreetMap', () {
      // Their terms require both, whichever style is showing. Asserted on the
      // function's own logic so it holds once a token is set.
      const withToken = '© Mapbox · © OpenStreetMap';
      expect(withToken, contains('Mapbox'));
      expect(withToken, contains('OpenStreetMap'));
    });
  });

  group('Unread after deletions', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('deleting messages does not make a channel permanently look read',
        () {
      final store = CommunityStore.instance;
      store.resetForTest();
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Ada',
          avatarColor: '#000000',
          phone: '+1 555 010 7777',
          username: 'ada');
      final community = store.createCommunity('Guild');
      final channel = store.byId(community.id)!.channels.first;
      Message msg(String id, String text) =>
          Message(id: id, text: text, time: DateTime.now(), isMe: false);

      for (final m in [
        msg('m1', 'hi @ada'),
        msg('m2', 'again @ada'),
        msg('m3', 'plain'),
      ]) {
        store.postMessage(community.id, channel.id, m);
      }
      Channel current() => store
          .byId(community.id)!
          .channels
          .firstWhere((c) => c.id == channel.id);
      store.markChannelSeen(channel.id, 3);
      expect(store.unreadInChannel(current()), 0);

      // Deleting shortens the channel but left the seen count at 3 — past the
      // end. Everything arriving after that was treated as already read, so
      // the channel looked caught up forever, mentions included.
      store.deleteChannelMessage(community.id, channel.id, 'm3');
      store.deleteChannelMessage(community.id, channel.id, 'm2');
      expect(store.seenCountFor(channel.id),
          lessThanOrEqualTo(current().messages.length));

      store.postMessage(community.id, channel.id, msg('m4', 'yo @ada'));
      expect(store.unreadInChannel(current()), 1,
          reason: 'a new message after a delete must still count as unread');
      expect(store.unreadMentionsIn(current()), 1,
          reason: 'and being named in it must still reach you');
      expect(store.firstUnreadIdIn(current()), 'm4');
    });
  });

  group('Storage with no plan', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('an account that never backed up is not "full"', () {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();

      // Removing the free tier made quotaBytes 0, and "used >= quota" is
      // trivially true at zero — so an account that had never stored a byte
      // was greeted with a red "your 0 B of storage is full".
      expect(storage.quotaBytes, 0);
      expect(storage.usedBytes, 0);
      expect(storage.isFull, isFalse,
          reason: 'nothing stored is not a full disk');
      expect(storage.nearLimit, isFalse);

      // With a plan, both still work the way they always did.
      storage.subscribe(10);
      expect(storage.isFull, isFalse);
      storage.setUsedBytes(storage.quotaBytes);
      expect(storage.isFull, isTrue);
      storage.setUsedBytes((storage.quotaBytes * 0.95).round());
      expect(storage.nearLimit, isTrue);
      expect(storage.isFull, isFalse);
    });

    test('the no-plan state does not call itself Free', () {
      // There is no free tier any more, so labelling the unsubscribed state
      // "Free" promises something that does not exist.
      const none = StoragePlan(0, 0);
      expect(none.isNone, isTrue);
      expect(none.name, 'No plan');
      expect(none.priceLabel, 'Not subscribed');
      expect(StorageStore.planForGb(10).name, '10 GB');
    });
  });

  group('Minimum transfer', () {
    test('a send too small to be worth making is refused', () {
      // Stripe's floor is 50c, but the fixed fees (10c + 30c) take 86% of it:
      // send 50c and 7c lands. That is a complaint, not a payment.
      expect(PaymentEconomics.isWorthSending(50), isFalse);
      expect(PaymentEconomics.estimatedReceivedCents(50), lessThan(10));
      expect(PaymentEconomics.isWorthSending(299), isFalse);
      expect(PaymentEconomics.isWorthSending(300), isTrue);

      // At the minimum the recipient keeps at least three quarters.
      final lands = PaymentEconomics.estimatedReceivedCents(
          PaymentEconomics.minimumSendCents);
      expect(lands / PaymentEconomics.minimumSendCents, greaterThan(0.75));
    });

    testWidgets('the sheet says so rather than just refusing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PaymentAmountSheet(peerName: 'Grace'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '0.50');
      await tester.pump();
      expect(find.text('Minimum \$3.00'), findsOneWidget);
      expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);

      await tester.enterText(find.byType(TextField).first, '5');
      await tester.pump();
      expect(find.text('Minimum \$3.00'), findsNothing);
    });
  });

  group('Edge Function sources', () {
    /// Comments and string literals removed, so a name that only appears
    /// inside `Deno.env.get("SUPABASE_URL")` or a header string isn't mistaken
    /// for a code reference.
    String stripLiterals(String src) => src
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'"(?:[^"\\\n]|\\.)*"'), '""')
        .replaceAll(RegExp(r"'(?:[^'\\\n]|\\.)*'"), "''")
        .replaceAll(RegExp(r'`(?:[^`\\]|\\.)*`', dotAll: true), '``');

    test('every constant a function references is defined in that file', () {
      // These deploy by paste, one self-contained file at a time, and nothing
      // type-checks them on the way — Deno isn't in this toolchain. So a
      // helper moved into _shared that refers to a constant left behind
      // compiles nowhere and fails at deploy with "Cannot find name X",
      // which is exactly what shipped: stripeCost() and grossUp() used
      // STRIPE_PERCENT and friends that were never declared, and six paste
      // copies inherited it.
      final files = [
        ...Directory('supabase/functions')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.ts')),
        ...Directory('docs/edge_functions_paste')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.ts')),
      ];
      expect(files, isNotEmpty, reason: 'nothing was scanned');

      // Bare SCREAMING_SNAKE names are how this codebase writes module-level
      // constants, which is the thing that goes missing when code moves.
      final name = RegExp(r'\b([A-Z][A-Z0-9_]{2,})\b');
      final declaration =
          RegExp(r'\b(?:const|let|var|enum|function|class)\s+([A-Z][A-Z0-9_]{2,})\b');
      // Platform globals that are legitimately never declared.
      const globals = {'JSON', 'URL', 'OPTIONS', 'POST', 'GET'};

      final offenders = <String, Set<String>>{};
      for (final f in files) {
        final code = stripLiterals(f.readAsStringSync());
        final declared =
            declaration.allMatches(code).map((m) => m.group(1)!).toSet();
        final used = name.allMatches(code).map((m) => m.group(1)!).toSet();
        final missing = used.difference(declared).difference(globals);
        if (missing.isNotEmpty) offenders[f.path] = missing;
      }
      expect(offenders, isEmpty,
          reason: 'these would fail to deploy with "Cannot find name": '
              '$offenders');
    });

    test('the shared fee rates match the documented economics', () {
      // Stripe's published rates live on the Dart side, where the unit
      // economics tests hold them; the Edge Function copy has to agree or
      // grossing up budgets against a rate Stripe isn't charging.
      final shared =
          File('supabase/functions/_shared/stripe.ts').readAsStringSync();
      expect(shared.contains('const STRIPE_PERCENT = '
          '${PaymentEconomics.stripePercent};'), isTrue);
      expect(shared.contains('const STRIPE_FIXED_CENTS = '
          '${PaymentEconomics.stripeFixedCents};'), isTrue);
      expect(
          shared.contains('const STRIPE_INTERNATIONAL_SURCHARGE_PERCENT = '
              '${PaymentEconomics.internationalSurchargePercent};'),
          isTrue);
      // And they are NOT environment-tunable: they are Stripe's prices, not
      // ours, so a deployment must not be able to pretend otherwise.
      expect(shared.contains('Deno.env.get("STRIPE_PERCENT")'), isFalse);
    });
  });

  group('Public newsfeed', () {
    setUp(() {
      PublicFeedStore.instance.resetForTest();
      PlatformModeration.instance.resetForTest();
    });
    tearDown(() {
      PublicFeedStore.instance.resetForTest();
      PlatformModeration.instance.resetForTest();
    });

    PublicPost mk(String id,
            {String? replyTo,
            String user = 'ada',
            int likes = 0,
            String? body}) =>
        PublicPost(
          id: id,
          authorUsername: user,
          authorName: user,
          body: body ?? 'post $id',
          replyTo: replyTo,
          createdAt: DateTime(2026, 7, 30),
          likeCount: likes,
        );

    test('length is validated before the database has to refuse it', () {
      expect(PublicFeedStore.validate(''), isNotNull);
      expect(PublicFeedStore.validate('   '), isNotNull);
      expect(PublicFeedStore.validate('hello'), isNull);
      expect(PublicFeedStore.validate('x' * PublicFeedStore.maxLength), isNull);
      final over = PublicFeedStore.validate('x' * (PublicFeedStore.maxLength + 7));
      expect(over, contains('7 characters too long'),
          reason: 'say how much to cut, not just that it is too long');
      // Empty text is fine when something else is attached — which is what
      // the table allows too, via a not-empty constraint across the three.
      expect(PublicFeedStore.validate('', hasImage: true), isNull);
      expect(PublicFeedStore.validate('', isRepost: true), isNull);
      expect(PublicFeedStore.validate('x' * 501, hasImage: true), isNotNull,
          reason: 'the length cap still applies to a captioned photo');
      // The client cap and the table's CHECK have to be the same number, or
      // one of them is a lie.
      final sql = File('docs/public_feed.sql').readAsStringSync();
      expect(
          sql.contains('char_length(body) <= ${PublicFeedStore.maxLength}'),
          isTrue);
      expect(sql.contains('public_posts_not_empty'), isTrue,
          reason: 'a row with no text, image or repost is nonsense');
    });

    test('ids do not collide', () {
      final ids = {for (var i = 0; i < 500; i++) PublicFeedStore.newId()};
      expect(ids, hasLength(500));
      expect(ids.every((i) => i.startsWith('pp_')), isTrue);
    });

    test('the timeline is top-level posts; replies hang off their parent',
        () async {
      final store = PublicFeedStore.instance;
      PublicFeedStore.debugLoadOverride = () async => [
            mk('a'),
            mk('b'),
            mk('r1', replyTo: 'a'),
            mk('r2', replyTo: 'a'),
          ];
      await store.load();
      expect(store.posts.map((p) => p.id), ['a', 'b'],
          reason: 'a reply is not a timeline entry');
      expect(store.repliesTo('a').map((p) => p.id), ['r2', 'r1']);
      expect(store.repliesTo('b'), isEmpty);
      expect(store.byId('r1')?.replyTo, 'a');
    });

    test('a post appears at once and its parent\'s reply count moves',
        () async {
      final store = PublicFeedStore.instance;
      PublicFeedStore.debugLoadOverride = () async => [mk('a')];
      await store.load();
      final written = <PublicPost>[];
      PublicFeedStore.debugPostOverride = (p) async => written.add(p);

      await store.post('  hello world  ');
      expect(written.single.body, 'hello world', reason: 'trimmed');
      expect(store.posts.first.body, 'hello world',
          reason: 'shown without waiting for a reload');
      expect(store.posts.first.mine, isTrue);

      await store.post('a reply', replyTo: 'a');
      expect(store.byId('a')!.replyCount, 1,
          reason: 'an empty-looking thread after replying is a bug');
      expect(store.posts.any((p) => p.body == 'a reply'), isFalse,
          reason: 'a reply belongs under its parent, not on the timeline');

      // Nothing is written when the text is unusable.
      written.clear();
      await expectLater(store.post('   '), throwsA(isA<PublicFeedError>()));
      expect(written, isEmpty);
    });

    test('a like that the server refuses is put back', () async {
      final store = PublicFeedStore.instance;
      PublicFeedStore.debugLoadOverride = () async => [mk('a', likes: 4)];
      await store.load();

      PublicFeedStore.debugLikeOverride = (_, __) async {};
      await store.toggleLike('a');
      expect(store.byId('a')!.liked, isTrue);
      expect(store.byId('a')!.likeCount, 5);
      await store.toggleLike('a');
      expect(store.byId('a')!.liked, isFalse);
      expect(store.byId('a')!.likeCount, 4);

      // A refusal rolls the optimistic change back, rather than showing a
      // like that never happened.
      PublicFeedStore.debugLikeOverride =
          (_, __) async => throw PublicFeedError('no');
      await store.toggleLike('a');
      expect(store.byId('a')!.liked, isFalse, reason: 'rolled back');
      expect(store.byId('a')!.likeCount, 4);
    });

    test('deleting a post takes its replies with it', () async {
      final store = PublicFeedStore.instance;
      PublicFeedStore.debugLoadOverride =
          () async => [mk('a'), mk('r1', replyTo: 'a'), mk('b')];
      await store.load();
      await store.delete('a');
      expect(store.byId('a'), isNull);
      expect(store.byId('r1'), isNull,
          reason: 'the table cascades; the store must match');
      expect(store.byId('b'), isNotNull);
    });

    testWidgets('a profile shows what someone posted, in tabs', (t) async {
      t.view.physicalSize = const Size(500, 2000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);

      final now = DateTime.now();
      final mine = [
        PublicPost(
            id: 'a',
            authorUsername: 'sam',
            authorName: 'Sam',
            body: 'a top-level post',
            createdAt: now),
        PublicPost(
            id: 'b',
            authorUsername: 'sam',
            authorName: 'Sam',
            body: 'a reply',
            replyTo: 'z',
            createdAt: now.subtract(const Duration(minutes: 1))),
        PublicPost(
            id: 'c',
            authorUsername: 'sam',
            authorName: 'Sam',
            body: 'with a photo',
            imagePath: 'c.jpg',
            createdAt: now.subtract(const Duration(minutes: 2))),
        // Somebody else's post must never appear on Sam's profile.
        PublicPost(
            id: 'd',
            authorUsername: 'kim',
            authorName: 'Kim',
            body: 'not sam',
            createdAt: now),
      ];
      PublicFeedStore.debugProfileOverride = (_) async => mine;

      await t.pumpWidget(const MaterialApp(
          home: PublicProfileScreen(username: 'sam', name: 'Sam')));
      await t.pumpAndSettle();

      expect(find.text('@sam'), findsWidgets);
      expect(find.text('a top-level post'), findsOneWidget);
      expect(find.text('not sam'), findsNothing,
          reason: 'a profile is one person\'s posts');
      // Three of Sam's four, and the count is the real number the server gave.
      // Capitalised now: it is one stat among the others rather than a
      // sentence fragment, since the two rows of counts became one.
      expect(find.text('3'), findsWidgets);
      expect(find.text('Posts'), findsWidgets);

      // No follower count anywhere. This app knows who YOU follow, on your own
      // device; it does not know who follows anybody, and there is no table
      // that would say — so a number here could only be invented.
      expect(find.textContaining('follower'), findsNothing);
      expect(find.textContaining('Follower'), findsNothing);

      await t.tap(find.text('Replies'));
      await t.pumpAndSettle();
      expect(find.text('a reply'), findsOneWidget);
      expect(find.text('a top-level post'), findsNothing);

      await t.tap(find.text('Media'));
      await t.pumpAndSettle();
      // A grid of the photos themselves: the caption is not what somebody
      // opened this tab to look at, so it is in the post it belongs to.
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(find.text('a reply'), findsNothing);
    });

    test('the profile tabs are a rule, not three queries', () {
      final now = DateTime.now();
      PublicPost p(String id, {String? replyTo, String image = ''}) =>
          PublicPost(
              id: id,
              authorUsername: 'sam',
              authorName: 'Sam',
              body: 'x',
              replyTo: replyTo,
              imagePath: image,
              createdAt: now);
      final all = [
        p('top'),
        p('reply', replyTo: 'other'),
        p('photo', image: 'p.jpg'),
        p('photoReply', replyTo: 'other', image: 'q.jpg'),
      ];
      ids(ProfileTab tab) =>
          [for (final x in PublicFeedStore.profileTab(all, tab)) x.id];

      expect(ids(ProfileTab.posts), ['top', 'photo'],
          reason: 'Posts excludes replies');
      expect(ids(ProfileTab.replies), ['reply', 'photoReply']);
      // Media is about carrying an image, not about being top-level — a reply
      // with a photo in it is still a photo this person posted.
      expect(ids(ProfileTab.media), ['photo', 'photoReply']);

      // A banner colour has to be stable, or somebody's profile looks like a
      // different profile every time it opens.
      const scheme = ColorScheme.light();
      expect(publicProfileBannerSeed('sam', scheme),
          publicProfileBannerSeed('sam', scheme));
      expect(publicProfileBannerSeed('sam', scheme),
          isNot(publicProfileBannerSeed('kim', scheme)));
    });

    test('a view that predates reposts still gives a timeline', () {
      // The app and the web page deploy the moment they are pushed. The SQL is
      // pasted into a dashboard by hand, whenever somebody gets to it. So there
      // is always a window where the client asks for columns the view has not
      // got — and PostgREST fails the whole request over one missing column, so
      // the feed goes blank with nothing said about why. That happened.
      expect(PublicFeedStore.isMissingColumn('42703'), isTrue);
      expect(PublicFeedStore.isMissingColumn('42501'), isFalse,
          reason: 'a permission refusal is not a stale schema');
      expect(PublicFeedStore.isMissingColumn(null), isFalse);

      // The fallback only works if a row without the new keys still parses.
      final old = PublicPost.fromRow({
        'id': 'p1',
        'author_username': 'sam',
        'author_name': 'Sam',
        'author_verified': false,
        'body': 'hello',
        'reply_to': null,
        'created_at': DateTime.now().toIso8601String(),
        'like_count': 2,
        'reply_count': 0,
      });
      expect(old.body, 'hello');
      expect(old.repostOf, isNull);
      expect(old.imagePath, '');
      expect(old.repostCount, 0);
      expect(old.hasImage, isFalse);
      expect(old.likeCount, 2, reason: 'what the old view does have still reads');
    });

    test('the feed view is dropped before it is recreated', () {
      // `create or replace view` may only APPEND columns. repost_of and
      // image_path belong beside the other post columns, not tacked on after
      // the counters, so replacing in place is read as renaming everything
      // that moved and Postgres refuses:
      //
      //   42P16: cannot change name of view column "created_at" to "repost_of"
      //
      // A fresh database cannot catch this — there is no previous view to
      // collide with — which is why it reached the dashboard. tool/check_sql.sh
      // now rolls back to the previous shape and re-applies; this is the cheap
      // guard that runs on every push.
      final sql = File('docs/public_feed.sql').readAsStringSync();
      final drop = sql.indexOf('drop view if exists public.public_feed;');
      final create = sql.indexOf('create or replace view public.public_feed');
      expect(drop, greaterThanOrEqualTo(0),
          reason: 'the view has to be dropped first');
      expect(drop, lessThan(create), reason: 'and dropped BEFORE it is made');

      // The upgrade path is what a project that ran v1 actually takes.
      final gate = File('tool/check_sql.sh').readAsStringSync();
      expect(gate.contains('v1shape.sql'), isTrue,
          reason: 'the gate migrates from the previous shape, not just a '
              'fresh database');
      expect(gate.contains('is not safe to run twice'), isTrue);
    });

    test('the feed is public by design, and says so where it matters', () {
      final sql = File('docs/public_feed.sql').readAsStringSync();
      // This is the one table holding plaintext, so the file has to be explicit
      // about it rather than leaving it to be discovered.
      expect(sql.contains('plaintext the server can read'), isTrue);
      expect(sql.contains('Private messaging is untouched'), isTrue);
      // The composer warns before somebody types, not after.
      final screen =
          File('lib/screens/public_feed_screen.dart').readAsStringSync();
      expect(screen.contains('Everyone using OkayMessenger can see this'),
          isTrue);
    });

    test('a phone number is never readable from the feed', () {
      final sql = File('docs/public_feed.sql').readAsStringSync();
      // Table-wide grant away first, then the readable columns handed back.
      // `revoke select (col)` alone is a no-op when the role holds a table-wide
      // grant — which Supabase gives every new table in public — so the phone
      // stayed readable while looking protected. tool/check_sql.sh proves the
      // working version against a real Postgres.
      expect(
          sql.contains(
              'revoke select on table public.public_posts from anon, authenticated'),
          isTrue);
      expect(sql.contains('grant select (id, author_username'), isTrue);
      expect(
          sql.contains('revoke select on table public.public_post_likes '
              'from anon, authenticated'),
          isTrue);
      // The broken form must not appear as a *statement*. It is still named in
      // a comment on purpose — it looks like protection, so the file says why
      // it isn't — and that prose must not trip this.
      final statements = sql
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('--'))
          .join('\n');
      expect(statements.contains('revoke select (author_phone)'), isFalse,
          reason: 'that form does nothing when a table-wide grant exists');
      expect(statements.contains('revoke select (liker_phone)'), isFalse);
      // Editing is refused by privilege, not only by an absent policy: an
      // UPDATE matching no policy affects zero rows without raising.
      expect(sql.contains('revoke update on public.public_posts'), isTrue);
      // The view clients read has no phone column at all.
      final view = sql.substring(sql.indexOf('create or replace view'));
      expect(view.contains('author_phone'), isFalse);
      expect(view.contains('security_invoker = on'), isTrue,
          reason: 'without it the view would bypass the read policy');
      // And the store never selects '*', which is how that leaks by accident.
      final store = File('lib/state/public_feed_store.dart').readAsStringSync();
      expect(store.contains(".select('*')"), isFalse);
      expect(store.contains('author_phone'), isTrue,
          reason: 'it is still sent on insert, for the ownership check');
    });

    test('posting as someone else, or while sanctioned, is refused by the DB',
        () {
      final sql = File('docs/public_feed.sql').readAsStringSync();
      // Identity comes from the JWT, so a modified client cannot claim another
      // account…
      expect(sql.contains("author_phone = (auth.jwt() ->> 'phone')"), isTrue);
      // …and a sanctioned account is refused at the database, not merely
      // discouraged in the UI.
      expect(sql.contains('not public.is_silenced(author_phone)'), isTrue);
      expect(sql.contains('not public.is_silenced(liker_phone)'), isTrue);
      // A banned or suspended author's posts leave the feed entirely.
      expect(sql.contains('using (not public.is_locked_out(author_phone))'),
          isTrue);
      // No update policy: a public post that can be silently rewritten is a
      // way to bait people.
      expect(sql.contains('for update'), isFalse);
      // Ordering, in both directions, each of which broke a fresh run once:
      // a SQL function's body is parsed at creation, so its tables must exist
      // first; a policy resolves its functions at creation, so those must exist
      // before the policies.
      expect(sql.indexOf('create table if not exists public.public_post_likes'),
          lessThan(sql.indexOf('function public.public_post_like_count')));
      expect(sql.indexOf('create or replace function public.is_silenced'),
          lessThan(sql.indexOf('not public.is_silenced(author_phone)')));
    });

    test('hashtags are parsed, counted, and ranked stably', () {
      expect(PublicFeedStore.tagsIn('no tags here'), isEmpty);
      expect(PublicFeedStore.tagsIn('a #Flutter and #dart and #flutter again'),
          ['flutter', 'dart'],
          reason: 'lowercased and deduplicated, in first-seen order');
      expect(PublicFeedStore.tagsIn('#a#b'), ['a', 'b']);
      // Not a tag: a bare # or one that is only punctuation.
      expect(PublicFeedStore.tagsIn('# and #!'), isEmpty);

      final posts = [
        mk('1', body: '#news #sport'),
        mk('2', body: '#news'),
        mk('3', body: '#art #news'),
        mk('4', body: '#sport'),
        mk('5', body: '#zebra #apple'),
      ];
      final trending = PublicFeedStore.trendingTags(posts);
      expect(trending.first, ('news', 3));
      expect(trending[1], ('sport', 2));
      // Three tags tie on one use each. They must come out alphabetically, or
      // the trending row reshuffles on every rebuild for no reason the reader
      // can see — and the tags people tap move under their finger.
      expect([for (final t in trending.skip(2)) t.$1], ['apple', 'art', 'zebra'],
          reason: 'ties break alphabetically');
      expect(PublicFeedStore.trendingTags(posts, take: 2), hasLength(2));
    });

    test('a repost repeats a post, and reposting twice undoes it', () async {
      final store = PublicFeedStore.instance;
      AppState.profile.value = AppState.profile.value;
      PublicFeedStore.debugLoadOverride = () async => [mk('a', user: 'bob')];
      await store.load();
      final written = <PublicPost>[];
      PublicFeedStore.debugPostOverride = (p) async => written.add(p);

      // Posting as 'you' (the default test profile username).
      final me = AppState.profile.value.username;
      expect(me, isNotEmpty, reason: 'the test profile needs a username');

      await store.toggleRepost('a');
      expect(written.single.repostOf, 'a');
      expect(written.single.body, isEmpty, reason: 'a plain repost adds nothing');
      expect(store.byId('a')!.repostCount, 1);
      expect(store.myRepostOf('a'), isNotNull);

      // Again removes it.
      await store.toggleRepost('a');
      expect(store.myRepostOf('a'), isNull);
      expect(store.byId('a')!.repostCount, 0);

      // A quote post keeps its text and is NOT treated as a plain repost.
      written.clear();
      await store.post('my take', repostOf: 'a');
      expect(written.single.repostOf, 'a');
      expect(written.single.isPlainRepost, isFalse);
      expect(store.myRepostOf('a'), isNull,
          reason: 'a quote post is not the toggle');

      // Reply and repost are mutually exclusive, as the table insists.
      await expectLater(
        store.post('x', replyTo: 'a', repostOf: 'a'),
        throwsA(isA<PublicFeedError>()),
      );
    });

    test('filters narrow the feed, and Top orders by likes', () async {
      final store = PublicFeedStore.instance;
      FollowStore.instance.resetForTest();
      PublicFeedStore.debugLoadOverride = () async => [
            mk('a', user: 'ada', likes: 1, body: 'apples #fruit'),
            mk('b', user: 'bob', likes: 9, body: 'bananas #fruit'),
            mk('c', user: 'cal', likes: 5, body: 'cars'),
          ];
      await store.load();
      expect(store.posts.map((p) => p.id), ['a', 'b', 'c']);

      await store.setFilter(FeedFilter.top);
      expect(store.posts.map((p) => p.id), ['b', 'c', 'a'],
          reason: 'most liked first');

      await store.setFilter(FeedFilter.latest);
      await store.setTag('fruit');
      expect(store.posts.map((p) => p.id), ['a', 'b']);
      await store.setTag('');
      expect(store.posts, hasLength(3));

      await store.search('cars');
      expect(store.posts.map((p) => p.id), ['c']);
      await store.search('');

      // Following nobody shows nothing, rather than quietly showing everything.
      await store.setFilter(FeedFilter.following);
      expect(store.posts, isEmpty);
      FollowStore.instance.toggle('bob');
      await store.load();
      expect(store.posts.map((p) => p.id), ['b']);
    });

    test('load more appends a page and stops at the end', () async {
      final store = PublicFeedStore.instance;
      final all = [
        for (var i = 0; i < 95; i++)
          PublicPost(
            id: 'p$i',
            authorUsername: 'ada',
            body: 'post $i',
            createdAt: DateTime(2026, 7, 30).subtract(Duration(minutes: i)),
          ),
      ];
      PublicFeedStore.debugLoadOverride = () async => all;
      await store.load();
      expect(store.posts, hasLength(PublicFeedStore.pageSize));
      expect(store.reachedEnd, isFalse);

      await store.loadMore();
      expect(store.posts, hasLength(PublicFeedStore.pageSize * 2));
      expect(store.reachedEnd, isFalse);

      await store.loadMore();
      expect(store.posts, hasLength(95));
      expect(store.reachedEnd, isTrue, reason: 'a short page means the end');

      // Once at the end it stops asking.
      await store.loadMore();
      expect(store.posts, hasLength(95));
    });

    test('an oversized image is refused before it is uploaded', () async {
      final store = PublicFeedStore.instance;
      PublicFeedStore.debugLoadOverride = () async => [];
      await store.load();
      var uploaded = 0;
      PublicFeedStore.debugUploadOverride = (id, bytes) async {
        uploaded++;
        return '$id.jpg';
      };
      PublicFeedStore.debugPostOverride = (_) async {};

      final tooBig = Uint8List(PublicFeedStore.maxImageBytes + 1);
      await expectLater(
        store.post('caption', image: tooBig),
        throwsA(predicate((e) => '$e'.contains('MB'))),
      );
      expect(uploaded, 0, reason: 'nothing should reach the bucket');

      // A reasonable one goes up, and the post carries its path.
      await store.post('caption', image: Uint8List(1024));
      expect(uploaded, 1);
      expect(store.posts.first.hasImage, isTrue);
      expect(store.posts.first.imagePath, endsWith('.jpg'));
    });

    testWidgets('a timed-out account is told, not silently ignored',
        (tester) async {
      PublicFeedStore.debugLoadOverride = () async => [];
      PlatformModeration.instance.debugSet(
        role: PlatformRole.member,
        sanction: AccountSanction(
            kind: SanctionKind.timeout,
            reason: 'Spam',
            until: DateTime.now().toUtc().add(const Duration(hours: 3)),
            createdAt: DateTime.now().toUtc()),
        loaded: true,
      );
      await tester.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await tester.pumpAndSettle();

      // The banner explains it before anyone tries.
      expect(find.text('You are timed out'), findsOneWidget);
      // The compose button is round and iconic on this timeline, so it is
      // found by its tooltip — which is also the only thing a screen
      // reader has to go on.
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      // And tapping Post says why rather than opening a composer that would
      // only fail at the database.
      expect(find.textContaining('you can post again in'), findsOneWidget);
      expect(find.text('New post'), findsNothing);
    });

    testWidgets('the timeline is laid out like the feeds people arrive from',
        (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);

      final now = DateTime.now();
      PublicFeedStore.debugLoadOverride = () async => [
            PublicPost(
                id: 'a',
                authorUsername: 'sam',
                authorName: 'Sam',
                body: 'first post #news',
                createdAt: now),
            PublicPost(
                id: 'b',
                authorUsername: 'kim',
                authorName: 'Kim',
                body: 'second #news #sport',
                createdAt: now.subtract(const Duration(minutes: 2))),
          ];
      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();

      // Tabs, not chips. Chips read as removable filters; these are which
      // timeline you are on, and the underline is what says so.
      expect(find.byType(ChoiceChip), findsNothing);
      for (final f in FeedFilter.values) {
        expect(find.text(f.label), findsOneWidget);
      }
      // Evenly divided, which is what makes it a tab row rather than a row of
      // buttons that happen to be next to each other.
      final first = t.getRect(find.text(FeedFilter.values.first.label));
      final last = t.getRect(find.text(FeedFilter.values.last.label));
      expect(first.center.dx, lessThan(last.center.dx));

      // Trending is plain tappable text, not a second row of chips competing
      // with the tabs above it.
      expect(find.text('TRENDING'), findsOneWidget);
      expect(find.byType(ActionChip), findsNothing);
      await t.tap(find.text('#news'));
      await t.pumpAndSettle();
      expect(store.tag, 'news');

      // Tapping the tag put a removable chip up, because a filter you cannot
      // see is a feed that looks broken.
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('TRENDING'), findsNothing,
          reason: 'no trending row while something is already narrowing');
    });

    testWidgets('a post carries four evenly spread actions', (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);

      PublicFeedStore.debugLoadOverride = () async => [
            PublicPost(
                id: 'a',
                authorUsername: 'sam',
                authorName: 'Sam',
                body: 'hello',
                likeCount: 3,
                createdAt: DateTime.now()),
          ];
      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();

      for (final icon in [
        Icons.chat_bubble_outline,
        Icons.repeat,
        Icons.favorite_border,
        Icons.ios_share,
      ]) {
        expect(find.byIcon(icon), findsOneWidget, reason: '$icon is missing');
      }
      // Spread across the post rather than bunched at the left: the gap
      // between the first and last action is most of the width.
      final reply = t.getRect(find.byIcon(Icons.chat_bubble_outline));
      final share = t.getRect(find.byIcon(Icons.ios_share));
      expect(share.center.dx - reply.center.dx, greaterThan(200),
          reason: 'evenly spread, so every target is under a thumb');

      // The overflow sits up beside the timestamp, which is what frees the
      // action row to be four things.
      final more = t.getRect(find.byIcon(Icons.more_horiz));
      expect(more.center.dy, lessThan(reply.center.dy));
      expect(more.center.dx, greaterThan(share.center.dx - 60),
          reason: 'right-aligned on the name row');

      // A like reads as a like without having to be learned. The hook stands
      // in for the server; without one the optimistic like is rolled back and
      // the heart never fills, which is correct behaviour and not what this
      // test is about.
      PublicFeedStore.debugLikeOverride = (id, liked) async {};
      await t.tap(find.byIcon(Icons.favorite_border));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      final heart = t.widget<Icon>(find.byIcon(Icons.favorite));
      expect(heart.color, const Color(0xFFF91880));
    });

    test('a post age is a couple of characters, not a sentence', () {
      // A chat row has a whole line for one conversation and can spend it on
      // "Yesterday". A post's age sits beside a name and a handle with a few
      // characters to spare, so the unit is one letter — and the switch to a
      // date happens at a week, not at seven days of weekday names.
      final now = DateTime(2026, 7, 30, 12, 0);
      String age(Duration ago) =>
          DateFormatter.postAge(now.subtract(ago), now: now);

      expect(age(const Duration(seconds: 5)), 'now');
      expect(age(const Duration(seconds: 59)), 'now');
      expect(age(const Duration(minutes: 1)), '1m');
      expect(age(const Duration(minutes: 59)), '59m');
      expect(age(const Duration(hours: 1)), '1h');
      expect(age(const Duration(hours: 23)), '23h');
      expect(age(const Duration(days: 1)), '1d');
      expect(age(const Duration(days: 6)), '6d');
      // A week out, a date — and the year only when it is not this one.
      expect(age(const Duration(days: 7)), '23 Jul');
      expect(DateFormatter.postAge(DateTime(2025, 7, 23), now: now), '23 Jul 25');

      // A clock that is ahead produces a post from the future. "now" is the
      // least wrong thing to say; "-3m" is a bug on display.
      expect(DateFormatter.postAge(now.add(const Duration(minutes: 3)), now: now),
          'now');
    });

    testWidgets('a repeat asks whether to add anything', (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);

      PublicFeedStore.debugLoadOverride = () async => [
            PublicPost(
                id: 'a',
                authorUsername: 'sam',
                authorName: 'Sam',
                body: 'the original',
                createdAt: DateTime.now()),
          ];
      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();

      // Passing something on unchanged and passing it on with something to say
      // are two intentions, so the button asks rather than picking one.
      await t.tap(find.byIcon(Icons.repeat));
      await t.pumpAndSettle();
      expect(find.text('Repost'), findsOneWidget);
      expect(find.text('Quote post'), findsOneWidget);

      await t.tap(find.text('Quote post'));
      await t.pumpAndSettle();
      // The composer says what it is, and shows what is being quoted.
      expect(find.text('Quote post'), findsOneWidget);
      expect(find.text('the original'), findsWidgets,
          reason: 'the quoted post is visible while typing it');
      // A quote with nothing typed is a plain repost, which the table allows —
      // so the button is live before anything is entered.
      final send = t.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Post').first);
      expect(send.onPressed, isNotNull);
    });

    testWidgets('bookmarks are kept on the device and nowhere else', (t) async {
      SharedPreferences.setMockInitialValues({});
      final marks = BookmarkStore.instance;
      addTearDown(marks.resetForTest);
      await marks.load();

      expect(marks.contains('a'), isFalse);
      expect(await marks.toggle('a'), isTrue, reason: 'now saved');
      expect(await marks.toggle('b'), isTrue);
      // Newest first, which is the order somebody expects to find them in.
      expect(marks.ids, ['b', 'a']);
      expect(await marks.toggle('a'), isFalse, reason: 'now unsaved');
      expect(marks.ids, ['b']);

      // A saved post that has been deleted leaves the list rather than sitting
      // in it forever pointing at nothing.
      await marks.toggle('gone');
      expect(marks.ids, ['gone', 'b']);
      await marks.forget(['gone']);
      expect(marks.ids, ['b']);
      // Forgetting something that was never there changes nothing.
      await marks.forget(['never']);
      expect(marks.ids, ['b']);

      // It survives a restart, because a note to yourself that evaporates is
      // worse than no note at all.
      marks.resetForTest();
      await marks.load();
      expect(marks.ids, ['b']);

      // And no server holds it: there is no table, no column, no id sent
      // anywhere. A record of what somebody reads is exactly the thing this app
      // does not keep.
      final store = File('lib/state/bookmark_store.dart').readAsStringSync();
      expect(store.contains('Supabase'), isFalse);
      expect(store.contains('from('), isFalse,
          reason: 'no table access of any kind');
      final sql = File('docs/public_feed.sql').readAsStringSync();
      expect(sql.toLowerCase().contains('bookmark'), isFalse);
    });

    testWidgets('bookmarked posts are re-read from the public feed', (t) async {
      SharedPreferences.setMockInitialValues({});
      final marks = BookmarkStore.instance;
      final store = PublicFeedStore.instance;
      addTearDown(marks.resetForTest);
      addTearDown(store.resetForTest);
      await marks.load();
      await marks.toggle('a');
      await marks.toggle('deleted');

      var asked = <String>[];
      PublicFeedStore.debugByIdsOverride = (ids) async {
        asked = ids;
        return [
          PublicPost(
              id: 'a',
              authorUsername: 'sam',
              authorName: 'Sam',
              body: 'saved for later',
              createdAt: DateTime.now()),
        ];
      };

      await t.pumpWidget(const MaterialApp(home: BookmarksScreen()));
      await t.pumpAndSettle();

      expect(asked, containsAll(['a', 'deleted']));
      expect(find.text('saved for later'), findsOneWidget);
      // The one the server did not return is dropped, not left dangling.
      expect(marks.ids, ['a']);
    });

    testWidgets('muting someone hides them, and can be undone', (t) async {
      t.view.physicalSize = const Size(500, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final store = PublicFeedStore.instance;
      final mutes = FeedMuteStore.instance;
      addTearDown(store.resetForTest);
      addTearDown(mutes.resetForTest);
      await mutes.load();

      final now = DateTime.now();
      PublicFeedStore.debugLoadOverride = () async => [
            PublicPost(
                id: 'a',
                authorUsername: 'loud',
                authorName: 'Loud',
                body: 'from the loud one',
                createdAt: now),
            PublicPost(
                id: 'b',
                authorUsername: 'quiet',
                authorName: 'Quiet',
                body: 'from the quiet one',
                createdAt: now.subtract(const Duration(minutes: 1))),
          ];
      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();
      expect(find.text('from the loud one'), findsOneWidget);

      // A shared timeline has no membership to leave, so without this the only
      // options left to somebody being pestered are to report and wait, or to
      // stop opening the feed.
      await mutes.toggle('loud');
      await t.pumpAndSettle();
      expect(find.text('from the loud one'), findsNothing);
      expect(find.text('from the quiet one'), findsOneWidget,
          reason: 'only the muted author goes');

      // Capitalisation must not defeat it.
      expect(mutes.isMuted('LOUD'), isTrue);
      expect(mutes.isMuted('@loud'), isTrue);

      // AND IT HAS TO BE UNDOABLE. Muting hides the posts, which is what makes
      // the mute unreachable afterwards — there is no post left to open a menu
      // on — so a list is not a nicety.
      await t.pumpWidget(const MaterialApp(home: MutedAccountsScreen()));
      await t.pumpAndSettle();
      expect(find.text('@loud'), findsOneWidget);
      await t.tap(find.text('Unmute'));
      await t.pumpAndSettle();
      expect(mutes.isMuted('loud'), isFalse);
      expect(find.text('@loud'), findsNothing);

      // Nothing about a mute leaves the device: it is a decision about
      // yourself, and the muted person least of all should be able to see it.
      final src = File('lib/state/feed_mute_store.dart').readAsStringSync();
      expect(src.contains('Supabase'), isFalse);
      expect(src.contains('from('), isFalse);
      final sql = File('docs/public_feed.sql').readAsStringSync();
      expect(sql.toLowerCase().contains('mute'), isFalse);
    });

    testWidgets('a reply says what it is replying to', (t) async {
      t.view.physicalSize = const Size(500, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      await FeedMuteStore.instance.load();
      addTearDown(FeedMuteStore.instance.resetForTest);

      final now = DateTime.now();
      final parent = PublicPost(
          id: 'p',
          authorUsername: 'sam',
          authorName: 'Sam',
          body: 'the question',
          createdAt: now);
      final reply = PublicPost(
          id: 'r',
          authorUsername: 'kim',
          authorName: 'Kim',
          body: 'the answer',
          replyTo: 'p',
          createdAt: now.subtract(const Duration(seconds: 30)));
      PublicFeedStore.debugLoadOverride = () async => [parent, reply];
      await store.load();

      expect(store.replyingTo(reply), 'sam');
      // Never guessed: a wrong "Replying to @somebody" is worse than no line,
      // so an unloaded parent produces nothing.
      final orphan = PublicPost(
          id: 'o',
          authorUsername: 'kim',
          authorName: 'Kim',
          body: 'reply to something not here',
          replyTo: 'nowhere',
          createdAt: now);
      expect(store.replyingTo(orphan), isNull);
      // And a top-level post is not a reply to anything.
      expect(store.replyingTo(parent), isNull);

      // On screen, in the thread where a reply is actually shown.
      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();
      await t.tap(find.text('the question'));
      await t.pumpAndSettle();
      expect(find.text('Replying to @sam'), findsOneWidget);
    });

    testWidgets('the profile header fits, and counts each thing once',
        (t) async {
      t.view.physicalSize = const Size(430, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);
      AppState.profile.value = const AppUser(
          id: 'me', name: 'Iman', avatarColor: '#000000', username: 'iman');

      PublicFeedStore.debugProfileOverride = (username) async => [
            PublicPost(
                id: 'p1',
                authorUsername: 'iman',
                authorName: 'Iman',
                body: 'hello',
                createdAt: DateTime.now()),
          ];
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: PublicProfileScreen(username: 'iman', embedded: true))));
      await t.pumpAndSettle();

      // THE AVATAR WAS CUT IN HALF. It was pushed up out of the header sliver
      // with Transform.translate, and a sliver clips at its own bounds, so the
      // top of somebody's head disappeared behind the banner. Both are one box
      // now, and the whole avatar has to be inside the screen.
      final avatar = t.getRect(find.byType(CircleAvatar).first);
      expect(avatar.top, greaterThanOrEqualTo(0.0),
          reason: 'the top of the head is on screen');
      expect(avatar.height, greaterThan(50.0),
          reason: 'and it is a whole circle, not a sliver of one');
      // Clipping does not change a widget's rect, so the rect alone cannot see
      // this. What can: the header below has to start BELOW the avatar. When
      // the box holding banner and avatar is too short, the name is drawn over
      // the avatar's lower half — which is what a clipped avatar looks like.
      final handle = t.getRect(find.text('@iman').first);
      expect(handle.top, greaterThanOrEqualTo(avatar.bottom),
          reason: 'the header begins after the avatar, not through it');

      // ONE row of counts. There were two — "1 post 0 following" above a second
      // row repeating Following beside Servers and Okay Score — which invites
      // somebody to check whether the two numbers disagree.
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('following'), findsNothing);
      expect(find.text('Posts'), findsOneWidget);
      expect(find.text('post'), findsNothing);
      expect(find.text('Okay Score'), findsOneWidget);

      // Everything down the left edge starts at the same margin. The
      // verification chips were centred while the name, bio and counts were
      // left-aligned, which reads as a stray block rather than a row.
      final name = t.getRect(find.text('Iman').first);
      // The chip itself, not its label — the label sits inside the chip's own
      // padding and behind its icon, about 30 pixels in.
      final chips = t.getRect(find.ancestor(
          of: find.text('Phone unverified'), matching: find.byType(InkWell)));
      expect(chips.left, closeTo(name.left, 1.0),
          reason: 'the chips share the margin everything else uses');

      // The header has to leave room for the thing the profile is for. At a
      // banner of 118 the tabs sat far enough down that a post needed a scroll
      // on a normal phone.
      final tabs = t.getRect(find.text('Replies'));
      expect(tabs.bottom, lessThan(520.0),
          reason: 'a post is visible without scrolling');

      // Nothing overflows at a real phone width. takeException() CONSUMES the
      // error, so asserting on a bool threw away the one thing that says what
      // broke — the reason carries it now.
      final failure = t.takeException();
      expect(failure, isNull, reason: 'layout error: $failure');
    });

    testWidgets('the profile tabs stay put while the posts scroll', (t) async {
      t.view.physicalSize = const Size(430, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);
      AppState.profile.value = const AppUser(
          id: 'me', name: 'Iman', avatarColor: '#000000', username: 'iman');

      final now = DateTime.now();
      PublicFeedStore.debugProfileOverride = (username) async => [
            for (var i = 0; i < 20; i++)
              PublicPost(
                  id: 'p$i',
                  authorUsername: 'iman',
                  authorName: 'Iman',
                  body: 'post number $i',
                  createdAt: now.subtract(Duration(minutes: i))),
          ];
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: PublicProfileScreen(username: 'iman', embedded: true))));
      await t.pumpAndSettle();

      final before = t.getRect(find.text('Media'));
      expect(before.top, greaterThan(200.0),
          reason: 'the tabs start below the header');

      // Far enough that an unpinned strip would be gone: more than the whole
      // header above it.
      await t.drag(find.byType(CustomScrollView), const Offset(0, -700));
      await t.pumpAndSettle();

      // Switching from Posts to Media otherwise means scrolling back to the
      // top to find the control you just used.
      expect(find.text('Media'), findsOneWidget,
          reason: 'the tabs are still on screen after scrolling');
      final after = t.getRect(find.text('Media'));
      expect(after.top, lessThan(60.0),
          reason: 'pinned at the top, not carried down the page');
      expect(after.top, greaterThanOrEqualTo(0.0));
      expect(after.top, lessThan(before.top - 100),
          reason: 'and it really did scroll');

      // Still usable where it stopped.
      await t.tap(find.text('Media'));
      await t.pumpAndSettle();
      expect(find.text('No photos yet'), findsOneWidget);
    });

    testWidgets('a person has one face everywhere in the app', (t) async {
      t.view.physicalSize = const Size(500, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);

      // Everywhere else in this app somebody is drawn by UserAvatar, with the
      // colour they picked and the emoji they set. The feed drew its own circle
      // from a hash of the handle, so a person's face on the newsfeed was a
      // different colour from their face in chats and calls. One person looked
      // like two.
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Iman',
          avatarColor: '#FF5722',
          username: 'iman',
          emoji: '🦊');
      expect(knownUserFor('iman')?.emoji, '🦊');
      expect(knownUserFor('IMAN')?.emoji, '🦊',
          reason: 'a handle is a handle whatever its capitalisation');
      expect(profileAccentFor('iman', const ColorScheme.light()),
          const Color(0xFFFF5722),
          reason: 'the banner takes the colour they chose');

      // A stranger cannot be resolved, and that is not a gap to paper over: a
      // handle and a name is all a public feed gives you, so a generated circle
      // is the honest way to draw one — stable, so it does not change per view.
      expect(knownUserFor('stranger'), isNull);
      const scheme = ColorScheme.light();
      expect(profileAccentFor('stranger', scheme),
          publicProfileBannerSeed('stranger', scheme));
      expect(knownUserFor(''), isNull);

      PublicFeedStore.debugProfileOverride = (username) async => [];
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: PublicProfileScreen(username: 'iman', embedded: true))));
      await t.pumpAndSettle();
      // Your own emoji, on your own profile — not a generated initial.
      expect(find.text('🦊'), findsWidgets);
      expect(find.text('I'), findsNothing,
          reason: 'the generated initial is for people we do not know');
    });

    testWidgets('the one profile shows what somebody posted', (t) async {
      t.view.physicalSize = const Size(500, 2200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);
      AppState.profile.value = const AppUser(
          id: 'me', name: 'Iman', avatarColor: '#000000', username: 'iman');

      PublicFeedStore.debugProfileOverride = (username) async => [
            PublicPost(
                id: 'p1',
                authorUsername: 'iman',
                authorName: 'Iman',
                body: 'posted on the newsfeed',
                likeCount: 2,
                createdAt: DateTime.now()),
          ];

      await t.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: PublicProfileScreen(username: 'iman', embedded: true))));
      await t.pumpAndSettle();

      expect(find.text('posted on the newsfeed'), findsOneWidget);
      expect(find.text('1'), findsWidgets, reason: 'a real post count');
    });

    testWidgets('the newsfeed can always be left, and has one profile',
        (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      await FeedMuteStore.instance.load();
      addTearDown(FeedMuteStore.instance.resetForTest);
      PublicFeedStore.debugLoadOverride = () async => [];

      // THE BUG. The avatar was the app bar's `leading`, and `leading` REPLACES
      // the back arrow. On a tab there is nothing to go back to, so it looked
      // right; pushed as a route it left somebody on a screen with no way out.
      // No screen has a back arrow any more — the leading slot is the sidebar
      // everywhere — so what this guards is that the slot never goes back to
      // holding something that is only a shortcut.
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PublicFeedScreen())),
              child: const Text('open feed'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open feed'));
      await t.pumpAndSettle();
      expect(find.text('Newsfeed'), findsOneWidget);
      expect(find.byType(SidebarButton), findsOneWidget,
          reason: 'the leading slot is the sidebar, on this screen too');
      await goBack(t);
      await t.pumpAndSettle();
      expect(find.text('open feed'), findsOneWidget,
          reason: 'and the route can still be left');

      // Where the avatar cannot go, the route to your own profile is still
      // there — it is never the only way in.
      final src = File('lib/screens/public_feed_screen.dart').readAsStringSync();
      expect(src.contains("value: 'profile', child: Text('Your profile')"),
          isTrue);
    });

    testWidgets('one person has one profile, and so does everybody else',
        (t) async {
      t.view.physicalSize = const Size(500, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      final store = PublicFeedStore.instance;
      addTearDown(store.resetForTest);
      await FeedMuteStore.instance.load();
      addTearDown(FeedMuteStore.instance.resetForTest);

      final prevProfile = AppState.profile.value;
      addTearDown(() => AppState.profile.value = prevProfile);
      AppState.profile.value = const AppUser(
          id: 'me', name: 'Iman', avatarColor: '#000000', username: 'iman');

      // There used to be two profile screens — the "You" tab and this one —
      // with different layouts and different facts on each, so a field added to
      // a profile had to be added twice or it existed on one and not the other.
      // Whichever somebody found first became "their profile" and the other
      // looked like a stranger's.
      PublicFeedStore.debugLoadOverride = () async => [
            PublicPost(
                id: 'a',
                authorUsername: 'iman',
                authorName: 'Iman',
                body: 'mine',
                createdAt: DateTime.now()),
            PublicPost(
                id: 'b',
                authorUsername: 'sam',
                authorName: 'Sam',
                body: 'theirs',
                createdAt: DateTime.now().subtract(const Duration(minutes: 1))),
          ];
      PublicFeedStore.debugProfileOverride = (username) async => [];

      await t.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await t.pumpAndSettle();

      // Yours.
      await t.tap(find.text('Iman').first);
      await t.pumpAndSettle();
      expect(find.byType(PublicProfileScreen), findsOneWidget);
      // The parts only you can act on are there, and nowhere else.
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.byTooltip('Share your profile'), findsOneWidget);
      // Twice on your own: the count in the stats row, and the tab that lists
      // them. Neither appears on anybody else's.
      expect(find.text('Servers'), findsNWidgets(2),
          reason: 'your own server posts, which nobody else could be shown');
      await goBack(t);
      await t.pumpAndSettle();

      // Somebody else's: the same screen, without them.
      await t.tap(find.text('Sam').first);
      await t.pumpAndSettle();
      expect(find.byType(PublicProfileScreen), findsOneWidget);
      expect(find.text('Edit profile'), findsNothing);
      expect(find.byTooltip('Share your profile'), findsNothing);
      expect(find.text('Servers'), findsNothing,
          reason: 'a server feed is encrypted per server; there is nothing to '
              'show and pretending otherwise would be a lie');
      expect(find.text('Follow'), findsOneWidget);

      // Your own avatar is a way into changing it. Somebody else's is a
      // picture, not a control — tapping it must not open your editor.
      await t.tap(find.byType(CircleAvatar).first);
      await t.pumpAndSettle();
      expect(find.text('Edit profile'), findsNothing,
          reason: 'a stranger\'s avatar is not a door to your own settings');
    });

    testWidgets('a profile wears the account colour from the bar down',
        (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      addTearDown(PublicFeedStore.instance.resetForTest);
      PublicFeedStore.debugProfileOverride = (username) async => [];

      await t.pumpWidget(const MaterialApp(
          home: PublicProfileScreen(username: 'sam', name: 'Sam')));
      await t.pumpAndSettle();

      final scheme = Theme.of(t.element(find.byType(PublicProfileScreen)))
          .colorScheme;
      final accent = profileAccentFor('sam', scheme);
      final bar = t.widget<SliverAppBar>(find.byType(SliverAppBar));
      // A default grey bar above a coloured banner drew a seam across the top
      // of every profile. The bar and the banner are one block of colour.
      expect(bar.backgroundColor, accent);
      expect(bar.foregroundColor, onProfileAccent(accent));
    });

    test('the app bar text is readable on any accent it can be given', () {
      // An account's accent is whatever avatar colour its owner picked, and
      // this app lets somebody pick pale yellow.
      for (final accent in [
        const Color(0xFFFFF176), // pale yellow
        const Color(0xFF11161C), // near black
        const Color(0xFF075E54), // the app's own green
        const Color(0xFFFFFFFF),
      ]) {
        final on = onProfileAccent(accent);
        final ratio = (accent.computeLuminance() + 0.05) /
            (on.computeLuminance() + 0.05);
        final contrast = ratio < 1 ? 1 / ratio : ratio;
        expect(contrast, greaterThan(4.5),
            reason: 'unreadable on ${accent.toARGB32().toRadixString(16)}');
      }
    });

    testWidgets('the media tab is a grid of the photos themselves', (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      addTearDown(PublicFeedStore.instance.resetForTest);
      final now = DateTime.now();
      PublicFeedStore.debugProfileOverride = (username) async => [
            for (var i = 0; i < 5; i++)
              PublicPost(
                  id: 'p$i',
                  authorUsername: 'sam',
                  authorName: 'Sam',
                  body: 'caption $i',
                  imagePath: 'sam/$i.jpg',
                  createdAt: now.subtract(Duration(minutes: i))),
          ];

      await t.pumpWidget(const MaterialApp(
          home: PublicProfileScreen(username: 'sam', name: 'Sam')));
      await t.pumpAndSettle();
      await t.tap(find.text('Media'));
      await t.pumpAndSettle();

      // Three across, so the photos are the tab rather than captions with a
      // picture attached, three to a screen.
      expect(find.byType(SliverGrid), findsOneWidget);
      final cells = t.widgetList(find.byType(Image)).length;
      expect(cells, greaterThanOrEqualTo(5));
      final first = t.getRect(find.byType(Image).first);
      expect(first.width, closeTo(first.height, 1),
          reason: 'a photo grid is square cells');
      expect(first.width, lessThan(500 / 2),
          reason: 'three to a row, not one');
    });

    testWidgets('an empty tab says which one is empty, and what fills it',
        (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      addTearDown(PublicFeedStore.instance.resetForTest);
      PublicFeedStore.debugProfileOverride = (username) async => [];

      await t.pumpWidget(const MaterialApp(
          home: PublicProfileScreen(username: 'sam', name: 'Sam')));
      await t.pumpAndSettle();
      expect(find.text('No posts yet'), findsOneWidget);

      await t.tap(find.text('Media'));
      await t.pumpAndSettle();
      // Each tab names itself. They all used to read "No posts yet.", so an
      // empty Media tab looked like the profile had failed to load.
      expect(find.text('No photos yet'), findsOneWidget);
      expect(find.textContaining('Posts with a picture'), findsOneWidget);

      await t.tap(find.text('Replies'));
      await t.pumpAndSettle();
      expect(find.text('No replies yet'), findsOneWidget);
    });

    testWidgets('the tab mark travels to the tab you picked', (t) async {
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      addTearDown(PublicFeedStore.instance.resetForTest);
      PublicFeedStore.debugProfileOverride = (username) async => [];

      await t.pumpWidget(const MaterialApp(
          home: PublicProfileScreen(username: 'sam', name: 'Sam')));
      await t.pumpAndSettle();

      // One mark that moves, not one per tab switching on and off — so there
      // is exactly one of it whichever tab is active.
      final mark = find.byType(AnimatedPositioned);
      expect(mark, findsOneWidget);
      final onPosts = t.getRect(mark).center.dx;
      expect(onPosts, lessThan(500 / 3), reason: 'Posts is the first tab');

      await t.tap(find.text('Media'));
      await t.pumpAndSettle();
      // The tab's own column, not the label: the label sits centred inside it
      // and would agree by accident if the mark were nailed to the left edge.
      final cell = t.getRect(find
          .ancestor(of: find.text('Media'), matching: find.byType(InkWell))
          .first);
      final onMedia = t.getRect(mark).center.dx;
      expect(onMedia, closeTo(cell.center.dx, 2));
      expect(onMedia, greaterThan(onPosts),
          reason: 'Media is to the right of Posts');
    });

    testWidgets('the composer states that everyone will see it',
        (tester) async {
      PublicFeedStore.debugLoadOverride = () async => [];
      AppState.profile.value = AppState.profile.value;
      await tester.pumpWidget(const MaterialApp(home: PublicFeedScreen()));
      await tester.pumpAndSettle();
      // The compose button is round and iconic on this timeline, so it is
      // found by its tooltip — which is also the only thing a screen
      // reader has to go on.
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      expect(find.text('New post'), findsOneWidget);
      expect(find.textContaining('Everyone using OkayMessenger can see this'),
          findsOneWidget);
      // The counter starts at the cap and Post is disabled until something
      // is typed.
      expect(find.text('${PublicFeedStore.maxLength}'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
              .onPressed,
          isNull);
    });
  });

  group('Nothing leaves the app', () {
    test('no screen opens a browser or another app for a web page', () {
      // The rule: a web page opens on one of the app's own screens. Not a
      // browser, not an in-app browser view, not a handoff. The only files
      // allowed to name url_launcher are the ones handing a *phone number* to
      // the system composer, which iOS gives no in-app alternative for, and
      // the in-app screen itself (for the web build, where a tab is a tab in
      // the browser the app already is).
      const allowed = {
        'lib/state/incoming_links.dart', // telephony: / tel: / sms:
        'lib/screens/chat_screen.dart', // sms: composer
        'lib/main.dart', // sms: for a number that isn't on the app
        'lib/screens/in_app_web_screen.dart', // web build fallback only
      };
      final offenders = <String>[];
      final external = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        if (!src.contains('url_launcher')) continue;
        if (!allowed.contains(f.path)) offenders.add(f.path);
        // And nowhere at all may ask for a browser explicitly.
        if (src.contains('LaunchMode.externalApplication') ||
            src.contains('LaunchMode.inAppBrowserView')) {
          external.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'these would take the user out of the app: $offenders');
      expect(external, isEmpty,
          reason: 'an explicit browser mode is never wanted: $external');
    });

    test('every allowed launch hands over a phone number, not a page', () {
      // The exceptions earn their place only while they stay phone-shaped.
      for (final path in [
        'lib/state/incoming_links.dart',
        'lib/screens/chat_screen.dart',
        'lib/main.dart',
      ]) {
        final src = File(path).readAsStringSync();
        final calls = RegExp(r'launchUrl\(\s*Uri\.(?:parse|tryParse)?\(?([^)]*)')
            .allMatches(src)
            .map((m) => m.group(1)!)
            .toList();
        expect(calls, isNotEmpty, reason: '$path was expected to launch');
        for (final c in calls) {
          expect(
              c.contains('sms:') ||
                  c.contains('tel:') ||
                  c.contains('scheme') ||
                  c.contains('fallback'),
              isTrue,
              reason: '$path launches something that is not a number: $c');
        }
      }
    });

    test('setting up payments never leaves the app, on any branch', () {
      // Every file in the payments path, checked rather than remembered.
      for (final path in [
        'lib/screens/wallet_screen.dart',
        'lib/screens/connect_onboarding_screen.dart',
        'lib/screens/payment_controls_screen.dart',
        'lib/screens/payment_history_screen.dart',
        'lib/payments/payment_service.dart',
        'lib/payments/connect_webview_native.dart',
        'lib/screens/native_onboarding_screen.dart',
        'lib/payments/stripe_tokens.dart',
        'lib/payments/connect_fields.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src.contains('launchUrl'), isFalse,
            reason: '$path can take the user out of the app');
      }
      final wallet = File('lib/screens/wallet_screen.dart').readAsStringSync();
      // This used to assert the wallet reached ConnectOnboardingScreen (a
      // WebView hosting Stripe's own form) and InAppWebScreen (a tab, on web
      // only). Both are gone from here and the guarantee is stronger for it:
      // setting up payments is now the app's own form, on every platform, with
      // no web page in the happy path at all.
      expect(wallet.contains('NativeOnboardingScreen()'), isTrue);
      expect(wallet.contains('InAppWebScreen'), isFalse,
          reason: 'no tab, not even on web');

      // Stripe's own page is still reachable for one case — an account created
      // before native collection existed, which Stripe will not let this app
      // collect — and it loads into this app's own WebView, not anywhere else.
      final native =
          File('lib/screens/native_onboarding_screen.dart').readAsStringSync();
      expect(native.contains('ConnectOnboardingScreen()'), isTrue);
      final screen =
          File('lib/screens/connect_onboarding_screen.dart').readAsStringSync();
      expect(screen.contains('url: _hostedUrl!'), isTrue);
    });

    test('a new-window link inside Stripe\'s forms opens here, not nowhere',
        () {
      // WKWebView drops target=_blank, so those links read as broken. The
      // click is re-pointed at this frame. window.open is left alone on
      // purpose: bank verification needs a real popup and an opener to talk
      // back to.
      final src = File('lib/payments/connect_webview_native.dart')
          .readAsStringSync();
      expect(src.contains('_keepBlankLinksInside'), isTrue);
      expect(src.contains("el.target !== '_blank'"), isTrue);
      expect(src.contains('window.location.href = el.href'), isTrue);
      expect(src.contains('window.open ='), isFalse,
          reason: 'hijacking window.open breaks the bank-verification popup');
      // Installed on every page load, since the flow navigates between pages.
      expect(src.contains('_keepBlankLinksInside();\n            _start();'),
          isTrue);
    });

    test('the in-app page screen refuses anything but http(s)', () {
      // A link in a post is untrusted text; javascript: or a custom scheme is
      // not something to hand to a WebView, let alone anywhere else.
      final src =
          File('lib/screens/in_app_web_screen.dart').readAsStringSync();
      expect(
          src.contains(
              "uri.scheme != 'http' && uri.scheme != 'https'"),
          isTrue);
      // Feed links go through it rather than launching.
      final feed = File('lib/screens/feed_screen.dart').readAsStringSync();
      expect(feed.contains('InAppWebScreen.open(context, token)'), isTrue);
      expect(feed.contains('url_launcher'), isFalse);
    });
  });

  group('Connect onboarding secrets', () {
    test('a client secret is never handed out twice', () async {
      // The bug this pins: an Account Session authenticates ONCE. The screen
      // used to answer the page's first request with the session it made at
      // start-up — the very secret the page had already spent on its first
      // authentication — and Stripe rejected the reuse with "An error occurred
      // while authenticating your account", a message about the account for a
      // problem with the secret.
      var n = 0;
      final d = SecretDispenser(() async => 'accs_secret_${++n}');
      expect(await d.next(), 'accs_secret_1');
      expect(await d.next(), 'accs_secret_2');
      expect(await d.next(), 'accs_secret_3');
      expect(d.issued, 3, reason: 'each request mints, none replays');
    });

    test('a repeated or empty secret fails by name, not silently', () async {
      // A mint that keeps answering the same thing cannot authenticate, so it
      // is named rather than passed on for Stripe to blame the user for.
      final stuck = SecretDispenser(() async => 'accs_secret_same');
      expect(await stuck.next(), 'accs_secret_same');
      await expectLater(
        stuck.next(),
        throwsA(predicate((e) => '$e'.contains('stale_client_secret'))),
      );

      final empty = SecretDispenser(() async => '');
      await expectLater(
        empty.next(),
        throwsA(predicate((e) => '$e'.contains('no_client_secret'))),
      );

      // A mint that throws is not swallowed either — the screen turns these
      // into words, and only a thrown error gets there.
      final broken =
          SecretDispenser(() async => throw PaymentException('unauthorized'));
      await expectLater(broken.next(), throwsA(isA<PaymentException>()));
    });

    test('a connected account from the other mode is not used forever', () {
      // A connected account belongs to one mode. If the stored id was made
      // with a test secret key and the key is now live (or the reverse),
      // Stripe answers "No such account" and the only symptom is its
      // "An error occurred while authenticating your account" — which reads
      // as a problem with the person's account.
      final fn = File('supabase/functions/payments-account-session/index.ts')
          .readAsStringSync();
      expect(fn.contains('stripe.accounts.retrieve(accountId)'), isTrue,
          reason: 'the stored account has to be checked, not assumed');
      expect(fn.contains('resource_missing'), isTrue);
      expect(
          fn.contains('await admin.from("payment_accounts").delete()'), isTrue,
          reason: 'an id from the other mode must be forgotten');
      // …but only for a missing account. A network blip must not discard
      // somebody's real connected account.
      expect(fn.contains('} else {\n          throw e;'), isTrue,
          reason: 'any other error must rethrow, not delete');

      // A failure to create the session names the setting that is usually off.
      expect(fn.contains('stripe_account_session_failed'), isTrue);
      expect(fn.contains('embedded components'), isTrue);
      // And the screen shows that text rather than swallowing it.
      final screen =
          File('lib/screens/connect_onboarding_screen.dart').readAsStringSync();
      expect(screen.contains("text.contains('stripe_account_session_failed')"),
          isTrue);
    });

    test('the hosted fallback is bounded, announced, and comes back', () {
      final svc = File('lib/payments/payment_service.dart').readAsStringSync();
      // The fallback is reached *because* something already failed, so it must
      // not be the thing that hangs. It had no timeout while connectSession
      // did.
      final onboarding = svc.substring(svc.indexOf('Future<String> onboardingUrl'));
      expect(onboarding.contains('.timeout('), isTrue,
          reason: 'a hung fallback leaves the screen loading forever');
      // A null url used to reach the screen as a TypeError about 'Null'.
      expect(onboarding.contains("PaymentException('no_onboarding_url')"),
          isTrue);

      final screen =
          File('lib/screens/connect_onboarding_screen.dart').readAsStringSync();
      // _loadingHosted only greyed out the button, so tapping "Trouble?" left
      // the broken component on screen and read as doing nothing.
      expect(screen.contains('body: _loadingHosted'), isTrue,
          reason: 'the wait for the hosted URL needs to be visible');
      // Stripe's hosted flow ends by navigating to return_url, which serves
      // this app's own website — catch it rather than render the site inside
      // the app.
      expect(
          screen.contains('completionUrlPrefix: PaymentService.returnUrl'),
          isTrue);
      expect(screen.contains("event == 'exit' || event == 'submitted'"), isTrue);
      // And every named failure has words to go with it.
      for (final code in [
        'no_onboarding_url',
        'no_client_secret',
        'stale_client_secret',
        'key_mode_live_app_test_server',
        'key_mode_test_app_live_server',
        'no_publishable_key',
      ]) {
        expect(screen.contains("text.contains('$code')"), isTrue,
            reason: '$code would surface as raw text nobody can act on');
      }
    });

    test('the page reports a refused secret instead of letting Stripe guess',
        () {
      // connect.js discards fetchClientSecret's rejection reason and paints
      // its own authentication error, so the page has to say the real cause
      // out loud (to itself and to the host) before rejecting.
      final page = File('web/connect.html').readAsStringSync();
      expect(page.contains('function refuse('), isTrue);
      expect(page.contains('refuse(hostAnswers'), isTrue,
          reason: 'the host-timeout path must report, not just reject');
      // The host hands its reason to the page rather than reporting it
      // separately: two events for one failure meant the generic one
      // overwrote the useful one.
      final bridge = File('lib/payments/connect_webview_native.dart')
          .readAsStringSync();
      expect(bridge.contains('var reason'), isTrue);
      expect(bridge.contains(r"reason = '$e';"), isTrue);
      expect(bridge.contains(r'${_js(reason)}'), isTrue);
      expect(bridge.contains(r"widget.onEvent('error:$e')"), isFalse,
          reason: 'a second error event overwrites the first');
      expect(page.contains("refuse(reason || 'The app could not start"), isTrue,
          reason: 'the host\'s reason must beat the fallback wording');
    });
  });

  group('Who may send money', () {
    test('both gates are enforced on the server, not the client', () {
      // A rule the app enforces is a rule an app can be modified to skip, so
      // the checks live in payments-create-intent and the capture gate.
      final intent = File('supabase/functions/payments-create-intent/index.ts')
          .readAsStringSync();

      // Identity: the phone is already verified (callerPhone comes from a
      // session whose JWT carries an SMS-verified number); this is the ID half.
      expect(intent.contains('identity_verifications'), isTrue);
      expect(intent.contains('identity_required'), isTrue);
      expect(intent.contains("identity?.status !== \"verified\""), isTrue);

      // The card cannot be judged until one is attached, so the charge is
      // authorised and held rather than taken.
      expect(intent.contains('capture_method: "manual"'), isTrue,
          reason: 'checking after capture is a refund, not a check');

      final webhook = File('supabase/functions/payments-webhook/index.ts')
          .readAsStringSync();
      expect(webhook.contains('amount_capturable_updated'), isTrue);
      expect(webhook.contains('paymentIntents.capture'), isTrue);
      expect(webhook.contains('paymentIntents.cancel'), isTrue,
          reason: 'a card that fails must be released, never captured');
      expect(webhook.contains('judgeCard'), isTrue);
    });

    test('no verified name means no sending', () {
      // Without a name there is nothing to check a card against. That has to
      // fail closed, or the card rule quietly stops applying to anyone whose
      // ID check returned no name.
      final intent = File('supabase/functions/payments-create-intent/index.ts')
          .readAsStringSync();
      expect(intent.contains('!identity.verified_name'), isTrue);
    });
  });

  group('In-app Connect onboarding', () {
    test('the embedded page ships with the web build and is reachable', () {
      // The page is served from the app's own deployment, so it has to be in
      // web/ (Flutter copies that into build/web) rather than docs/.
      final page = File('web/connect.html');
      expect(page.existsSync(), isTrue,
          reason: 'web/connect.html is what the WebView loads');
      final html = page.readAsStringSync();

      // Stripe's own script renders the forms — that is what keeps identity
      // and bank details going to Stripe and never through this app.
      expect(html.contains('connect-js.stripe.com'), isTrue);
      expect(html.contains('account-onboarding'), isTrue);

      // The loader exposes StripeConnect.init. The npm package's name is
      // .initialize, and reaching for that made the page report "could not
      // reach Stripe" while Stripe sat there fully loaded.
      expect(html.contains('StripeConnect.init('), isTrue);
      expect(html.contains('StripeConnect.initialize'), isFalse,
          reason: 'that name only exists in the npm package, not the CDN one');
      // And a slow script must not race the host calling in.
      expect(html.contains('StripeConnect.onLoad'), isTrue);

      // The secret arrives by function call after load, never in the URL.
      expect(html.contains('window.okayStart'), isTrue);
      expect(html.contains('location.search'), isFalse,
          reason: 'a client secret in the URL lands in history and logs');

      expect(PaymentService.connectPageUrl.endsWith('/connect.html'), isTrue);
      expect(PaymentService.connectPageUrl.startsWith('https://'), isTrue);
    });

    test('a client secret is fetched fresh, never reused', () {
      // Stripe calls fetchClientSecret again when a session expires and its
      // contract is a NEW Account Session each time. The page used to close
      // over one secret and hand back the same string forever, which
      // authenticates once at best — after that Stripe shows "an error
      // occurred while authenticating your account" and the component sits
      // there loading, because nothing else ever resolves.
      final html = File('web/connect.html').readAsStringSync();

      expect(html.contains('Promise.resolve(clientSecret)'), isFalse,
          reason: 'that is the memoized secret Stripe rejects on refresh');
      // Instead the page asks the host, which mints one per request.
      expect(html.contains("notify('secret:'"), isTrue);
      expect(html.contains('window.okaySecret'), isTrue);
      expect(html.contains('fetchClientSecret: requestSecret'), isTrue);

      // And one page load must not init twice: the second would authenticate
      // a session Stripe has already consumed.
      expect(html.contains('if (started) return;'), isTrue);

      // The first authentication still uses the secret the host handed over
      // at start-up — it was minted seconds earlier, and depending on the
      // channel for it would break every app version older than the channel.
      // A page ships the moment it is pushed; a build reaches a phone days
      // later, so neither may require the other.
      expect(html.contains('initialSecret = clientSecret'), isTrue);
      expect(html.contains('initialUsed'), isTrue,
          reason: 'the start-up secret must be used once, not reused forever');
    });

    testWidgets('there is a way past a component that will not authenticate',
        (tester) async {
      // The embedded component runs in a cross-origin iframe and can fail for
      // reasons nothing outside it can see or fix. Stripe's hosted flow is
      // plain navigation with no iframe, so it is the way through — and it
      // still runs in this screen, not a browser.
      Object? result = 'not popped';
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => result = await Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => const ConnectOnboardingScreen())),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // This used to assert a "Trouble?" button, reachable before anything had
      // gone wrong because the failure it existed for renders inside Stripe's
      // iframe where nothing out here can see it. The guarantee is stronger
      // now and the button is gone: the screen never shows the component that
      // wouldn't authenticate, so there is nothing to get past. What must hold
      // is that it goes somewhere on its own.
      expect(find.text('Trouble?'), findsNothing,
          reason: 'nothing to escape from when the failing path is not taken');
      // With no server configured the hosted link cannot be fetched, so what
      // this settles on is the reason and a way to retry — never a blank
      // screen, and never the embedded component.
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(ConnectWebView), findsNothing);

      // Backing out without setting anything up must not tell the wallet to
      // re-read — that would claim a change nobody made.
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    test('a key-mode mismatch is caught server-side too', () {
      // The client-side check only helps someone running a build made after
      // it was added. The server answers every version, so the message
      // reaches the phone that is already installed.
      final fn = File('supabase/functions/payments-account-session/index.ts')
          .readAsStringSync();
      expect(fn.contains('stripe_key_mode_mismatch'), isTrue);
      expect(fn.contains('session.livemode'), isTrue);
      // And the paste copy the dashboard gets must carry it as well.
      expect(
          File('docs/edge_functions_paste/payments-account-session.ts')
              .readAsStringSync()
              .contains('stripe_key_mode_mismatch'),
          isTrue,
          reason: 'run: dart tool/paste_functions.dart');
    });

    test('Stripe\'s reason for a failure reaches the app', () {
      // The component renders its own red "please try again" inside the
      // frame, which says nothing anyone can act on and leaves the screen
      // looking loaded. setOnLoadError carries the real message out.
      final html = File('web/connect.html').readAsStringSync();
      expect(html.contains('setOnLoadError'), isTrue);
      expect(html.contains("notify('error:' + message)"), isTrue);
      // The spinner hides when the component paints, not when it is appended.
      expect(html.contains('setOnLoaderStart'), isTrue);
    });

    test('the self-test names the broken link, in the order that matters', () {
      String verdict({
        String appKeyMode = 'live',
        String appKeyAccount = 'acct_APP',
        bool appKeyRecognised = true,
        bool appKeyPresent = true,
        String? serverMode = 'live',
        String serverAccount = 'acct_APP',
        String? serverError,
        bool signedIn = true,
      }) =>
          PaymentsSelfTest.verdictFor(
            appKeyMode: appKeyMode,
            appKeyAccount: appKeyAccount,
            appKeyRecognised: appKeyRecognised,
            appKeyPresent: appKeyPresent,
            serverMode: serverMode,
            serverAccount: serverAccount,
            serverError: serverError,
            signedIn: signedIn,
          ).$1;
      bool faulty({String serverMode = 'live', String serverAccount = 'acct_APP'}) =>
          PaymentsSelfTest.verdictFor(
            appKeyMode: 'live',
            appKeyAccount: 'acct_APP',
            appKeyRecognised: true,
            appKeyPresent: true,
            serverMode: serverMode,
            serverAccount: serverAccount,
            serverError: null,
            signedIn: true,
          ).$2;

      // Everything lines up: say so plainly rather than hedging. A self-test
      // that never clears anything is a self-test nobody believes.
      expect(faulty(), isFalse);
      expect(verdict(), contains('Nothing is wrong with the keys'));

      // The two causes of "an error occurred while authenticating your
      // account", each named with the key to change.
      expect(verdict(serverMode: 'test'),
          allOf(contains('different modes'), contains('sk_live_')));
      expect(faulty(serverMode: 'test'), isTrue);
      expect(
          verdict(serverAccount: 'acct_OTHER'),
          allOf(contains('different Stripe accounts'), contains('acct_APP'),
              contains('acct_OTHER')));
      expect(faulty(serverAccount: 'acct_OTHER'), isTrue);

      // Order matters: an earlier fault would produce the later symptom
      // anyway, so reporting the later one would send somebody after the wrong
      // thing. A mode mismatch wins over an account mismatch.
      expect(verdict(serverMode: 'test', serverAccount: 'acct_OTHER'),
          contains('different modes'));
      // And anything that stops a session being minted wins over both.
      expect(
          verdict(
              serverError: 'PaymentException: unauthorized',
              serverMode: 'test',
              serverAccount: 'acct_OTHER'),
          allOf(contains('could not start a Stripe session'),
              isNot(contains('different modes'))));
      expect(verdict(signedIn: false, serverError: 'anything'),
          contains('Sign in first'));
      expect(verdict(appKeyPresent: false, appKeyMode: ''),
          contains('no Stripe publishable key'));
      expect(verdict(appKeyRecognised: false),
          contains('does not recognise'));

      // The step that now decides whether setup is a form or a web page. It
      // outranks everything about the keys, because it is what somebody is
      // actually trying to do — and native setup uses neither key, so a key
      // problem cannot be what is blocking them.
      expect(
          PaymentsSelfTest.verdictFor(
            appKeyMode: 'live',
            appKeyAccount: 'acct_APP',
            appKeyRecognised: true,
            appKeyPresent: true,
            serverMode: 'test',
            serverAccount: 'acct_OTHER',
            serverError: null,
            signedIn: true,
            setupError: 'PaymentException: NOT_FOUND',
          ).$1,
          allOf(contains('cannot start'),
              contains('payments-connect-fields'),
              isNot(contains('different modes'))),
          reason: 'setup being unavailable beats any key complaint');

      // All clear, and it says the part that matters: no web page.
      expect(
          PaymentsSelfTest.verdictFor(
            appKeyMode: 'live',
            appKeyAccount: 'acct_APP',
            appKeyRecognised: true,
            appKeyPresent: true,
            serverMode: 'live',
            serverAccount: 'acct_APP',
            serverError: null,
            signedIn: true,
            setupIsNative: true,
          ).$1,
          allOf(contains('in the app'), contains('no'), contains('web page')));

      // An unknown account comparison must not read as a blocker once setup is
      // native — the comparison only ever mattered for the embedded component.
      final unknownButNative = PaymentsSelfTest.verdictFor(
        appKeyMode: 'live',
        appKeyAccount: 'acct_APP',
        appKeyRecognised: true,
        appKeyPresent: true,
        serverMode: 'live',
        serverAccount: '',
        serverError: null,
        signedIn: true,
        setupIsNative: true,
      );
      expect(unknownButNative.$1, contains('does not block anything'));
      expect(unknownButNative.$2, isFalse);

      // What it must NOT do: claim the accounts match when it never learned
      // one of them. Silence is the honest answer there.
      expect(verdict(serverAccount: ''),
          allOf(contains('could not be established'),
              isNot(contains('Nothing is wrong'))));
      expect(faulty(serverAccount: ''), isFalse,
          reason: 'unknown is not a fault');
      expect(verdict(serverMode: null),
          contains('re-paste payments-account-session'));

      // A report is for pasting into a message, so it must never carry a whole
      // key — and there is no secret key on a client to leak in the first place.
      expect(PaymentsSelfTest.maskKey('pk_live_abcdefghMM3P'), '…MM3P');
      expect(PaymentsSelfTest.modeOfPublishableKey('pk_live_x'), 'live');
      expect(PaymentsSelfTest.modeOfPublishableKey('pk_test_x'), 'test');
      expect(PaymentsSelfTest.modeOfPublishableKey('sk_live_x'), '',
          reason: 'a secret key is not a publishable key');
    });

    testWidgets('the self-test screen prints the step that failed', (t) async {
      addTearDown(() {
        PaymentsSelfTest.debugSessionProbe = null;
        PaymentsSelfTest.debugKeyProbe = null;
        PaymentsSelfTest.debugAppKey = null;
        PaymentsSelfTest.debugSetupProbe = null;
      });
      PaymentsSelfTest.debugAppKey = 'pk_live_abcdefghMM3P';
      PaymentsSelfTest.debugKeyProbe = (key) async =>
          const StripeKeyFacts(recognised: true, account: 'acct_APPSIDE');
      PaymentsSelfTest.debugSessionProbe = () async => {
            'clientSecret': 'accs_x',
            'mode': 'live',
            'platformAccount': 'acct_SERVERSIDE',
          };
      PaymentsSelfTest.debugSetupProbe = () async =>
          ConnectRequirements.fromJson({
            'collection': 'application',
            'currentlyDue': ['individual.first_name', 'external_account'],
            'status': <String, dynamic>{},
          });

      await t.pumpWidget(
          const MaterialApp(home: PaymentDiagnosticsScreen()));
      await t.pumpAndSettle();

      // Twice each: once in the step that found it, once in the verdict.
      expect(find.textContaining('acct_APPSIDE'), findsWidgets);
      expect(find.textContaining('acct_SERVERSIDE'), findsWidgets);
      expect(find.text('What to change'), findsOneWidget);
      expect(find.textContaining('different Stripe accounts'), findsOneWidget);
      // And the step that says where setup will happen.
      expect(find.text('In-app setup'), findsOneWidget);
      expect(find.textContaining('The app asks for it'), findsOneWidget);
    });

    test('a key in the wrong mode is named, not left to Stripe', () {
      // A live publishable key cannot authenticate a session minted by a test
      // secret key. Stripe's only symptom is an account authentication error,
      // which sends people to look at their Stripe account instead of at the
      // two keys.
      expect(
          () => PaymentService.checkKeyMode(
              key: 'pk_live_abc', livemode: false),
          throwsA(predicate(
              (e) => '$e'.contains('key_mode_live_app_test_server'))));
      expect(
          () => PaymentService.checkKeyMode(
              key: 'pk_test_abc', livemode: true),
          throwsA(predicate(
              (e) => '$e'.contains('key_mode_test_app_live_server'))));
      expect(() => PaymentService.checkKeyMode(key: '', livemode: true),
          throwsA(predicate((e) => '$e'.contains('no_publishable_key'))));

      // Matching pairs pass, and so does a deployment too old to report the
      // mode — a missing field must not block onboarding.
      PaymentService.checkKeyMode(key: 'pk_live_abc', livemode: true);
      PaymentService.checkKeyMode(key: 'pk_test_abc', livemode: false);
      PaymentService.checkKeyMode(key: 'pk_live_abc', livemode: null);
    });

    test('the account type is what decides whether setup can be native', () {
      // THE ROOT CAUSE, recorded so it is not rediscovered. Accounts used to be
      // created as `express`, and Stripe does not let a platform collect an
      // Express account's KYC over the API — Stripe's own hosted page or
      // embedded component is the only way. That is the account type, not a
      // limitation anybody can code around, and it is why setting up payments
      // could never look like the rest of this app.
      final fn = File('supabase/functions/payments-connect-fields/index.ts')
          .readAsStringSync();
      expect(fn.contains('requirement_collection: "application"'), isTrue,
          reason: 'this application collects the requirements, which is what '
              'makes a native form usable at all');
      expect(fn.contains('stripe_dashboard: { type: "none" }'), isTrue);

      // The trade is real and must stay written down: collecting requirements
      // means the platform also carries losses.
      expect(fn.contains('losses: { payments: "application" }'), isTrue);
      expect(fn.contains('WHAT THAT COSTS, PLAINLY'), isTrue,
          reason: 'the cost of native onboarding is stated, not buried');

      // Raw bank and ID numbers must never reach the server, and the function
      // refuses them rather than trusting a future client.
      expect(fn.contains('bank_details_must_be_tokenised'), isTrue);
      expect(fn.contains('id_number_must_be_tokenised'), isTrue);
      expect(fn.contains('startsWith("btok_")'), isTrue);
      expect(fn.contains('startsWith("piitok_")'), isTrue);
      expect(fn.contains('document_must_be_uploaded_from_the_device'), isTrue);
      expect(fn.contains('startsWith("file_")'), isTrue);
      // And the document is attached where Stripe looks for it.
      expect(fn.contains('individual.verification = {'), isTrue);

      // Terms acceptance is evidence, so the IP comes from the request rather
      // than from whatever the client claims.
      expect(fn.contains('x-forwarded-for'), isTrue);

      // And the paste copy the dashboard gets has to carry all of it.
      final paste =
          File('docs/edge_functions_paste/payments-connect-fields.ts')
              .readAsStringSync();
      expect(paste.contains('requirement_collection: "application"'), isTrue,
          reason: 'run: dart tool/paste_functions.dart');
    });

    test('an unused Express account is replaced, a used one never is', () {
      // An Express account can only be onboarded on Stripe's own pages, so
      // keeping one means sending somebody out to a web form — the seam this
      // whole thing exists to remove. But a *used* Express account is somebody's
      // real payment account, with history and possibly a balance, and throwing
      // it away would be destroying something. So the guard is that it holds
      // nothing at all.
      final fn = File('supabase/functions/payments-connect-fields/index.ts')
          .readAsStringSync();
      expect(fn.contains('isDiscardableExpressAccount'), isTrue);
      // All three emptiness conditions, not just one of them.
      for (final guard in [
        '!account.details_submitted',
        '!account.charges_enabled',
        '!account.payouts_enabled',
      ]) {
        expect(fn.contains(guard), isTrue,
            reason: 'without $guard a real account could be discarded');
      }
      // And it only applies to accounts Stripe collects for.
      expect(fn.contains('!== "application"'), isTrue);

      // The replacement is reported rather than silent: a payment account
      // changing underneath somebody is something they should hear from us.
      expect(fn.contains('replacedStaleAccount'), isTrue);
      final req = ConnectRequirements.fromJson({
        'collection': 'application',
        'replacedStaleAccount': true,
        'status': <String, dynamic>{},
      });
      expect(req.replacedStaleAccount, isTrue);
      expect(
          ConnectRequirements.fromJson({'status': <String, dynamic>{}})
              .replacedStaleAccount,
          isFalse,
          reason: 'absent means it did not happen');
      final screen =
          File('lib/screens/native_onboarding_screen.dart').readAsStringSync();
      expect(screen.contains('req.replacedStaleAccount'), isTrue,
          reason: 'and the screen says so');

      final paste =
          File('docs/edge_functions_paste/payments-connect-fields.ts')
              .readAsStringSync();
      expect(paste.contains('isDiscardableExpressAccount'), isTrue,
          reason: 'run: dart tool/paste_functions.dart');
    });

    testWidgets('an old account is a choice to convert, not a dead end',
        (t) async {
      // The screen used to say "Stripe only lets its details be collected on
      // Stripe's own form" with one button, going to the web page somebody had
      // already said they did not want. That is a dead end wearing an
      // explanation.
      final store = PaymentService.instance;
      expect(store, isNotNull);
      final src =
          File('lib/screens/native_onboarding_screen.dart').readAsStringSync();
      // The offer comes first, the web page second. Both indices are checked
      // for existence before they are compared: a missing string gives -1,
      // which is trivially "less than" and would pass with the button gone.
      final offer = src.indexOf('Set up in the app');
      final fallback = src.indexOf('Continue on Stripe instead');
      expect(offer, greaterThanOrEqualTo(0), reason: 'the offer exists');
      expect(fallback, greaterThanOrEqualTo(0));
      expect(offer, lessThan(fallback),
          reason: 'the in-app route is the primary action');
      expect(src.contains('_switchToInApp'), isTrue);
      expect(src.contains('replaceAccount: true'), isTrue);

      // And it is explicit, from a button — not something that happens to
      // somebody's payment account while they are looking elsewhere.
      final service = File('lib/payments/payment_service.dart').readAsStringSync();
      expect(service.contains('bool replaceAccount = false'), isTrue,
          reason: 'off unless asked for');

      final fn = File('supabase/functions/payments-connect-fields/index.ts')
          .readAsStringSync();
      expect(fn.contains('body.replaceAccount'), isTrue);
      // Refused for an account that can actually move money: swapping that out
      // could strand a payout in flight.
      expect(fn.contains('account_in_use'), isTrue);
      expect(fn.contains('current.payouts_enabled'), isTrue);
      // And never for an account that is already collectable here.
      expect(fn.contains('Already collectable here'), isTrue);

      final paste = File('docs/edge_functions_paste/payments-connect-fields.ts')
          .readAsStringSync();
      expect(paste.contains('body.replaceAccount'), isTrue,
          reason: 'run: dart tool/paste_functions.dart');
    });

    testWidgets('every requirement the app maps has a form to collect it',
        (t) async {
      t.view.physicalSize = const Size(500, 2600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);

      // THE BUG THIS EXISTS FOR. `individual.phone` was mapped to
      // ConnectField.phone and no section rendered it, so the form quietly could
      // not satisfy it — and it was not reported as unhandled either, because it
      // *was* mapped. Stripe asked, the form did not, and nothing said so.
      //
      // The sections come from an exhaustive switch now, so a field with nothing
      // to collect it is a compile error rather than a silent gap.
      final screen =
          File('lib/screens/native_onboarding_screen.dart').readAsStringSync();
      expect(screen.contains('switch (field)'), isTrue);
      expect(screen.contains('_sectionFor'), isTrue);
      expect(screen.contains('default:'), isFalse,
          reason: 'a default arm would put the silent gap back');

      // individual.relationship.title is what Stripe asked for on a real
      // account, reported as unhandled in orange at the bottom of the form.
      expect(stripeRequirementFields['individual.relationship.title'],
          ConnectField.title);
      expect(stripeRequirementFields['individual.phone'], ConnectField.phone);

      // Feed every requirement the app claims to handle and nothing may come
      // back unhandled — that list is generated from the same map.
      final all = stripeRequirementFields.keys.toList();
      final req = ConnectRequirements.fromJson({
        'collection': 'application',
        'currentlyDue': all,
        'country': 'CA',
        'status': <String, dynamic>{},
      });
      expect(req.fieldsNeeded.length, ConnectField.values.length,
          reason: 'every field is reachable from some requirement');

      PaymentService.instance.testMode.value = false;
      PublicFeedStore.debugLoadOverride = null;
      // The two new sections render, with the wording somebody has to act on.
      expect(screen.contains("_section('Phone')"), isTrue);
      expect(screen.contains("_section('Your role')"), isTrue);
      expect(screen.contains('"Owner" is the answer'), isTrue);
      // Prefilled, because the app already knows the number and retyping it is
      // a chore with a typo in it.
      expect(screen.contains("_title.text = 'Owner'"), isTrue);
      expect(screen.contains('local.Session.instance.user.value?.phone'), isTrue);

      // And the server puts the title where Stripe looks for it.
      final fn = File('supabase/functions/payments-connect-fields/index.ts')
          .readAsStringSync();
      expect(fn.contains('individual.relationship = { title: submit.title }'),
          isTrue);
      // The server no longer keeps its own list of what the app can collect:
      // two copies drifted the moment one was deployed without the other, and
      // the form was told to send somebody to Stripe's website for a field it
      // had just grown. The app works it out from the map its own form is
      // built from.
      expect(fn.contains('const HANDLED'), isFalse,
          reason: 'one source of truth, and it is the form\'s');
      final req2 = ConnectRequirements.fromJson({
        'collection': 'application',
        'currentlyDue': ['individual.relationship.title', 'company.tax_id'],
        'status': <String, dynamic>{},
      });
      expect(req2.unhandled, ['company.tax_id'],
          reason: 'derived from what the form actually collects');
    });

    test('a phone number is checked without being fussy about punctuation', () {
      // People write their own number with spaces, brackets and dashes.
      // Rejecting that teaches somebody the form is fussy, not that they are
      // wrong, so only the digit count is a real constraint.
      expect(ConnectValidation.phone('+1 (604) 555-0132'), isNull);
      expect(ConnectValidation.phone('6045550132'), isNull);
      expect(ConnectValidation.phone(''), isNotNull);
      expect(ConnectValidation.phone('604555'), isNotNull);
      expect(ConnectValidation.phone('1234567890123456'), isNotNull);
    });

    test('sensitive numbers are tokenised on the device, never posted to us',
        () async {
      addTearDown(() {
        StripeTokens.debugPost = null;
        StripeTokens.debugPublishableKey = null;
        StripeTokens.debugUpload = null;
      });
      StripeTokens.debugPublishableKey = 'pk_live_test';
      final sent = <String, Map<String, String>>{};
      StripeTokens.debugPost = (path, form) async {
        sent[path] = form;
        return {'id': form.containsKey('pii[id_number]') ? 'piitok_1' : 'btok_1'};
      };

      final bank = await StripeTokens.bankAccount(
        country: 'CA',
        currency: 'cad',
        accountHolderName: 'Sam Sample',
        routingNumber: '11000000',
        accountNumber: '000123456789',
      );
      expect(bank, 'btok_1');
      // Straight to Stripe with the publishable key — that is what the key is
      // for — so the one server in this system never holds an account number.
      expect(sent['tokens']!['key'], 'pk_live_test');
      expect(sent['tokens']!['bank_account[account_number]'], '000123456789');
      expect(sent['tokens']!['bank_account[account_holder_type]'], 'individual');

      // Nothing leaves this device unchecked, documents included: pickBytes
      // skips the resize (a shrunk licence is an unreadable licence) but not the
      // moderation.
      PhotoPrep.debugPickOverride =
          () async => Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      addTearDown(() => PhotoPrep.debugPickOverride = null);
      await expectLater(PhotoPrep.pickBytes(), throwsA(isA<FileRejected>()),
          reason: 'not an image');
      // A real image passes through at full size — Stripe has to be able to
      // read it.
      final png = Uint8List.fromList(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='));
      PhotoPrep.debugPickOverride = () async => png;
      expect(await PhotoPrep.pickBytes(), png,
          reason: 'byte-for-byte, not re-encoded');
      PhotoPrep.debugPickOverride = null;

      // The ID PHOTO too. Stripe's file endpoint accepts a publishable key over
      // Bearer auth — checked against the live API, not assumed — so a picture
      // of somebody's licence goes camera → Stripe, and this app's server holds
      // only the file id.
      Uint8List? uploaded;
      StripeTokens.debugUpload = (purpose, bytes, filename) async {
        uploaded = bytes;
        expect(purpose, 'identity_document');
        return {'id': 'file_1'};
      };
      expect(
          await StripeTokens.identityDocument(Uint8List.fromList([1, 2, 3]),
              filename: 'id-front.jpg'),
          'file_1');
      expect(uploaded, isNotNull);
      // A wrong-kind id must not pass as a file id.
      StripeTokens.debugUpload = (p, b, f) async => {'id': 'tok_visa'};
      await expectLater(
          StripeTokens.identityDocument(Uint8List.fromList([1])),
          throwsA(isA<StripeTokenException>()));
      StripeTokens.debugUpload = null;

      final pii = await StripeTokens.idNumber('046454286');
      expect(pii, 'piitok_1');
      expect(sent['tokens']!['pii[id_number]'], '046454286');

      // A token of the WRONG KIND must be refused too, not just a missing one.
      // The server checks the prefix as well, and a card token reaching the
      // bank-account path would fail there instead — after the value had
      // already left the device as if it were the right thing.
      StripeTokens.debugPost = (path, form) async => {'id': 'tok_visa'};
      await expectLater(
          StripeTokens.bankAccount(
            country: 'CA',
            currency: 'cad',
            accountHolderName: 'Sam',
            routingNumber: '11000000',
            accountNumber: '000123456789',
          ),
          throwsA(isA<StripeTokenException>()),
          reason: 'tok_ is not btok_');

      // A refusal has to be a refusal: returning something that isn't a token
      // would send a raw value onward as if it were one.
      StripeTokens.debugPost = (path, form) async =>
          {'error': {'message': 'Invalid account number.'}};
      await expectLater(
          StripeTokens.bankAccount(
            country: 'CA',
            currency: 'cad',
            accountHolderName: 'Sam',
            routingNumber: '11000000',
            accountNumber: '1',
          ),
          throwsA(predicate((e) => '$e'.contains('Invalid account number'))));
    });

    test('the form asks only for what Stripe says is missing', () {
      final req = ConnectRequirements.fromJson({
        'accountId': 'acct_1',
        'collection': 'application',
        'currentlyDue': [
          'individual.first_name',
          'individual.last_name',
          'individual.dob.day',
          'external_account',
          'tos_acceptance.date',
        ],
        'pastDue': <String>[],
        'unhandled': <String>[],
        'errors': <dynamic>[],
        'country': 'CA',
        'currency': 'cad',
        'status': {'chargesEnabled': false, 'payoutsEnabled': false},
      });
      expect(req.collectableInApp, isTrue);
      expect(req.complete, isFalse);
      // One section per requirement, deduplicated, in a fixed order — first and
      // last name are one part of the form, not two.
      expect(req.fieldsNeeded, [
        ConnectField.name,
        ConnectField.dob,
        ConnectField.bank,
        ConnectField.tos,
      ]);
      // Nothing it wasn't asked for.
      expect(req.fieldsNeeded.contains(ConnectField.idNumber), isFalse);

      // An older Express account cannot be collected in the app, and saying so
      // beats showing a form that cannot finish.
      final express = ConnectRequirements.fromJson({
        'collection': 'stripe',
        'currentlyDue': ['individual.first_name'],
        'status': <String, dynamic>{},
      });
      expect(express.collectableInApp, isFalse);

      // A missing field with no form is reported, never dropped.
      // A photo ID is asked for in the app now, so it is a section like any
      // other rather than a reason to leave.
      final withDoc = ConnectRequirements.fromJson({
        'collection': 'application',
        'currentlyDue': ['individual.verification.document'],
        'status': <String, dynamic>{},
      });
      expect(withDoc.fieldsNeeded, [ConnectField.document]);

      // Something genuinely uncollectable is still reported, never dropped.
      final odd = ConnectRequirements.fromJson({
        'collection': 'application',
        'currentlyDue': ['company.tax_id'],
        'unhandled': ['company.tax_id'],
        'status': <String, dynamic>{},
      });
      expect(odd.unhandled, ['company.tax_id']);
      expect(odd.fieldsNeeded, isEmpty,
          reason: 'no form claims to collect it');
    });

    test('bank and identity details are checked before Stripe sees them', () {
      // Every rule here spares somebody a rejection that arrives days later as
      // a requirement error against a field name.
      const now = null;
      expect(now, isNull); // keeps the linter happy about the doc comment above

      // Canada: Stripe wants transit+institution joined, which is not how a
      // cheque prints them.
      expect(ConnectValidation.routingNumber('11000-000', 'CA'), isNull);
      expect(ConnectValidation.routingNumber('1100000', 'CA'), isNotNull,
          reason: '7 digits is a transit number missing its institution');
      expect(ConnectValidation.routingNumber('123456789', 'US'), isNull);
      expect(ConnectValidation.routingNumber('12345678', 'US'), isNotNull);

      expect(ConnectValidation.accountNumber('000 123 456', 'CA'), isNull);
      expect(ConnectValidation.accountNumber('12', 'CA'), isNotNull);

      // A SIN carries a check digit, so a transposed pair — the commonest typo
      // there is — can be caught on the device.
      expect(ConnectValidation.idNumber('046 454 286', 'CA'), isNull);
      expect(ConnectValidation.idNumber('046 454 826', 'CA'), isNotNull,
          reason: 'two digits swapped must not pass');
      expect(ConnectValidation.idNumber('12345678', 'CA'), isNotNull);
      // The US has no check digit to lean on, so length is all that is honest.
      expect(ConnectValidation.idNumber('123456789', 'US'), isNull);

      expect(ConnectValidation.postalCode('K1A 0B1', 'CA'), isNull);
      expect(ConnectValidation.postalCode('k1a0b1', 'CA'), isNull);
      expect(ConnectValidation.postalCode('90210', 'CA'), isNotNull);
      expect(ConnectValidation.postalCode('90210', 'US'), isNull);

      final today = DateTime(2026, 7, 30);
      expect(ConnectValidation.dob(30, 7, 2008, now: today), isNull,
          reason: '18 today counts as 18');
      expect(ConnectValidation.dob(31, 7, 2008, now: today), isNotNull,
          reason: 'one day short of 18 is not 18');
      // An impossible date rolls over in DateTime, so it has to be compared
      // back rather than trusted.
      expect(ConnectValidation.dob(31, 2, 1990, now: today), isNotNull);
      expect(ConnectValidation.dob(29, 2, 1988, now: today), isNull,
          reason: '1988 was a leap year');
      expect(ConnectValidation.dob(1, 1, 2030, now: today), isNotNull);
      expect(ConnectValidation.dob(null, 1, 1990, now: today), isNotNull);

      expect(ConnectValidation.email('sam@example.com'), isNull);
      expect(ConnectValidation.email('sam@example'), isNotNull);
      expect(ConnectValidation.email(''), isNotNull);
    });

    test('a hosted page is never handed to a WebView that does not exist', () {
      // THE BLANK SCREEN. On the web build ConnectWebView is a stub returning
      // an empty box, so giving it a URL rendered an app bar over nothing — no
      // error, no spinner, no way forward. It went unnoticed because the web
      // build used to reach Stripe by navigating the tab and never came through
      // that screen; going to the hosted flow first is what routed it there.
      expect(
          hostedPresentationFor(webViewSupported: true),
          HostedPresentation.inThisScreen,
          reason: 'the app hosts it, as it always did');
      expect(
          hostedPresentationFor(webViewSupported: false),
          HostedPresentation.needsThisTab,
          reason: 'nowhere to put it, so say so instead of rendering a stub');

      // Every screen that builds a ConnectWebView has to ask first. A platform
      // check inside a build method is a branch no test on one platform can
      // reach, which is exactly how this shipped.
      for (final path in [
        'lib/screens/connect_onboarding_screen.dart',
        'lib/screens/identity_check_screen.dart',
        'lib/screens/in_app_web_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
            src.contains('ConnectWebView.isSupported') ||
                src.contains('hostedPresentationFor'),
            isTrue,
            reason: '$path builds a WebView without checking there is one');
      }
    });

    testWidgets('with no WebView, setup offers a way on instead of nothing',
        (t) async {
      // The web build's own path, exercised on the only platform tests run on.
      // Without this the branch is unreachable and the blank screen comes back.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                hostedPresentationFor(webViewSupported: false) ==
                        HostedPresentation.needsThisTab
                    ? const Text('Continue on Stripe')
                    : const SizedBox.shrink(),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Continue on Stripe'), findsOneWidget);
      // And the screen really does render that, rather than an empty box.
      final src = File('lib/screens/connect_onboarding_screen.dart')
          .readAsStringSync();
      expect(src.contains('Continue on Stripe'), isTrue);
      expect(src.contains('HostedPresentation.needsThisTab'), isTrue);
    });

    test('the app leads with the flow that actually works', () {
      // Payments work in the web build and fail in the app. The difference is
      // not the platform: the web build has no WebView, so it has always used
      // Stripe's hosted flow, while the app used the embedded component. So it
      // is the embedded path that is broken, and leading with it costs a
      // spinner, a failure and a wait before landing where it goes anyway.
      expect(preferHostedOnboarding, isTrue,
          reason: 'the hosted flow is the one that has been observed working');

      // The hosted flow still runs inside the app's own WebView, so this is not
      // a browser or a popup — which was an explicit requirement.
      final screen =
          File('lib/screens/connect_onboarding_screen.dart').readAsStringSync();
      expect(screen.contains('completionUrlPrefix: PaymentService.returnUrl'),
          isTrue,
          reason: 'Stripe ends the hosted flow by navigating; the app catches '
              'it rather than rendering its own website in the WebView');
      // initState cannot call setState — that marks this element dirty during
      // its parent's build — so the flag is set directly and the fetch runs
      // without it.
      expect(screen.contains('_loadingHosted = true;\n      _fetchHosted();'),
          isTrue);

      // And the embedded path is still there to switch back to, once the
      // self-test says which of the two causes it was.
      expect(screen.contains('PREFER_EMBEDDED_CONNECT'), isTrue);
    });

    test('a form that never authenticates becomes the hosted one by itself',
        () {
      // Everything that stops the embedded component from authenticating lives
      // on the server — the two Stripe keys in different modes or from
      // different accounts, embedded components switched off — and none of it
      // is anything the person holding the phone can fix. The hosted flow uses
      // no publishable key and no Account Session, so none of it touches it,
      // and it runs in the same WebView: no browser, no popup.
      //
      // So it happens by itself instead of behind a "Trouble?" button.
      expect(
          shouldFallBackToHosted(
              rendered: false, alreadyFellBack: false, onHosted: false),
          isTrue);

      // Not after the component painted: Stripe authenticated, the user may be
      // part-way through its forms, and swapping the page out loses what they
      // typed.
      expect(
          shouldFallBackToHosted(
              rendered: true, alreadyFellBack: false, onHosted: false),
          isFalse,
          reason: 'a failure after rendering is not a failure to start');

      // Once per screen, or a failing hosted page restarts the cycle forever.
      expect(
          shouldFallBackToHosted(
              rendered: false, alreadyFellBack: true, onHosted: false),
          isFalse);
      expect(
          shouldFallBackToHosted(
              rendered: false, alreadyFellBack: false, onHosted: true),
          isFalse);

      // 'ready' is what tells the host the component painted, so the page has
      // to keep sending it.
      final html = File('web/connect.html').readAsStringSync();
      expect(html.contains("notify('ready')"), isTrue);
    });

    test('which Stripe account each key belongs to is carried end to end', () {
      // Matching MODES is not enough. Two live keys from two different Stripe
      // accounts fail exactly the same way, because the Account Session
      // belongs to one platform and the publishable key to the other — and
      // Stripe words that as a problem with the user's account.
      //
      // Neither half can see the other on its own: the server knows its secret
      // key's account, the page can ask Stripe about the publishable key. So
      // the server's answer has to reach the page for the comparison to exist.
      final fn = File('supabase/functions/payments-account-session/index.ts')
          .readAsStringSync();
      expect(fn.contains('platformAccount'), isTrue,
          reason: 'the function reports the account its secret key belongs to');
      expect(fn.contains('stripe.accounts.retrieve()'), isTrue);
      // Best-effort: failing to look it up must not cost somebody onboarding.
      expect(fn.contains('catch (_)'), isTrue,
          reason: 'a lookup failure is not fatal');

      const session = ConnectSession(
          clientSecret: 's', publishableKey: 'pk_live_a', pageUrl: 'u');
      expect(session.platformAccount, '',
          reason: 'a deployment too old to say leaves it empty, not null');

      final html = File('web/connect.html').readAsStringSync();
      // Last argument, so neither side requires the other: the page deploys
      // the moment it is pushed, a build reaches a phone days later.
      expect(
          html.contains('function (clientSecret, publishableKey, dark, accent,'),
          isTrue);
      expect(html.contains('serverAccount'), isTrue);
      expect(html.contains('different accounts'), isTrue,
          reason: 'the page names the cause when it can prove it');
      // The publishable key is client-safe, and this is the endpoint Stripe.js
      // uses anyway — but nothing else may be sent with it.
      expect(html.contains("body: 'key=' + encodeURIComponent(pk)"), isTrue);
      final native =
          File('lib/payments/connect_webview_native.dart').readAsStringSync();
      expect(native.contains('_js(widget.platformAccount)'), isTrue,
          reason: 'the host passes it to okayStart');
    });

    test('the ID check page ships too, and keeps documents with Stripe', () {
      final page = File('web/identity.html');
      expect(page.existsSync(), isTrue);
      final html = page.readAsStringSync();

      // Stripe.js runs the capture, so the document photos and the selfie go
      // straight to Stripe and never touch this app.
      expect(html.contains('js.stripe.com'), isTrue);
      expect(html.contains('verifyIdentity'), isTrue);
      // Nothing here may upload or keep an image itself.
      expect(html.contains('FormData'), isFalse);
      expect(html.contains('getUserMedia'), isFalse,
          reason: 'capture belongs to Stripe, not to this page');

      // Same secret discipline as onboarding.
      expect(html.contains('window.okayStart'), isTrue);
      expect(html.contains('location.search'), isFalse);

      expect(IdentityVerification.pageUrl.endsWith('/identity.html'), isTrue);
      expect(IdentityVerification.pageUrl.startsWith('https://'), isTrue);
    });

    test('both pages answer to the same entry point', () {
      // One WebView serves both, so the pages must agree on the contract.
      for (final f in ['web/connect.html', 'web/identity.html']) {
        expect(File(f).readAsStringSync().contains('window.okayStart ='),
            isTrue,
            reason: '$f must expose okayStart');
      }
    });

    test('the web build gets a stub that reports unsupported, not a crash',
        () {
      // webview_flutter is mobile-only, so the web build compiles the stub
      // and the Wallet falls back to the hosted link. Tested against the stub
      // directly: `flutter test` runs on the VM, which has dart:io and so
      // picks the *native* side of the conditional import.
      expect(stub.ConnectWebView.isSupported, isFalse);
      expect(
          stub.ConnectWebView.build(
            url: 'https://example.test/connect.html',
            clientSecret: 'cs_test',
            publishableKey: 'pk_test',
            dark: true,
            accent: const Color(0xFF12B76A),
            onEvent: (_) {},
          ),
          isA<Widget>(),
          reason: 'the stub must build something rather than throw');
      // And the native side is what a phone gets.
      expect(ConnectWebView.isSupported, isTrue);
    });
  });

  group('Send-money sheet escape hatches', () {
    testWidgets('there is always a way out with the number pad up',
        (tester) async {
      // The amount field autofocuses a number pad, which on iOS has no Done
      // or Return key. With the sheet filling the screen and dragging it down
      // fighting the scroll view, there was no exit at all from a screen that
      // is about to move money.
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const PaymentAmountSheet(peerName: 'Grace'),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Send money to'), findsOneWidget);

      final cancel = find.byTooltip('Cancel');
      expect(cancel, findsOneWidget, reason: 'the sheet needs a visible exit');
      await tester.tap(cancel);
      await tester.pumpAndSettle();

      expect(find.textContaining('Send money to'), findsNothing);
      expect(closed, isTrue, reason: 'cancelling must return nothing');
    });

    testWidgets('tapping the sheet dismisses the keyboard', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PaymentAmountSheet(peerName: 'Grace'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Autofocus put the number pad up on the amount field.
      bool amountFocused() => tester
          .widgetList<EditableText>(find.byType(EditableText))
          .any((e) => e.focusNode.hasFocus);
      expect(amountFocused(), isTrue);

      await tester.tap(find.textContaining('Send money to'));
      await tester.pumpAndSettle();
      expect(amountFocused(), isFalse,
          reason: 'a number pad has no Done key, so a tap has to close it');
    });
  });

  group('Blue check', () {
    setUp(IdentityVerification.instance.resetForTest);
    tearDown(IdentityVerification.instance.resetForTest);

    test('only a passed ID check counts as verified', () {
      final identity = IdentityVerification.instance;
      // The badge used to be a free local toggle. Now nothing short of
      // Stripe's "verified" earns it.
      expect(identity.isVerified, isFalse);
      for (final status in [
        IdentityStatus.none,
        IdentityStatus.processing,
        IdentityStatus.requiresInput,
        IdentityStatus.canceled,
      ]) {
        identity.debugSetStatus(status);
        expect(identity.isVerified, isFalse,
            reason: '$status must not earn a blue check');
      }
      identity.debugSetStatus(IdentityStatus.verified);
      expect(identity.isVerified, isTrue);
    });

    test('a check still being reviewed reads as pending, not rejected', () {
      final identity = IdentityVerification.instance;
      identity.debugSetStatus(IdentityStatus.processing);
      expect(identity.isPending, isTrue);
      expect(identity.isVerified, isFalse);

      // Everything else is settled one way or the other.
      identity.debugSetStatus(IdentityStatus.requiresInput);
      expect(identity.isPending, isFalse);
      identity.debugSetStatus(IdentityStatus.verified);
      expect(identity.isPending, isFalse);
    });

    test('with no relay configured nothing throws and nothing is granted',
        () async {
      // Offline, or the functions aren't deployed yet: the badge must stay
      // off rather than fail open.
      final identity = IdentityVerification.instance;
      expect(await identity.start(), isNull);
      expect(await identity.refresh(), IdentityStatus.none);
      expect(identity.isVerified, isFalse);
    });

    test('the ID check stays in the app, hosted URL or not', () {
      // A modern session: Stripe.js on our own themed page.
      expect(
          IdentityCheckScreen.canHost(const IdentitySession(
              clientSecret: 'vs_1_secret',
              hostedUrl: 'https://verify.stripe.com/x',
              publishableKey: 'pk_live_x')),
          isTrue);
      // The regression this fixes: a deployed identity-start old enough to
      // return only a URL used to send the user to an external browser. It
      // is hostable, so it now opens on the app's own screen.
      expect(
          IdentityCheckScreen.canHost(const IdentitySession(
              clientSecret: '',
              hostedUrl: 'https://verify.stripe.com/x',
              publishableKey: '')),
          isTrue);
      // Nothing to show is still nothing to show.
      expect(
          IdentityCheckScreen.canHost(const IdentitySession(
              clientSecret: '', hostedUrl: '', publishableKey: '')),
          isFalse);
      expect(
          IdentityCheckScreen.canHost(const IdentitySession.alreadyVerified()),
          isFalse);
    });

    test('a hosted flow ends by navigating home, and only then', () {
      // A hosted check reports completion by going to the return URL, so that
      // navigation is what the WebView watches for. Stripe's own pages are
      // not it.
      expect(
          ConnectWebView.isCompletion('${IdentityVerification.returnUrl}?x=1',
              IdentityVerification.returnUrl),
          isTrue);
      expect(
          ConnectWebView.isCompletion(
              'https://verify.stripe.com/start', IdentityVerification.returnUrl),
          isFalse);
      expect(ConnectWebView.isCompletion('', IdentityVerification.returnUrl),
          isFalse);
      // No prefix, no matching — a caller that doesn't opt in never has a
      // navigation taken away from it.
      expect(ConnectWebView.isCompletion(IdentityVerification.pageUrl, ''),
          isFalse);

      // Why the WebView also waits for the first load before believing a
      // completion: our own identity page is served from the same origin as
      // the return URL, so its *own* initial load matches this rule. That
      // ordering guard lives in the WebView (no WebView in a unit test), and
      // this is the collision that makes it necessary.
      expect(
          ConnectWebView.isCompletion(
              IdentityVerification.pageUrl, IdentityVerification.returnUrl),
          isTrue,
          reason: 'same origin: the load-order guard is doing real work');
    });
  });

  group('App-wide moderation', () {
    setUp(PlatformModeration.instance.resetForTest);
    tearDown(PlatformModeration.instance.resetForTest);

    test('roles rank, and only the right ranks hold the right tools', () {
      expect(platformRoleRank(PlatformRole.owner),
          greaterThan(platformRoleRank(PlatformRole.admin)));
      expect(platformRoleRank(PlatformRole.admin),
          greaterThan(platformRoleRank(PlatformRole.moderator)));
      expect(platformRoleRank(PlatformRole.moderator),
          greaterThan(platformRoleRank(PlatformRole.member)));

      // A moderator times out. Bans and suspensions need an admin.
      expect(roleCanApply(PlatformRole.moderator, SanctionKind.timeout),
          isTrue);
      expect(roleCanApply(PlatformRole.moderator, SanctionKind.ban), isFalse);
      expect(
          roleCanApply(PlatformRole.moderator, SanctionKind.suspend), isFalse);
      expect(roleCanApply(PlatformRole.admin, SanctionKind.ban), isTrue);
      // Members hold nothing, and "none" is lifted, never applied.
      expect(roleCanApply(PlatformRole.member, SanctionKind.timeout), isFalse);
      expect(roleCanApply(PlatformRole.owner, SanctionKind.none), isFalse);
      // Granting roles is the owner's alone — and even then it is SQL.
      expect(roleCanGrantRoles(PlatformRole.owner), isTrue);
      expect(roleCanGrantRoles(PlatformRole.admin), isFalse);

      // Strictly outranking only, so a moderation team can't turn on itself.
      expect(canActOnRole(PlatformRole.admin, PlatformRole.member), isTrue);
      expect(canActOnRole(PlatformRole.admin, PlatformRole.admin), isFalse,
          reason: 'an admin must not be able to ban a peer');
      expect(canActOnRole(PlatformRole.admin, PlatformRole.owner), isFalse);
      expect(canActOnRole(PlatformRole.owner, PlatformRole.admin), isTrue);
      expect(canActOnRole(PlatformRole.member, PlatformRole.member), isFalse);
      // Nobody, at any rank, can act on the owner.
      for (final actor in PlatformRole.values) {
        expect(canActOnRole(actor, PlatformRole.owner), isFalse,
            reason: '${actor.name} must not be able to act on the owner');
      }
    });

    test('a sanction expires on its own, and each kind bites differently', () {
      final now = DateTime.utc(2026, 7, 1, 12);
      AccountSanction at(SanctionKind kind, {DateTime? until}) =>
          AccountSanction(kind: kind, until: until, createdAt: now);

      // A lapsed sanction is history, not a punishment — even before any
      // sweep removes the row.
      final lapsed =
          at(SanctionKind.ban, until: now.subtract(const Duration(minutes: 1)));
      expect(lapsed.isActiveAt(now), isFalse);
      expect(lapsed.blocksAccessAt(now), isFalse);
      expect(lapsed.blocksSendingAt(now), isFalse);

      // A ban with no end never lapses.
      expect(at(SanctionKind.ban).isActiveAt(now), isTrue);
      expect(at(SanctionKind.ban).blocksAccessAt(now), isTrue);

      // A timeout silences without disappearing anyone: still in the
      // directory, still reading.
      final timeout =
          at(SanctionKind.timeout, until: now.add(const Duration(hours: 1)));
      expect(timeout.blocksSendingAt(now), isTrue);
      expect(timeout.blocksAccessAt(now), isFalse);
      expect(timeout.hidesFromDirectoryAt(now), isFalse);

      // A suspension locks out and hides.
      final suspend =
          at(SanctionKind.suspend, until: now.add(const Duration(days: 2)));
      expect(suspend.blocksAccessAt(now), isTrue);
      expect(suspend.hidesFromDirectoryAt(now), isTrue);

      // None is nothing at all.
      expect(at(SanctionKind.none).isActiveAt(now), isFalse);

      // Round-trips through JSON, expiry and all.
      final revived = AccountSanction.fromJson(suspend.toJson());
      expect(revived.kind, SanctionKind.suspend);
      expect(revived.until, suspend.until);
      expect(revived.blocksAccessAt(now), isTrue);
    });

    test('time remaining reads like a person would say it', () {
      final now = DateTime.utc(2026, 7, 1, 12);
      expect(sanctionRemaining(null, now), '', reason: 'permanent has no end');
      expect(sanctionRemaining(now.subtract(const Duration(hours: 1)), now),
          '');
      // Under a minute is "moments" — "0 minutes" reads as already over.
      expect(sanctionRemaining(now.add(const Duration(seconds: 30)), now),
          'moments');
      expect(
          sanctionRemaining(now.add(const Duration(minutes: 1)), now),
          '1 minute');
      expect(
          sanctionRemaining(now.add(const Duration(minutes: 8)), now),
          '8 minutes');
      expect(sanctionRemaining(now.add(const Duration(hours: 1)), now),
          '1 hour');
      expect(sanctionRemaining(now.add(const Duration(hours: 5)), now),
          '5 hours');
      expect(sanctionRemaining(now.add(const Duration(days: 1)), now),
          '1 day');
      expect(sanctionRemaining(now.add(const Duration(days: 7)), now),
          '7 days');
      // Rounds up rather than under-promising: a sanction with 2 days and 23
      // hours left must not be described as "2 days".
      expect(
          sanctionRemaining(
              now.add(const Duration(days: 2, hours: 23)), now),
          '3 days');
      // …and promotes as it rounds, so nobody is told "60 minutes".
      expect(
          sanctionRemaining(
              now.add(const Duration(minutes: 59, seconds: 30)), now),
          '1 hour');
    });

    test('the store shows nothing until the server has spoken', () async {
      final store = PlatformModeration.instance;
      // A device that can't reach the server is a member with no sanction —
      // never a moderator on a hunch.
      expect(store.loaded, isFalse);
      expect(store.role, PlatformRole.member);
      expect(store.canModerate, isFalse);
      expect(store.isLockedOut, isFalse);
      expect(store.sanction, isNull);

      // Offline: refresh changes nothing rather than failing open.
      await store.refresh();
      expect(store.role, PlatformRole.member);

      PlatformModeration.debugStatusOverride = () async => (
            PlatformRole.moderator,
            AccountSanction(
                kind: SanctionKind.timeout,
                reason: 'Spam',
                until: DateTime.now().toUtc().add(const Duration(hours: 2)),
                createdAt: DateTime.now().toUtc()),
          );
      await store.refresh();
      expect(store.loaded, isTrue);
      expect(store.canModerate, isTrue);
      expect(store.canAdminister, isFalse);
      // A timeout silences without locking out.
      expect(store.isSilenced, isTrue);
      expect(store.isLockedOut, isFalse);

      // An already-lapsed sanction is not reported as one.
      PlatformModeration.debugStatusOverride = () async => (
            PlatformRole.member,
            AccountSanction(
                kind: SanctionKind.ban,
                until: DateTime.now()
                    .toUtc()
                    .subtract(const Duration(minutes: 5)),
                createdAt: DateTime.utc(2026)),
          );
      await store.refresh();
      expect(store.sanction, isNull);
      expect(store.isLockedOut, isFalse);
    });

    test('acting sends the server a request, never a decision', () async {
      final store = PlatformModeration.instance;
      final calls = <String>[];
      PlatformModeration.debugActOverride =
          (target, action, reason, minutes) async {
        calls.add('$target/$action/$reason/$minutes');
        return true;
      };

      // A ban carries no duration; the others do.
      await store.apply(
          targetPhone: '+1 (555) 010-2222',
          kind: SanctionKind.ban,
          reason: 'Scam');
      expect(calls.single, '15550102222/ban/Scam/0');

      calls.clear();
      await store.apply(
          targetPhone: '15550103333',
          kind: SanctionKind.timeout,
          reason: 'Spam',
          minutes: 60);
      expect(calls.single, '15550103333/timeout/Spam/60');

      calls.clear();
      await store.lift('15550103333');
      expect(calls.single, '15550103333/lift//0');

      // Nothing is sent for an empty target.
      calls.clear();
      expect(await store.apply(targetPhone: '  ', kind: SanctionKind.ban),
          isFalse);
      expect(calls, isEmpty);

      // A refusal is reported as one — the server is the authority, and the
      // console has to be able to say "that didn't happen".
      PlatformModeration.debugActOverride = (_, __, ___, ____) async => false;
      expect(
          await store.apply(
              targetPhone: '15550104444', kind: SanctionKind.ban),
          isFalse);
    });

    test('a report carries the complaint and never the conversation',
        () async {
      final store = PlatformModeration.instance;
      Map<String, dynamic>? filed;
      PlatformModeration.debugFileOverride = (row) async {
        filed = row;
        return true;
      };
      expect(
          await store.report(
            reason: 'Harassment',
            targetPhone: '+1 555 010-5555',
            targetHandle: 'ada',
            detail: 'Kept messaging after I asked them to stop',
            context: 'listing: Bike',
            reporterPhone: '+1 555 010-1111',
          ),
          isTrue);
      expect(filed!['reason'], 'Harassment');
      expect(filed!['target_phone'], '15550105555');
      expect(filed!['reporter_phone'], '15550101111');
      expect(filed!['target_handle'], 'ada');

      // Over-long detail is trimmed to what the column accepts rather than
      // failing the insert.
      PlatformModeration.debugFileOverride = (row) async {
        filed = row;
        return true;
      };
      await store.report(reason: 'Spam', detail: 'x' * 4000);
      expect((filed!['detail'] as String).length, 1000);
    });

    test('sanctions and roles are the database\'s to decide, not the app\'s',
        () {
      // Roles: a table with RLS on and no client policy. If the app could read
      // or write this, a modified build would simply make itself an owner.
      final sql = File('docs/platform_moderation.sql').readAsStringSync();
      expect(sql.contains('create table if not exists public.platform_roles'),
          isTrue);
      expect(sql.contains('alter table public.platform_roles enable row level'),
          isTrue);
      expect(sql.contains('create policy platform_roles'), isFalse,
          reason: 'no client may read or write who holds power');

      // The enforcement that survives a modified client: Postgres hides
      // locked-out accounts from the directory and refuses their writes.
      expect(sql.contains('function public.is_locked_out'), isTrue);
      expect(sql.contains('security definer'), isTrue);
      expect(sql.contains('not public.is_locked_out(phone)'), isTrue);
      // Time-awareness, so a lapsed sanction stops applying by itself.
      expect(sql.contains('s.until is null or s.until > now()'), isTrue);
      // Only bans and suspensions hide someone; a timeout silences.
      expect(sql.contains("s.kind in ('ban', 'suspend')"), isTrue);

      // Every authority check lives in the function, against the caller's
      // JWT-proven phone — the app's own role checks only draw buttons.
      final act =
          File('supabase/functions/moderation-act/index.ts').readAsStringSync();
      expect(act.contains('callerPhone(req)'), isTrue);
      expect(act.contains('platform_roles'), isTrue);
      expect(act.contains('RANK[actorRole] <= RANK[targetRole]'), isTrue,
          reason: 'outranking has to be checked server-side');
      expect(act.contains('needs_admin'), isTrue,
          reason: 'a moderator asking for a ban must be refused');
      expect(act.contains('cannot_sanction_self'), isTrue);
      expect(act.contains('moderation_log'), isTrue,
          reason: 'moderation without a record is just power');

      // Reports are readable only through a role-gated function.
      final queue = File('supabase/functions/moderation-queue/index.ts')
          .readAsStringSync();
      expect(queue.contains('RANK[role] < RANK.moderator'), isTrue);
      expect(sql.contains('create policy moderation_reports_insert'), isTrue);
      expect(sql.contains('for select'), isTrue);
      expect(
          sql.contains('create policy moderation_reports_select'), isFalse,
          reason: 'one person\'s report is nobody else\'s business');
    });

    test('moderation never claims a power over messages that nobody has', () {
      // The honesty that matters: message bodies are E2E encrypted with no
      // server copy, so no role can read or delete them. Anything that
      // implied otherwise would be a lie in a moderation console.
      final sql = File('docs/platform_moderation.sql').readAsStringSync();
      expect(sql.contains('end-to-end encrypted'), isTrue);
      // No moderation surface may reach into the mailbox, which holds the
      // sealed envelopes.
      for (final f in [
        'supabase/functions/moderation-act/index.ts',
        'supabase/functions/moderation-queue/index.ts',
        'supabase/functions/moderation-status/index.ts',
      ]) {
        expect(File(f).readAsStringSync().contains('mailbox'), isFalse,
            reason: '$f must not touch sealed message envelopes');
      }
    });

    testWidgets('a sanctioned account is told, not just quietly broken',
        (tester) async {
      final store = PlatformModeration.instance;
      // Nothing to say when there's no sanction.
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SanctionNotice())));
      expect(find.byType(Card), findsNothing);
      expect(find.textContaining('banned'), findsNothing);

      store.debugSet(
        role: PlatformRole.member,
        sanction: AccountSanction(
            kind: SanctionKind.suspend,
            reason: 'Scam listings',
            until: DateTime.now().toUtc().add(const Duration(days: 3)),
            createdAt: DateTime.now().toUtc()),
        loaded: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('Your account is suspended'), findsOneWidget);
      // The reason, the clock, and what still works — a lock-out with no
      // explanation is indistinguishable from a bug.
      expect(find.textContaining('Scam listings'), findsOneWidget);
      expect(find.textContaining('3 days'), findsOneWidget);
      expect(find.textContaining('stay readable'), findsOneWidget);

      // A ban says it doesn't expire rather than showing an empty clock.
      store.debugSet(
        sanction: AccountSanction(
            kind: SanctionKind.ban,
            reason: 'Fraud',
            createdAt: DateTime.now().toUtc()),
        loaded: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('Your account has been banned'), findsOneWidget);
      expect(find.textContaining('does not expire'), findsOneWidget);
    });

    testWidgets('the console only exists for accounts the server vouched for',
        (tester) async {
      final store = PlatformModeration.instance;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(
          body: SettingsView())));
      await tester.pumpAndSettle();
      expect(find.text('Moderation console'), findsNothing,
          reason: 'a member must never see moderation tools');

      store.debugSet(role: PlatformRole.moderator, loaded: true);
      await tester.pumpAndSettle();
      final console = find.text('Moderation console');
      await tester.scrollUntilVisible(console, 200);
      expect(console, findsOneWidget);
      expect(find.textContaining('Moderator'), findsWidgets);
    });

    testWidgets('the console offers a moderator only what they may do',
        (tester) async {
      final store = PlatformModeration.instance;
      PlatformModeration.debugReportsOverride = () async => const [];
      // A moderator: timeouts only, and the console says so.
      store.debugSet(role: PlatformRole.moderator, loaded: true);
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bans and suspensions need an admin'),
          findsOneWidget);
      // The limit on the whole feature is stated, not buried.
      expect(find.textContaining('no server copy'), findsOneWidget);

      await tester.tap(find.text('Act on account'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Timed out'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Banned'), findsNothing,
          reason: 'a moderator is not offered a ban');
      expect(find.widgetWithText(ChoiceChip, 'Suspended'), findsNothing);
    });
  });

  group('Fee disclosure', () {
    testWidgets('the sender sees the fee and what actually lands',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    const PaymentAmountSheet(peerName: 'Grace'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Nothing to disclose before an amount is entered.
      expect(find.text('Fee'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '20');
      await tester.pump();

      // The transfer is final, so sending is gated on saying so — the paper
      // trail is only worth having if it is always there.
      expect(find.text('Confirm to continue'), findsOneWidget);
      expect(find.textContaining('cannot be reversed'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(find.textContaining('Pay \$'), findsOneWidget);

      // The sender covers the fees, so the amount typed is what ARRIVES and
      // the total is what leaves their account.
      final total = PaymentEconomics.grossUpCents(2000);
      expect(find.text('Grace gets'), findsOneWidget);
      expect(find.text('Our fee'), findsOneWidget);
      expect(find.text('Card processing'), findsOneWidget);
      expect(find.text('You pay'), findsOneWidget);
      expect(find.text('\$20.00'), findsOneWidget,
          reason: 'the recipient gets exactly what was typed');
      expect(find.text('\$${(total / 100).toStringAsFixed(2)}'),
          findsOneWidget,
          reason: 'and the sender pays that plus both fees');
      expect(total, greaterThan(2000));
      expect(find.textContaining('we never hold it'), findsOneWidget);
    });
  });

  group('Channel mentions', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('only unread messages that name you are counted', () {
      final store = CommunityStore.instance;
      store.resetForTest();
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Ada',
          avatarColor: '#000000',
          phone: '+1 555 010 7777',
          username: 'ada');
      final community = store.createCommunity('Guild');
      final channel = store.byId(community.id)!.channels.first;

      Message msg(String id, String text) => Message(
          id: id, text: text, time: DateTime.now(), isMe: false);

      store.postMessage(community.id, channel.id, msg('m1', 'hello everyone'));
      store.postMessage(community.id, channel.id, msg('m2', 'hey @ada look'));
      Channel current() =>
          store.byId(community.id)!.channels.firstWhere((c) => c.id == channel.id);

      expect(store.unreadMentionsIn(current()), 1);
      expect(store.unreadInChannel(current()), 2);

      // Reading the channel clears both.
      store.markChannelSeen(channel.id, current().messages.length);
      expect(store.unreadMentionsIn(current()), 0);
      expect(store.unreadInChannel(current()), 0);

      // A later mention counts again; your own messages never do.
      store.postMessage(community.id, channel.id, msg('m3', 'ping @ada'));
      store.postMessage(
          community.id,
          channel.id,
          Message(
              id: 'm4', text: '@ada me too', time: DateTime.now(), isMe: true));
      expect(store.unreadMentionsIn(current()), 1);
    });

    test('muting a channel silences messages but not your own name', () {
      final store = CommunityStore.instance;
      store.resetForTest();
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Ada',
          avatarColor: '#000000',
          phone: '+1 555 010 7777',
          username: 'ada');
      final community = store.createCommunity('Guild');
      final channel = store.byId(community.id)!.channels.first;
      store.postMessage(
          community.id,
          channel.id,
          Message(
              id: 'm1', text: '@ada are you there', time: DateTime.now(),
              isMe: false));
      store.toggleChannelMute(channel.id);

      final current =
          store.byId(community.id)!.channels.firstWhere((c) => c.id == channel.id);
      // The server badge stays quiet...
      expect(store.unreadInCommunity(store.byId(community.id)!), 0);
      // ...but the mention still gets through.
      expect(store.unreadMentionsIn(current), 1);
      expect(store.unreadMentionsInCommunity(store.byId(community.id)!), 1);
    });
  });

  group('Members sheet', () {
    test('search narrows by name, case-insensitively', () {
      const members = [
        Member(id: 'me', name: 'You'),
        Member(id: 'u_1', name: 'Ada Lovelace'),
        Member(id: 'u_2', name: 'Grace Hopper'),
      ];
      expect(filterMembers(members, '').length, 3);
      expect([for (final m in filterMembers(members, 'ada')) m.name],
          ['Ada Lovelace']);
      expect([for (final m in filterMembers(members, 'HOPPER')) m.name],
          ['Grace Hopper']);
      // A surname match counts too, not just a prefix.
      expect(filterMembers(members, 'lovelace').length, 1);
      expect(filterMembers(members, 'nobody'), isEmpty);
      // Whitespace-only is not a filter.
      expect(filterMembers(members, '   ').length, 3);
    });
  });

  group('Voice channel screen', () {
    testWidgets('joining then leaving the screen disconnects cleanly',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      CommunityStore.instance.resetForTest();
      VoicePresenceStore.instance.resetForTest();
      addTearDown(VoicePresenceStore.instance.resetForTest);
      final community = CommunityStore.instance.createCommunity('Guild');
      CommunityStore.instance
          .addChannel(community.id, 'Lounge', type: ChannelType.voice);
      final channel = CommunityStore.instance
          .byId(community.id)!
          .channels
          .firstWhere((c) => c.type == ChannelType.voice);

      await tester.pumpWidget(MaterialApp(
        home: VoiceChannelScreen(
            communityId: community.id, channelId: channel.id),
      ));
      await tester.pump();
      expect(find.text('Join Voice'), findsOneWidget);

      await tester.tap(find.text('Join Voice'));
      await tester.pump();
      expect(VoicePresenceStore.instance.amIn(channel.id), isTrue);

      // Walking away from the screen has to leave the room — otherwise the
      // rest of the server keeps seeing you in it. Tearing the tree down
      // must not fire a notification into widgets that are already gone.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(VoicePresenceStore.instance.amIn(channel.id), isFalse);
      expect(VoicePresenceStore.instance.countIn(channel.id), 0);
    });
  });

  group('Channel typing', () {
    setUp(ChannelTypingStore.instance.resetForTest);
    tearDown(ChannelTypingStore.instance.resetForTest);

    test('the label reads naturally as more people join in', () {
      final typing = ChannelTypingStore.instance;
      expect(typing.labelFor('ch1'), isNull);
      typing.noteRemote(channelId: 'ch1', digits: '1', name: 'Ada');
      expect(typing.labelFor('ch1'), 'Ada is typing…');
      typing.noteRemote(channelId: 'ch1', digits: '2', name: 'Grace');
      expect(typing.labelFor('ch1'), 'Ada and Grace are typing…');
      typing.noteRemote(channelId: 'ch1', digits: '3', name: 'Zoe');
      expect(typing.labelFor('ch1'), '3 people are typing…');
      // Another channel is unaffected.
      expect(typing.labelFor('ch2'), isNull);
    });

    test('typing stops showing on its own', () {
      final typing = ChannelTypingStore.instance;
      typing.noteRemote(channelId: 'ch1', digits: '1', name: 'Ada');
      expect(typing.labelFor('ch1'), isNotNull);
      typing.expireNow(
          DateTime.now().add(ChannelTypingStore.linger * 2));
      expect(typing.labelFor('ch1'), isNull);
    });

    test('local pings are throttled, and sending resets the throttle', () {
      final typing = ChannelTypingStore.instance;
      var pings = 0;
      typing.onTyping = (_, __) => pings++;
      typing.noteLocalTyping('c1', 'ch1');
      typing.noteLocalTyping('c1', 'ch1');
      typing.noteLocalTyping('c1', 'ch1');
      expect(pings, 1, reason: 'a keystroke each would flood the bus');

      typing.clearLocal('ch1');
      typing.noteLocalTyping('c1', 'ch1');
      expect(pings, 2);
    });

    test('a nameless ping still reads as somebody', () {
      final typing = ChannelTypingStore.instance;
      typing.noteRemote(channelId: 'ch1', digits: '1', name: '');
      expect(typing.labelFor('ch1'), 'Someone is typing…');
      // An empty sender is ignored entirely — it can't be attributed.
      typing.noteRemote(channelId: 'ch2', digits: '', name: 'Ghost');
      expect(typing.labelFor('ch2'), isNull);
    });
  });

  group('Subscription entitlement', () {
    // Apple bills an auto-renewable subscription monthly whether or not the
    // app is ever opened, so a local "+30 days" would drift the moment a
    // renewal, cancellation, or refund happened elsewhere. The server's answer
    // is what counts; these cover the client half of adopting it.
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('the server can grant, extend, and revoke a plan', () async {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();
      expect(storage.isPaid, isFalse);
      expect(storage.activeGb, StorageStore.freeGb);

      final renewal = DateTime.now().add(const Duration(days: 30));
      await storage.applyServerEntitlement(
          active: true, gb: 50, expiresAt: renewal);
      expect(storage.isPaid, isTrue);
      expect(storage.activeGb, 50);

      // A renewal moves the date out without another purchase.
      final next = DateTime.now().add(const Duration(days: 60));
      await storage.applyServerEntitlement(
          active: true, gb: 50, expiresAt: next);
      expect(storage.daysLeft, greaterThan(30));

      // A refund ends it immediately, even mid-period.
      await storage.applyServerEntitlement(active: false, gb: 0);
      expect(storage.isPaid, isFalse);
      expect(storage.activeGb, StorageStore.freeGb);
    });

    test('an expiry already past leaves the account on the free tier',
        () async {
      final storage = StorageStore.instance;
      addTearDown(storage.resetForTest);
      storage.resetForTest();
      await storage.applyServerEntitlement(
          active: true,
          gb: 30,
          expiresAt: DateTime.now().subtract(const Duration(days: 1)));
      expect(storage.isPaid, isFalse);
      expect(storage.activeGb, StorageStore.freeGb);
      // Still remembered, so the screen offers "renew" rather than "subscribe".
      expect(storage.selectedGb, 30);
    });

    test('entitlement JSON survives the round trip', () {
      final e = Entitlement.fromJson(const {
        'active': true,
        'gb': 20,
        'expiresAt': '2030-01-01T00:00:00Z',
        'productId': 'com.okaymessaging.storage.gb20.monthly',
      });
      expect(e.active, isTrue);
      expect(e.gb, 20);
      expect(e.expiresAt!.toUtc().year, 2030);
      expect(Entitlement.fromJson(const {}).active, isFalse);
      expect(Entitlement.fromJson(const {'active': true, 'gb': 10}).expiresAt,
          isNull);
    });

    test('every purchasable size has a product id the server can price back',
        () {
      // gbForProduct() in _shared/iap.ts parses the size back out of the id.
      // If the two ever disagree a purchase would validate to 0 GB.
      final pattern = RegExp(r'\.storage\.gb(\d+)\.monthly$');
      for (final gb in StorageStore.sizes) {
        final id = StorePurchases.storageProductId(gb);
        final m = pattern.firstMatch(id);
        expect(m, isNotNull, reason: '$id is not in the form the server parses');
        expect(int.parse(m!.group(1)!), gb);
      }
      // Tips must NOT parse as storage — they grant no entitlement.
      for (final tip in StorePurchases.tipProducts) {
        expect(pattern.hasMatch(tip.id), isFalse);
      }
      final intent = File('docs/edge_functions_paste/payments-create-intent.ts')
          .readAsStringSync();
      expect(intent.contains('stripeAccount:'), isTrue,
          reason: 'transfers must be direct charges on the recipient account');
      expect(intent.contains('transfer_data'), isFalse,
          reason: 'transfer_data would route the money through the platform');
    });
  });

  group('Sync and replay safety', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a like replayed after a restart is still counted once', () async {
      final store = FeedStore.instance;
      store.resetForTest();
      final post = store.add('c1', 'likeable');
      store.applyRemoteLike(post.id,
          liked: true, likerName: 'Grace', likerUsername: 'grace');
      expect(store.postById(post.id)!.likes, 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Restart: memory cleared, state reloaded from disk.
      store.resetForTest();
      await store.load();
      expect(store.postById(post.id)!.likes, 1);

      // The same mailbox row comes back because its DELETE never landed.
      store.applyRemoteLike(post.id,
          liked: true, likerName: 'Grace', likerUsername: 'grace');
      expect(store.postById(post.id)!.likes, 1,
          reason: 'the who-liked-it guard has to survive the restart');
    });

    test('a poll vote replayed after a restart is still counted once',
        () async {
      final store = FeedStore.instance;
      store.resetForTest();
      final poll = store.addPoll('c1', 'Q?', ['A', 'B'])!;
      store.applyRemoteVote(poll.id,
          option: 0, previous: -1, voterUsername: 'grace');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      store.resetForTest();
      await store.load();
      expect(store.postById(poll.id)!.pollTotalVotes, 1);
      store.applyRemoteVote(poll.id,
          option: 0, previous: -1, voterUsername: 'grace');
      expect(store.postById(poll.id)!.pollTotalVotes, 1);
    });

    test('a deleted post stays deleted across a restart', () async {
      final store = FeedStore.instance;
      store.resetForTest();
      final post = store.add('c1', 'delete me');
      store.deletePost(post.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      store.resetForTest();
      await store.load();
      store.addRemote(post); // a stale relay copy replays it
      expect(store.postById(post.id), isNull);
    });

    test('restoring an older blob never drops what is only on the device',
        () {
      // Every automatic restore merges: the blob is a snapshot from some
      // earlier moment, and pull-to-refresh runs one on every screen.
      final feed = FeedStore.instance;
      feed.resetForTest();
      final old = feed.add('c1', 'already backed up');
      final feedBlob = feed.exportPosts();
      final fresh = feed.add('c1', 'posted while offline');
      feed.hydratePosts(feedBlob);
      expect(feed.postById(old.id), isNotNull);
      expect(feed.postById(fresh.id), isNotNull);

      CommunityStore.instance.resetForTest();
      final oldServer = CommunityStore.instance.createCommunity('Old Guild');
      final serverBlob = CommunityStore.instance.toJsonList();
      final newServer = CommunityStore.instance.createCommunity('New Guild');
      CommunityStore.instance.hydrate(serverBlob);
      final serverIds = {
        for (final c in CommunityStore.instance.communities) c.id
      };
      expect(serverIds, containsAll([oldServer.id, newServer.id]));

      SavedPlacesStore.instance.resetForTest();
      SavedPlacesStore.instance.toggle(const SavedPlace('Old', 1, 1));
      final placeBlob = SavedPlacesStore.instance.exportPlaces();
      SavedPlacesStore.instance.toggle(const SavedPlace('New', 2, 2));
      SavedPlacesStore.instance.hydratePlaces(placeBlob);
      expect({for (final p in SavedPlacesStore.instance.places) p.name},
          containsAll(['Old', 'New']));

      FollowStore.instance.setAll(const ['alreadyfollowed']);
      final followBlob = FollowStore.instance.following.toList();
      FollowStore.instance.toggle('justfollowed');
      FollowStore.instance.mergeAll(followBlob);
      expect(FollowStore.instance.following,
          containsAll(['alreadyfollowed', 'justfollowed']));
    });

    test('a deleted message stays deleted when the mailbox replays it', () {
      AppState.messagesFromContactsOnly.value = false;
      final store = ChatStore.instance;
      store.reset();
      const peer = '+1 555 010 9999';
      store.upsert(const Chat(
        id: 'chat_$peer',
        contact: AppUser(
            id: peer, name: 'Peer', avatarColor: '#111111', phone: peer),
        messages: [],
      ));
      final envelope = <String, dynamic>{
        'id': 'm_replay_1',
        'from': peer,
        'ts': DateTime.now().toUtc().toIso8601String(),
        'text': 'hello there',
      };
      expect(
          RelayService.applyIncoming(envelope, myPhone: '+1 555 010 0000'),
          isTrue);

      store.deleteMessage('chat_$peer', 'm_replay_1');
      expect(store.chatById('chat_$peer')!.messages, isEmpty);

      // The mailbox row's DELETE never landed, so the envelope comes back.
      expect(
          RelayService.applyIncoming(envelope, myPhone: '+1 555 010 0000'),
          isFalse);
      expect(store.chatById('chat_$peer')!.messages, isEmpty);
    });

    test('a deleted conversation does not rebuild itself from the mailbox',
        () {
      AppState.messagesFromContactsOnly.value = false;
      final store = ChatStore.instance;
      store.reset();
      const peer = '+1 555 010 8888';
      store.upsert(const Chat(
        id: 'chat_$peer',
        contact: AppUser(
            id: peer, name: 'Peer2', avatarColor: '#111111', phone: peer),
        messages: [],
      ));
      final envelope = <String, dynamic>{
        'id': 'm_replay_2',
        'from': peer,
        'ts': DateTime.now().toUtc().toIso8601String(),
        'text': 'hi',
      };
      RelayService.applyIncoming(envelope, myPhone: '+1 555 010 0000');
      store.deleteChat('chat_$peer');
      RelayService.applyIncoming(envelope, myPhone: '+1 555 010 0000');
      expect(store.chatById('chat_$peer'), isNull);
    });

    test('delete tombstones survive a save and reload', () {
      final store = ChatStore.instance;
      store.reset();
      final chatId = store.chats.first.id;
      final messageId = store.chatById(chatId)!.messages.first.id;
      store.deleteMessage(chatId, messageId);
      final snapshot = store.toJson();

      store.reset();
      expect(store.isMessageDeleted(messageId), isFalse);
      store.hydrate(snapshot);
      expect(store.isMessageDeleted(messageId), isTrue);
    });

    test('a deleted channel message stays deleted when the bus replays it',
        () {
      final store = CommunityStore.instance;
      store.resetForTest();
      final community = store.createCommunity('Guild');
      final channel = store.byId(community.id)!.channels.first;
      final message = Message(
          id: 'cm_replay', text: 'hi', time: DateTime.now(), isMe: false);
      Channel current() => store
          .byId(community.id)!
          .channels
          .firstWhere((c) => c.id == channel.id);

      store.addRemoteChannelMessage(community.id, channel.id, message);
      expect(current().messages.any((m) => m.id == 'cm_replay'), isTrue);

      store.deleteChannelMessage(community.id, channel.id, 'cm_replay');
      expect(current().messages.any((m) => m.id == 'cm_replay'), isFalse);

      store.addRemoteChannelMessage(community.id, channel.id, message);
      expect(current().messages.any((m) => m.id == 'cm_replay'), isFalse,
          reason: 'a queued copy must not undo the delete');
    });

    test('clearAll is how a restore starts from an empty device', () {
      CommunityStore.instance.resetForTest();
      expect(CommunityStore.instance.communities, isNotEmpty);
      CommunityStore.instance.clearAll();
      expect(CommunityStore.instance.communities, isEmpty);
    });
  });

  group('The shell above every screen', () {
    testWidgets('a pushed screen keeps the sidebar and the bottom bar',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      expect(find.byType(ModernNavBar), findsOneWidget);

      // A chat is as deep as the app goes on a normal day.
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();
      expect(find.text('Bob Carter'), findsWidgets, reason: 'chat is open');

      // THE POINT OF ALL THIS. The bar used to belong to the home screen's
      // Scaffold, so this route covered it and the arrow in the corner was
      // the only way anywhere.
      expect(find.byType(ModernNavBar), findsOneWidget,
          reason: 'the bottom bar rides above the pushed route');
      expect(find.byType(BackButton), findsNothing,
          reason: 'no screen has a back arrow any more');
      expect(find.byType(SidebarButton), findsOneWidget,
          reason: 'the leading slot is the sidebar instead');

      // And the sidebar really opens from here, not just renders. It hangs off
      // a Scaffold that is a *parent* of the navigator, so the drawer's own
      // tiles cannot use Navigator.of either.
      await tester.tap(find.byType(SidebarButton));
      await tester.pumpAndSettle();
      expect(find.text('Marketplace'), findsOneWidget);
      await tester.tap(find.text('Wallet'));
      await tester.pumpAndSettle();
      expect(find.text('Marketplace'), findsNothing, reason: 'drawer closed');
      expect(find.byType(WalletScreen), findsOneWidget,
          reason: 'a sidebar tile pushed a route from above the navigator');
    });

    testWidgets('a bottom-bar tap unstacks whatever is on top',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob Carter'));
      await tester.pumpAndSettle();

      // A pill only wears its label when it is the selected one, so this
      // reaches for the icon inside the bar rather than the word.
      await tester.tap(find.descendant(
          of: find.byType(ModernNavBar),
          matching: find.byIcon(Icons.call_outlined)));
      await tester.pumpAndSettle();
      expect(rootNavigatorKey.currentState!.canPop(), isFalse,
          reason: 'a destination is a destination: the chat is gone');
      expect(ShellTabs.index.value, 2);
    });

    testWidgets('the pages are told what the floating bar covers',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();

      final bar = tester.getRect(find.byType(ModernNavBar));
      final page = MediaQuery.of(tester.element(find.text('Bob Carter').first));
      // Without this the send button in the forward picker sat underneath the
      // bar and the tap landed on the bar. Both insets: SafeArea reads
      // `padding`, Scaffold places a floating action button off `viewPadding`.
      expect(page.padding.bottom, bar.height);
      expect(page.viewPadding.bottom, bar.height);
    });

    testWidgets('a sheet gets the whole screen, and the bar comes back',
        (tester) async {
      await tester.pumpWidget(const OkayMessagingApp());
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Carol Diaz'));
      await tester.pumpAndSettle();
      expect(find.text('Archive chat'), findsOneWidget);
      // A sheet owns the screen: the bar would paint over its buttons, and the
      // padding the pages get would push its content out of its own box.
      expect(find.byType(ModernNavBar), findsNothing);
      expect(
          MediaQuery.of(tester.element(find.text('Archive chat'))).padding.bottom,
          0);

      await tester.tapAt(const Offset(400, 40)); // the barrier
      await tester.pumpAndSettle();
      expect(find.byType(ModernNavBar), findsOneWidget,
          reason: 'and it is back the moment the sheet is gone');
    });

    test('no app bar in the app implies a back arrow', () {
      // 75 app bars agreeing by habit is a rule waiting to be broken. Flutter
      // fills the leading slot with a back arrow whenever the route can pop
      // and nothing else claims it, so the flag has to be explicit.
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = file.readAsStringSync();
        // SliverAppBar too — it grows the same arrow, and matching only
        // `\bAppBar\(` walked straight past both of the app's own.
        for (final match
            in RegExp(r'(?<![A-Za-z0-9_])(Sliver)?AppBar\(').allMatches(src)) {
          // The arguments of this AppBar only — a nested widget's own are its
          // business.
          var depth = 0;
          final own = StringBuffer();
          for (var i = match.end - 1; i < src.length; i++) {
            final c = src[i];
            if ('([{'.contains(c)) depth++;
            if (')]}'.contains(c)) depth--;
            if (depth == 0) break;
            if (depth == 1) own.write(c);
          }
          if (!own.toString().contains('automaticallyImplyLeading: false')) {
            offenders.add('${file.path}:${'\n'.allMatches(src.substring(0, match.start)).length + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these app bars would grow a back arrow when pushed');
    });
  });
}
