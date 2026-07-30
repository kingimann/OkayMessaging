// Renders screens to PNGs so a change to how something looks can be looked at
// instead of imagined.
//
// NOT part of the suite. `flutter test` only collects files whose names end in
// _test.dart, so this one sits beside them and is never collected — a golden
// that has to be regenerated on every deliberate pixel change is a gate nobody
// thanks you for. It is under test/ rather than tool/ because that is where
// @visibleForTesting hooks may be used. Run it by hand:
//
//   export PATH="/opt/flutter/bin:$PATH"
//   flutter test test/screenshot_tool.dart --update-goldens
//   # then look at test/shots/*.png
//
// Edit `main` to point at whatever is being worked on. The pieces worth
// keeping are `loadFonts` and the view size — without the first, every glyph
// renders as a filled box and the shot tells you nothing about type.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/models/user.dart';
import 'package:okay_messaging/main.dart';
import 'package:okay_messaging/state/chat_store.dart';
import 'package:okay_messaging/state/legal_consent.dart';
import 'package:okay_messaging/state/session.dart';
import 'package:okay_messaging/state/public_feed_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real type instead of the test font's filled boxes.
///
/// The bytes are read SYNCHRONOUSLY on purpose: a testWidgets body runs in
/// fake async, so a real File future never completes and the whole run hangs
/// with no output and no error.
Future<void> loadFonts() async {
  const dir = '/opt/flutter/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(
          ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  testWidgets('shots', (t) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({});
    // A phone, not the 800x600 the test binding defaults to — half of what
    // looks wrong on a real screen is width.
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);

    AppState.profile.value = const AppUser(
        id: 'me',
        name: 'Iman Fakhar',
        avatarColor: '#2E7D32',
        username: 'iman',
        about: 'Building OkayMessenger. Privacy-first, local-first.',
        link: 'okaymessaging.com',
        pronouns: 'he/him');

    final now = DateTime.now();
    PublicFeedStore.debugProfileOverride = (u) async => [
          for (var i = 0; i < 6; i++)
            PublicPost(
                id: 'p$i',
                authorUsername: 'iman',
                authorName: 'Iman Fakhar',
                body: i.isEven
                    ? 'Shipped the shell today — every screen keeps the '
                        'sidebar and the bottom bar now.'
                    : 'Short one.',
                likeCount: 3 + i,
                replyCount: i,
                mine: true,
                createdAt: now.subtract(Duration(hours: i))),
        ];

    ChatStore.instance.reset();
    AppState.resetForTest();
    Session.instance.signInForTest();
    LegalConsent.instance.resetForTest();
    await t.pumpWidget(const OkayMessagingApp());
    await t.pumpAndSettle();

    Future<void> shot(String name) async {
      await t.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
    }

    // Every bottom-bar destination.
    await shot('tab_chats');
    for (final (i, name) in [
      (1, 'tab_servers'),
      (2, 'tab_calls'),
      (3, 'tab_alerts'),
      (4, 'tab_you'),
    ]) {
      await t.tap(find.byIcon([
        Icons.chat_bubble_outline,
        Icons.groups_outlined,
        Icons.call_outlined,
        Icons.notifications_none,
        Icons.person_outline,
      ][i]));
      await shot(name);
    }

    // Back to Chats, then the drawer.
    await t.tap(find.byIcon(Icons.chat_bubble_outline));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await shot('drawer');

    // A screen reached from the drawer — does it have a way back?
    await t.tap(find.text('Settings'));
    await shot('pushed_settings');
  });
}
