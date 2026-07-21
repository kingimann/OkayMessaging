import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/main.dart';
import 'package:okay_messaging/models/message.dart';
import 'package:okay_messaging/state/chat_store.dart';

void main() {
  // Singletons persist across tests; reset them so each starts clean.
  setUp(() {
    ChatStore.instance.reset();
    AppState.resetForTest();
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
    await tester.pumpAndSettle();

    expect(ChatStore.instance.chatById('c_bob')!.messages
        .firstWhere((m) => m.id == firstId)
        .reactions
        .contains('❤️'), isTrue);
  });
}
