import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/main.dart';
import 'package:okay_messaging/screens/auth/phone_login_screen.dart';
import 'package:okay_messaging/screens/call_screen.dart';
import 'package:okay_messaging/screens/media_gallery_screen.dart';
import 'package:okay_messaging/models/message.dart';
import 'package:okay_messaging/relay/relay_service.dart';
import 'package:okay_messaging/state/chat_store.dart';
import 'package:okay_messaging/state/session.dart';
import 'package:okay_messaging/widgets/heart_burst.dart';
import 'package:okay_messaging/widgets/linkable_text.dart';

void main() {
  // Singletons persist across tests; reset them so each starts clean. Most
  // tests assume a signed-in user so they land on the home screen; the
  // phone-login test signs out first.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.instance.reset();
    AppState.resetForTest();
    Session.instance.signInForTest();
  });

  testWidgets('App boots with Chats and Calls tabs (no Status)',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    expect(find.text('Okay Messaging'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Calls'), findsOneWidget);
    expect(find.text('Status'), findsNothing);
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

  testWidgets('Groups filter shows only group chats', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();

    expect(find.text('Team Standup'), findsOneWidget);
    expect(find.text('Alice Bennett'), findsNothing);
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

    expect(find.text('Bob Carter'), findsNothing);
    expect(find.text('Archived'), findsOneWidget);
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

    await tester.tap(find.byIcon(Icons.search));
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

  testWidgets('Archiving a chat moves it into the Archived section',
      (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // Long-press Carol's chat and archive it.
    await tester.longPress(find.text('Carol Diaz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive chat'));
    await tester.pumpAndSettle();

    // Carol is gone from the main list; an Archived row appears.
    expect(find.text('Carol Diaz'), findsNothing);
    expect(find.text('Archived'), findsOneWidget);

    // Opening Archived shows Carol again.
    await tester.tap(find.text('Archived'));
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

    // Carol's chat has a message with a link, rendered via LinkableText.
    expect(find.byType(LinkableText), findsOneWidget);

    // Tapping the link span copies it and shows a confirmation snackbar.
    // (Pump past the double-tap timeout so the single tap resolves to the
    // link's recognizer rather than the bubble's double-tap detector.)
    await tester.tapOnText(find.textRange.ofSubstring('okaydocs.example'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Link copied'), findsOneWidget);
  });

  testWidgets('Tapping the call button opens the call screen', (tester) async {
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

    // After connecting, a running timer replaces the ringing status.
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ringing…'), findsNothing);

    // Ending the call returns to the conversation.
    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsNothing);
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

    // Enter a name and phone number and continue.
    await tester.enterText(find.widgetWithText(TextFormField, 'Your name'),
        'Ada');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone number'), '5550123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Now signed in: the chat list is shown.
    expect(find.byType(PhoneLoginScreen), findsNothing);
    expect(find.text('Alice Bennett'), findsOneWidget);
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

    expect(find.text('2 unread messages'), findsOneWidget);
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
  });
}
