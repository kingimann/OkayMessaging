// Tests that measure how wide something is, and therefore need the type the
// app actually ships.
//
// A SEPARATE FILE ON PURPOSE. The test binding draws every glyph as an
// identical square, so laid-out text in a test is about twice the width it is
// on a phone — fine until a test asks "does this fit on one line". Loading the
// real Roboto fixes that, but a FontLoader registers with the whole isolate
// and never unregisters, so every later test in the same file silently gets
// different metrics. One did: the notification filters measured 338 points of
// a 390 point row and failed for a reason that had nothing to do with it.
// `flutter test` gives each file its own isolate, so here the fonts stay put.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:okay_messaging/app_state.dart';
import 'package:okay_messaging/models/user.dart';
import 'package:okay_messaging/screens/cloud_sync_screen.dart';
import 'package:okay_messaging/screens/profile_screen.dart';
import 'package:okay_messaging/screens/public_feed_screen.dart';
import 'package:okay_messaging/state/account_email.dart';
import 'package:okay_messaging/state/public_feed_store.dart';
import 'package:okay_messaging/state/storage_store.dart';
import 'package:okay_messaging/theme/app_theme.dart';

/// The bytes are read SYNCHRONOUSLY on purpose: a testWidgets body runs in
/// fake async, so a real File future never completes and the run hangs with no
/// output and no error.
Future<void> loadRealFonts() async {
  const dir = '/opt/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']) {
    loader.addFont(
        Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StorageStore.instance.resetForTest();
    AccountEmail.instance.resetForTest();
  });
  tearDown(() {
    StorageStore.instance.resetForTest();
    AccountEmail.instance.resetForTest();
    PublicFeedStore.instance.resetForTest();
    AppState.resetForTest();
  });

  testWidgets('a profile spends its first screen on the person', (t) async {
    // The banner cost 92 points, plus the half-avatar hanging off it, plus
    // the buttons on a line of their own below — most of a phone's first
    // screenful spent on decoration, with the tab strip pushed almost to the
    // fold. Real type, because this is a measurement and the test font is
    // twice the width of the one that ships.
    await loadRealFonts();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    addTearDown(PublicFeedStore.instance.resetForTest);
    AppState.profile.value = const AppUser(
        id: 'me',
        name: 'Iman Fakhar',
        avatarColor: '#2E7D32',
        username: 'iman',
        about: 'Building OkayMessenger — privacy-first, local-first. '
            'Everything stays on your device.',
        link: 'okaymessaging.com',
        pronouns: 'he/him');
    addTearDown(AppState.resetForTest);
    PublicFeedStore.debugProfileOverride = (username) async => [];

    await t.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const PublicProfileScreen(
            username: 'iman', name: 'Iman Fakhar')));
    await t.pumpAndSettle();

    // Everything the profile says about the person, above the tab strip.
    final tabs = t.getRect(find.text('Replies'));
    for (final finder in [
      find.text('@iman'),
      find.textContaining('privacy-first'),
      find.text('okaymessaging.com'),
      find.text('Following'),
      find.text('Okay Score'),
      find.text('Verify phone'),
    ]) {
      expect(t.getRect(finder).bottom, lessThan(tabs.top),
          reason: 'this belongs above the tabs, not under them');
    }
    // And the strip itself is well clear of the fold. Putting a 92pt banner
    // back would land it around 560.
    expect(tabs.bottom, lessThan(500.0),
        reason: 'the header is eating the screen again');
  });

  testWidgets('the profile buttons are not cropped on a phone', (t) async {
    // The avatar and the buttons share a line now. Written as a Spacer with a
    // Flexible after it, the two Expandeds split the free space between them
    // and "Edit profile" was cropped to "Edit …" on a 390pt phone with room
    // to spare.
    await loadRealFonts();
    for (final width in [320.0, 390.0, 430.0]) {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      AppState.profile.value = const AppUser(
          id: 'me',
          name: 'Iman Fakhar',
          avatarColor: '#2E7D32',
          username: 'iman');
      PublicFeedStore.debugProfileOverride = (username) async => [];

      await t.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: const PublicProfileScreen(
              username: 'iman', name: 'Iman Fakhar')));
      await t.pumpAndSettle();

      final label = t.renderObject<RenderParagraph>(find.text('Edit profile'));
      expect(label.didExceedMaxLines, isFalse,
          reason: 'the button label is cropped at $width');
      expect(t.takeException(), isNull, reason: 'it overflows at $width');
    }
  });

  testWidgets('the three verification chips fit on one line', (t) async {
    await loadRealFonts();
    // Filled pills at 13pt with 13 points of side padding do not fit a
    // 390pt phone, so the row wrapped and the middle of every profile had
    // two ragged lines of grey lozenges in it.
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    AccountEmail.instance.resetForTest();
    addTearDown(AccountEmail.instance.resetForTest);

    await t.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
            body: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [ProfileVerificationRow()])))));
    await t.pumpAndSettle();

    final tops = {
      for (final chip in t.widgetList<Container>(
          find.descendant(of: find.byType(Wrap), matching: find.byType(Container))))
        t.getRect(find.byWidget(chip)).top.round()
    };
    expect(tops.length, 1,
        reason: 'the chips are on ${tops.length} lines, not one');
  });

  testWidgets('everything on the screen starts at the same left edge',
      (t) async {
    // Four different left edges ran down this screen: the note was inset by
    // an icon, the headings by 4, the body copy by 4, and the cards by 0.
    await loadRealFonts();
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);

    await t.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const CloudSyncScreen()));
    await t.pump();

    final lefts = <double>[];
    for (final finder in [
      find.textContaining('Servers, posts and follows'),
      find.text('NEED MORE SPACE?'),
      find.textContaining('The App Store sells fixed sizes'),
      find.text('CHAT BACKUP'),
      find.textContaining('encrypted with a key only you hold'),
    ]) {
      lefts.add(t.getRect(finder).left);
    }
    // The cards themselves, which are what the text has to line up with.
    // Found by their shape rather than through a label: the nearest
    // Container above a piece of text is some inner box, not the card.
    // DecoratedBox rather than Container: a Container's rect includes any
    // margin it carries, so a card inset by its own margin still measures
    // as starting at the screen edge.
    var cards = 0;
    for (final box in t.widgetList<DecoratedBox>(find.byType(DecoratedBox))) {
      final decoration = box.decoration;
      if (decoration is! BoxDecoration) continue;
      if (decoration.borderRadius != BorderRadius.circular(14)) continue;
      cards++;
      lefts.add(t.getRect(find.byWidget(box)).left);
    }
    expect(cards, 2, reason: 'the usage card and the plan card');
    for (final left in lefts) {
      expect(left, closeTo(16.0, 0.5),
          reason: 'this block starts at $left, not the screen margin');
    }
  });
}
