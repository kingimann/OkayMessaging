import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:okay_messaging/main.dart';

void main() {
  testWidgets('App boots and shows the three main tabs', (tester) async {
    await tester.pumpWidget(const OkayMessagingApp());
    await tester.pumpAndSettle();

    // App bar title.
    expect(find.text('Okay Messaging'), findsOneWidget);

    // The three tabs are present.
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
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
}
