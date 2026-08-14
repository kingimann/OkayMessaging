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

/// Where this Flutter keeps the Roboto it ships, or null if it can't be found.
///
/// ASKED, NOT ASSUMED. This was the literal path on the machine it was written
/// on — `/opt/flutter/bin/cache/artifacts/material_fonts` — which is nowhere
/// on the macOS runner that builds the iOS release, so every test in this file
/// threw before it measured anything and the build went red.
Directory? _materialFonts() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?
        when root.isNotEmpty)
      '$root/bin/cache/artifacts/material_fonts',
    // flutter_tester runs from
    // <flutter>/bin/cache/artifacts/engine/<host>/flutter_tester, so the
    // fonts are a sibling of `engine` two levels up.
    '${File(Platform.resolvedExecutable).parent.parent.parent.path}'
        '/material_fonts',
  ];
  for (final path in candidates) {
    final dir = Directory(path);
    if (File('${dir.path}/Roboto-Regular.ttf').existsSync()) return dir;
  }
  return null;
}

/// Loads the real Roboto, and says whether the type being measured is now the
/// type that ships.
///
/// The bytes are read SYNCHRONOUSLY on purpose: a testWidgets body runs in
/// fake async, so a real File future never completes and the run hangs with no
/// output and no error.
Future<bool> loadRealFonts() async {
  final dir = _materialFonts();
  if (dir == null) return false;
  try {
    final loader = FontLoader('Roboto');
    for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']) {
      // Only what is there. A cache missing one weight should leave these
      // tests unable to measure, not throw out of a build.
      final file = File('${dir.path}/$f');
      if (!file.existsSync()) continue;
      loader.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  } catch (_) {
    return false;
  }
  // Proving it, rather than trusting the path: the test font draws every
  // glyph as the same square, so under it 'iiiiiiiiii' and 'MMMMMMMMMM' are
  // exactly as wide as each other. Under real Roboto they are not close.
  return _width('iiiiiiiiii') < _width('MMMMMMMMMM') * 0.75;
}

double _width(String text) {
  final painter = TextPainter(
    text: TextSpan(
        text: text,
        style: const TextStyle(fontFamily: 'Roboto', fontSize: 20)),
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width;
}

/// Skips the running test when this machine has no real type to measure with.
/// A skip is visible in the output; a measurement taken in the test font would
/// silently be an answer about a font the app does not ship.
bool _needsRealType(bool loaded) {
  if (loaded) return false;
  markTestSkipped('no material_fonts on this machine — nothing to measure');
  return true;
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
    if (_needsRealType(await loadRealFonts())) return;
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
    // By tooltip, not by text: the strip draws glyphs now.
    final tabs = t.getRect(find.byTooltip(ProfileTab.replies.label));
    for (final finder in [
      find.text('@iman'),
      find.textContaining('privacy-first'),
      find.text('okaymessaging.com'),
      find.text('Following'),
      find.text('Okay Score'),
    ]) {
      final bottom = t.getRect(finder).bottom;
      expect(bottom, lessThan(tabs.top),
          reason: 'this ends at $bottom, under the tabs at ${tabs.top}');
    }
    // And the strip itself is well clear of the fold.
    //
    // This number survived the X header coming back (2026-08-14) and the
    // reason is worth recording, because the obvious guess is wrong: the
    // header costs a band plus an overhang, but the action buttons moved
    // INSIDE it and they used to take a row of their own. Measured 466
    // before and 505 after — thirty-nine points, not a hundred and twenty.
    // The old note here predicted "near 570" for a banner's return and was
    // written about a 92pt rounded card with a separate button row under it.
    //
    // Fifteen points of headroom is not much. The band is the only part of
    // the header that is decoration, so it is the part to shorten if this
    // ever needs to give — it already came down from 84 to 68 to buy the
    // strip an honest height (see `_AvatarRow._height`).
    expect(tabs.bottom, lessThan(520.0),
        reason: 'the tab strip is at ${tabs.bottom} — the header is eating '
            'the screen again');
    // The header itself is really drawn, not merely budgeted for: the face
    // hangs BELOW the band's bottom edge, which is the whole silhouette.
    final band = t.getRect(find.byKey(const ValueKey('profileBand')));
    final face = t.getRect(find.byKey(const ValueKey('profileAvatarRing')));
    expect(face.bottom, greaterThan(band.bottom),
        reason: 'the avatar does not overhang the band');
    expect(face.top, lessThan(band.bottom),
        reason: 'the avatar is below the band rather than over it');
    // Edge to edge: a band inset in a margin reads as a card on the page
    // rather than the top of it.
    expect(band.left, 0.0);
    expect(band.right, 390.0);
  });

  testWidgets('the profile metadata shares one row, X-style', (t) async {
    // Where you are, your link and when you joined used to be three stacked
    // rows, each spending a whole line on a handful of words — which is
    // what pushed the counts down the page. X puts them on one wrapped
    // line, and this measures that they really share it rather than merely
    // being written next to each other in the source.
    if (_needsRealType(await loadRealFonts())) return;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    addTearDown(PublicFeedStore.instance.resetForTest);
    AppState.profile.value = AppUser(
        id: 'me',
        name: 'Iman Fakhar',
        avatarColor: '#2E7D32',
        username: 'iman',
        location: 'Halifax',
        link: 'okaymessaging.com',
        joinedAt: DateTime(2026, 3, 2));
    addTearDown(AppState.resetForTest);
    PublicFeedStore.debugProfileOverride = (username) async => [];

    await t.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const PublicProfileScreen(
            username: 'iman', name: 'Iman Fakhar')));
    await t.pumpAndSettle();

    final place = t.getRect(find.text('Halifax'));
    final link = t.getRect(find.text('okaymessaging.com'));
    final joined = t.getRect(find.text('Joined March 2026'));
    // They FLOW: the first two share a line, second to the right of first.
    expect(link.top, closeTo(place.top, 0.5));
    expect(link.left, greaterThan(place.right));
    // The third wraps at this width rather than squeezing — which is what
    // X does too, and is the point of a Wrap over a Row. What it must not
    // do is stack: three items on three lines is the layout this replaced.
    expect(joined.top, greaterThan(place.top));
    expect(joined.left, closeTo(place.left, 0.5));
    // Two lines, not three. Measured end to end rather than by counting
    // widgets, because "it looks stacked" is a height, not a tree shape.
    expect(joined.bottom - place.top, lessThan(56.0),
        reason: 'the metadata is ${joined.bottom - place.top} tall — that is '
            'three stacked rows again, not a wrapped one');
    // And nothing runs off the screen it is laid out for.
    expect(link.right, lessThan(390.0));
  });

  testWidgets('the three verification chips fit on one line', (t) async {
    if (_needsRealType(await loadRealFonts())) return;
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
        reason: 'the chips are on ${tops.length} lines, not one — tops $tops');
  });

  testWidgets('everything on the screen starts at the same left edge',
      (t) async {
    // Four different left edges ran down this screen: the note was inset by
    // an icon, the headings by 4, the body copy by 4, and the cards by 0.
    if (_needsRealType(await loadRealFonts())) return;
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
          reason: 'this block starts at $left, not the screen margin — all '
              'of them: $lefts');
    }
  });
}
