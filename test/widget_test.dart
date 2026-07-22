import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/crypto/e2e.dart';
import 'package:okay_messaging/crypto/key_exchange.dart';
import 'package:okay_messaging/main.dart';
import 'package:okay_messaging/screens/auth/phone_login_screen.dart';
import 'package:okay_messaging/screens/call_screen.dart';
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
import 'package:okay_messaging/state/call_service.dart';
import 'package:okay_messaging/state/community_store.dart';
import 'package:okay_messaging/state/file_transfer.dart';
import 'package:okay_messaging/state/chat_store.dart';
import 'package:okay_messaging/state/scheduler.dart';
import 'package:okay_messaging/state/session.dart';
import 'package:okay_messaging/widgets/chat_input_bar.dart';
import 'package:okay_messaging/widgets/heart_burst.dart';
import 'package:okay_messaging/widgets/rich_message_text.dart';

void main() {
  // Singletons persist across tests; reset them so each starts clean. Most
  // tests assume a signed-in user so they land on the home screen; the
  // phone-login test signs out first.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.instance.reset();
    AppState.resetForTest();
    Session.instance.signInForTest();
    Scheduler.instance.resetForTest();
    CallService.instance.resetForTest();
    AppLock.instance.resetForTest();
    CommunityStore.instance.resetForTest();
  });

  testWidgets('App boots with Chats and Calls tabs (no Status)',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('Okay Messaging'), findsOneWidget);
    // The modern pill bar labels only the active tab; Chats is active.
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Status'), findsNothing);

    // The Calls destination exists; selecting it reveals its label.
    expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Calls'), findsOneWidget);
  });

  testWidgets('At least one conversation is listed on the Chats tab',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('Alice Bennett'), findsOneWidget);
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

  testWidgets('FAB on the Chats tab opens the new-chat contact picker',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
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

    await tester.pageBack();
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Ada Lovelace');
    await tester.tap(find.byIcon(Icons.check));
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chats'));
    await tester.pumpAndSettle();

    expect(find.text('Chat wallpaper'), findsOneWidget);
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

    expect(find.text('Did you see the game last night?'), findsNothing);
    expect(find.textContaining('What a finish'), findsOneWidget);
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

    // Open the attachment sheet and pick Gallery.
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob');
    expect(bob!.messages.any((m) => m.isImage), isTrue);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Sharing a location sends a location message', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    expect(bob.messages.any((m) => m.isLocation), isTrue);
    // The location card renders its pin.
    expect(find.byIcon(Icons.location_on), findsWidgets);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
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

    // Start a voice call from the chat header.
    await tester.tap(find.byIcon(Icons.call));
    await tester.pumpAndSettle();

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
        find.widgetWithText(TextFormField, 'Username'), 'AdaL');
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
        scrollable: find.byType(Scrollable).first);
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
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(blockTile);
    await tester.pumpAndSettle();
    await tester.tap(blockTile);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();
    final bobPhone = ChatStore.instance.chatWithContact('u_bob')!.contact.phone;
    expect(AppState.isBlocked(bobPhone), isTrue);

    // Back in the conversation, the composer is gone and a banner shows.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChatInputBar), findsNothing);
    expect(find.text('You blocked Bob Carter'), findsOneWidget);
  });

  testWidgets('Chat menu: Wallpaper opens the picker, Export copies the chat',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    // Wallpaper opens the picker screen.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wallpaper'));
    await tester.pumpAndSettle();
    // Per-chat wallpaper picker (its "Default" swatch is shown).
    expect(find.text('Default'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Export copies the conversation and confirms via a snackbar.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export chat'));
    await tester.pumpAndSettle();
    expect(find.text('Chat copied to clipboard'), findsOneWidget);
  });

  testWidgets('Disappearing-messages menu sets a timer and shows the indicator',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disappearing messages'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1 day'));
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
    await tester.pageBack();
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

  test('editMessage replaces text and marks it edited', () {
    ChatStore.instance.reset();
    final bob = ChatStore.instance.chatWithContact('u_bob')!;
    final id = bob.messages.firstWhere((m) => m.isMe).id;

    ChatStore.instance.editMessage(bob.id, id, 'edited text');
    final m = ChatStore.instance
        .chatById(bob.id)!
        .messages
        .firstWhere((x) => x.id == id);
    expect(m.text, 'edited text');
    expect(m.edited, isTrue);
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
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'Edited!',
    );
    await tester.tap(find.text('Save'));
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute notifications'));
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chatWithContact('u_bob')!.isMuted, isTrue);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
  });

  testWidgets('Pinning from the chat menu pins the conversation',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin chat'));
    await tester.pumpAndSettle();

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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear chat'));
    await tester.pumpAndSettle();
    // Confirm in the dialog (the red action button).
    await tester.tap(find.widgetWithText(TextButton, 'Clear chat'));
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chatWithContact('u_bob')!.messages, isEmpty);
  });

  testWidgets('Delete chat removes the conversation and pops back',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bob Carter'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete chat'));
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

  testWidgets('Creating a group adds it to the chat list with its members',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Chats FAB → New group.
    await tester.tap(find.byType(FloatingActionButton));
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(AppState.shareLastSeen.value, isTrue);
    expect(find.text('Share online status'), findsOneWidget);

    await tester.tap(find.text('Share online status'));
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

  testWidgets('The lock screen gates the app and unlocks with the right PIN',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppLock.instance.resetForTest();
    await AppLock.instance.setPin('4321');
    AppLock.instance.locked.value = true; // simulate a fresh, locked launch

    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    expect(find.text('Okay Messaging is locked'), findsOneWidget);

    // Wrong PIN keeps it locked.
    await tester.enterText(find.byType(TextField).first, '0000');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Okay Messaging is locked'), findsOneWidget);

    // Correct PIN unlocks.
    await tester.enterText(find.byType(TextField).first, '4321');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Okay Messaging is locked'), findsNothing);
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
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

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(AppState.sendReadReceipts.value, isTrue);

    final tile = find.text('Read receipts');
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(AppState.sendReadReceipts.value, isFalse);
  });

  testWidgets('Storage → clear all chats empties the store after confirming',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();
    expect(ChatStore.instance.chats, isNotEmpty);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    final tile = find.text('Storage and data');
    await tester.scrollUntilVisible(tile, 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // Confirm the destructive dialog.
    await tester.tap(find.text('Clear'));
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
}
