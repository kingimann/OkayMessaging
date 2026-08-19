import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Ads, held to the app's own rules.
///
/// WHERE THEY MAY EXIST: the public newsfeed and the marketplace — the two
/// surfaces that are world-readable by design. Never chats, never calls,
/// never servers; a privacy messenger with an ad inside a conversation has
/// broken its one promise, and a test pins that no chat file reaches for
/// this one.
///
/// WHAT KIND: **non-personalized only** (`npa=1` on every request). No
/// tracking, no App Tracking Transparency prompt, no device-graph SDK
/// behavior — the ad is chosen by context, not by profiling the person.
/// That earns less per impression and is the right trade for this app.
///
/// WHEN THEY EXIST AT ALL: only when a banner unit id is configured at
/// build time (`--dart-define=ADMOB_BANNER_IOS=...`), the same pattern as
/// the GIF key — nothing in the repo, off silently when absent. Debug
/// builds use Google's official TEST units so the wiring is verifiable
/// without an account. Web has no AdMob at all, so the service is inert
/// there by construction.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  /// Real banner unit ids, injected at build time. Empty = ads off.
  static const String _bannerIos =
      String.fromEnvironment('ADMOB_BANNER_IOS', defaultValue: '');
  static const String _bannerAndroid =
      String.fromEnvironment('ADMOB_BANNER_ANDROID', defaultValue: '');

  /// Real native unit ids, injected the same way. Empty = no native ads.
  static const String _nativeIos =
      String.fromEnvironment('ADMOB_NATIVE_IOS', defaultValue: '');
  static const String _nativeAndroid =
      String.fromEnvironment('ADMOB_NATIVE_ANDROID', defaultValue: '');

  /// Owner's escape hatch: `ADMOB_TEST_ADS=true` makes RELEASE builds use
  /// Google's labeled test units, so placement is verifiable on a TestFlight
  /// phone while AdMob verification still blocks real fill. Off by default,
  /// and meant to be removed again — test creatives must never reach App
  /// Store users.
  ///
  /// **It WINS over a configured real unit id (2026-08-18, the owner's
  /// call), reversing the original rule.** Real-id-wins was chosen so that
  /// forgetting to remove the flag could never hide real ads once fill
  /// started — defensible, and it made the flag inert in exactly the
  /// situation it was written for. That situation then happened: real ids
  /// configured, the flag set, and no way to see a single ad because the
  /// app is unpublished and every request comes back no-fill. A flag that
  /// cannot do its one job is worse than the risk it was avoiding.
  ///
  /// The risk is answered rather than ignored: "Check ads" turns its whole
  /// verdict RED for a release build running on test units and says the
  /// build must not be shipped. Google's creatives also label themselves
  /// "Test Ad", so this is visible from two directions.
  static const bool _testAdsFlag =
      bool.fromEnvironment('ADMOB_TEST_ADS', defaultValue: false);

  /// Google's published TEST units — safe for anyone to load, never
  /// paid, clearly labeled "Test Ad". Debug-only, so a release build with
  /// no real ids shows NOTHING rather than test filler (the no-fake-data
  /// rule, wearing yet another hat).
  static const String _testBannerIos =
      'ca-app-pub-3940256099942544/2934735716';
  static const String _testBannerAndroid =
      'ca-app-pub-3940256099942544/6300978111';
  static const String _testNativeIos =
      'ca-app-pub-3940256099942544/3986624511';
  static const String _testNativeAndroid =
      'ca-app-pub-3940256099942544/2247696110';

  /// The unit this build should use, or null when ads are off here.
  /// Pure-ish and static so a test can pin every rule.
  static String? bannerUnitFor({
    required bool isWeb,
    required TargetPlatform platform,
    required bool releaseMode,
    bool testAds = false,
    String? configuredIos,
    String? configuredAndroid,
  }) {
    if (isWeb) return null; // no AdMob on web, by SDK and by choice
    final configured = switch (platform) {
      TargetPlatform.iOS => configuredIos ?? _bannerIos,
      TargetPlatform.android => configuredAndroid ?? _bannerAndroid,
      _ => '',
    };
    // An explicit ADMOB_TEST_ADS=true beats a configured id — see the flag.
    if (!testAds && configured.isNotEmpty) return configured;
    if (releaseMode && !testAds) return null; // no ids in release = no ads
    return switch (platform) {
      TargetPlatform.iOS => _testBannerIos,
      TargetPlatform.android => _testBannerAndroid,
      _ => null,
    };
  }

  /// Same rules, native unit. Kept separate rather than parameterized so a
  /// test failure names the surface that broke.
  static String? nativeUnitFor({
    required bool isWeb,
    required TargetPlatform platform,
    required bool releaseMode,
    bool testAds = false,
    String? configuredIos,
    String? configuredAndroid,
  }) {
    if (isWeb) return null;
    final configured = switch (platform) {
      TargetPlatform.iOS => configuredIos ?? _nativeIos,
      TargetPlatform.android => configuredAndroid ?? _nativeAndroid,
      _ => '',
    };
    if (!testAds && configured.isNotEmpty) return configured;
    if (releaseMode && !testAds) return null;
    return switch (platform) {
      TargetPlatform.iOS => _testNativeIos,
      TargetPlatform.android => _testNativeAndroid,
      _ => null,
    };
  }

  String? get _bannerUnit => bannerUnitFor(
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
        releaseMode: kReleaseMode,
        testAds: _testAdsFlag,
      );

  String? get _nativeUnit => nativeUnitFor(
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
        releaseMode: kReleaseMode,
        testAds: _testAdsFlag,
      );

  /// The unit this build would actually ask Google for, or null when ads are
  /// off here. Public so the "Check ads" self-test can say WHICH unit was
  /// tried — the question a dashboard cannot answer, because AdMob knows what
  /// it would serve and nothing about what this binary was compiled with.
  String? get bannerUnit => _bannerUnit;
  String? get nativeUnit => _nativeUnit;

  /// Whether `ADMOB_TEST_ADS=true` was set at build time.
  static bool get testAdsFlag => _testAdsFlag;

  /// Whether [id] is one of Google's published test units rather than a real
  /// one. Read off the same constants the units are chosen from, so the
  /// self-test cannot come to a different answer than the loader did.
  static bool isTestUnit(String id) => const {
        _testBannerIos,
        _testBannerAndroid,
        _testNativeIos,
        _testNativeAndroid,
      }.contains(id);

  /// Whether this build shows ads anywhere.
  bool get enabled => _bannerUnit != null;

  /// Whether in-timeline native ads are on for this build.
  bool get nativeEnabled => _nativeUnit != null;

  /// The public-feed timeline with ad slots dealt in: each element is a
  /// post index, or `-1 - slot` for the slot-th native ad. One ad after
  /// every [every] posts, never as the trailing element — a short feed
  /// must read as content, not filler. Pure, so a test can pin the deal.
  static List<int> timelineWithAds(int postCount,
      {required bool adsEnabled, int every = 8}) {
    final out = <int>[];
    var slot = 0;
    for (var p = 0; p < postCount; p++) {
      out.add(p);
      if (adsEnabled && (p + 1) % every == 0 && p != postCount - 1) {
        out.add(-1 - slot++);
      }
    }
    return out;
  }

  bool _initialized = false;

  /// Initializes the SDK lazily — only ever called from a surface about to
  /// show an ad, so a build with ads off never touches the SDK at all.
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await MobileAds.instance.initialize();
    } catch (_) {
      // Missing plist id / SDK unavailable: surfaces simply stay ad-free.
    }
  }

  /// A non-personalized banner request — npa=1 is the whole privacy story.
  static AdRequest request() =>
      const AdRequest(nonPersonalizedAds: true);

  /// Loads one native ad, drawn by the SDK's own medium template — no
  /// platform factory code, and the "Ad" attribution badge is the SDK's,
  /// not ours to get wrong. The caller owns disposal.
  Future<NativeAd?> loadNative({required void Function() onLoaded}) async {
    final unit = _nativeUnit;
    if (unit == null) return null;
    await _ensureInitialized();
    try {
      final ad = NativeAd(
        adUnitId: unit,
        nativeTemplateStyle:
            NativeTemplateStyle(templateType: TemplateType.medium),
        request: request(),
        listener: NativeAdListener(
          onAdLoaded: (_) => onLoaded(),
          onAdFailedToLoad: (ad, _) => ad.dispose(),
        ),
      );
      await ad.load();
      return ad;
    } catch (_) {
      return null;
    }
  }

  /// Loads one banner. The caller owns disposal.
  Future<BannerAd?> loadBanner({required void Function() onLoaded}) async {
    final unit = _bannerUnit;
    if (unit == null) return null;
    await _ensureInitialized();
    try {
      final ad = BannerAd(
        adUnitId: unit,
        size: AdSize.banner,
        request: request(),
        listener: BannerAdListener(
          onAdLoaded: (_) => onLoaded(),
          onAdFailedToLoad: (ad, _) => ad.dispose(),
        ),
      );
      await ad.load();
      return ad;
    } catch (_) {
      return null;
    }
  }

  /// Asks Google for one banner and reports what came back — the live half of
  /// the "Check ads" self-test.
  ///
  /// **A NO-FILL IS NOT A FAULT**, and telling the two apart is the whole
  /// reason this exists: `AdBannerSlot` renders `SizedBox.shrink()` whether
  /// ads were compiled out, the SDK failed to start, or Google simply had
  /// nothing to serve. On screen those are identical; here they are three
  /// different sentences.
  ///
  /// The ad is disposed either way — this is a probe, not a placement, and an
  /// impression nobody saw would be one the reports could not explain.
  Future<AdProbe> probeBanner() async {
    final unit = _bannerUnit;
    if (unit == null) return const AdProbe.notConfigured();
    try {
      await _ensureInitialized();
    } catch (e) {
      return AdProbe.error(-1, 'the ad SDK would not start: $e');
    }
    AdProbe refused(int code, String message) => AdProbe.error(code, message,
        noFill: AdProbe.isNoFill(code, message, defaultTargetPlatform));
    final done = Completer<AdProbe>();
    try {
      final ad = BannerAd(
        adUnitId: unit,
        size: AdSize.banner,
        request: request(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            ad.dispose();
            if (!done.isCompleted) done.complete(const AdProbe.loaded());
          },
          onAdFailedToLoad: (ad, err) {
            ad.dispose();
            if (!done.isCompleted) {
              done.complete(refused(err.code, err.message));
            }
          },
        ),
      );
      await ad.load();
    } catch (e) {
      return AdProbe.error(-1, '$e');
    }
    // A request that never comes back at all is its own answer, and a probe
    // that hangs is worse than one that says it timed out.
    return done.future.timeout(const Duration(seconds: 12),
        onTimeout: () => const AdProbe.error(-2, 'no answer within 12 seconds'));
  }
}

/// What one live ad request came back as.
class AdProbe {
  const AdProbe.loaded()
      : configured = true,
        filled = true,
        code = 0,
        message = '',
        noFill = false;
  const AdProbe.notConfigured()
      : configured = false,
        filled = false,
        code = 0,
        message = '',
        noFill = false;
  const AdProbe.error(this.code, this.message, {this.noFill = false})
      : configured = true,
        filled = false;

  /// Whether an error code means "Google had no ad", which is NOT a fault.
  ///
  /// **The code differs by platform, and getting it wrong is precisely the
  /// mistake this probe exists to prevent.** It shipped checking only `3` —
  /// ANDROID's `ERROR_CODE_NO_FILL` — and on a real iPhone classified iOS's
  /// no-fill as a refusal, telling the owner to go check a unit id that was
  /// perfectly fine. iOS `GADErrorCode.noFill` is **1**; on iOS `3` is a
  /// SERVER ERROR, which really is a fault. The plugin passes the native
  /// code straight through and keeps no table of its own, so there is
  /// nothing between these numbers and the platform.
  ///
  /// The message is checked too, because a code table is exactly the kind of
  /// thing that shifts under you — but only as a second opinion, since it is
  /// English and could be localised.
  static bool isNoFill(int code, String message, TargetPlatform platform) {
    final byCode = platform == TargetPlatform.android ? code == 3 : code == 1;
    final m = message.toLowerCase();
    return byCode || m.contains('no ad to show') || m.contains('no fill');
  }

  /// Whether this build had a unit to ask with at all.
  final bool configured;

  /// Whether Google actually returned an ad.
  final bool filled;

  /// The platform's own error code, passed through by the plugin. -1 is a
  /// thrown exception and -2 a timeout, both this app's own. Which number
  /// means "no fill" depends on the platform — see [isNoFill].
  final int code;
  final String message;

  /// Whether the failure is Google having no ad, rather than anything wrong.
  /// Decided at construction by [isNoFill], because [AdProbe] does not know
  /// which platform it is on and a bare `code == n` here was wrong once.
  final bool noFill;
}

/// A banner slot for the two public surfaces: takes no space at all until
/// an ad really loaded (an empty gray box is a broken promise about
/// content), and is plainly labeled by AdMob itself.
class AdBannerSlot extends StatefulWidget {
  const AdBannerSlot({super.key});

  @override
  State<AdBannerSlot> createState() => _AdBannerSlotState();
}

class _AdBannerSlotState extends State<AdBannerSlot> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (AdService.instance.enabled) {
      AdService.instance.loadBanner(onLoaded: () {
        if (mounted) setState(() => _loaded = true);
      }).then((ad) {
        if (!mounted) {
          ad?.dispose();
          return;
        }
        setState(() => _ad = ad);
      });
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}

/// One native ad card in the public-feed timeline. Zero-height until an ad
/// really filled — an empty frame between posts is a broken promise about
/// content — and kept alive once loaded, so scrolling past and back does
/// not bill a fresh impression for the same slot.
class NativeAdCard extends StatefulWidget {
  const NativeAdCard({super.key});

  @override
  State<NativeAdCard> createState() => _NativeAdCardState();
}

class _NativeAdCardState extends State<NativeAdCard>
    with AutomaticKeepAliveClientMixin {
  NativeAd? _ad;
  bool _loaded = false;

  @override
  bool get wantKeepAlive => _loaded;

  @override
  void initState() {
    super.initState();
    if (AdService.instance.nativeEnabled) {
      AdService.instance.loadNative(onLoaded: () {
        if (mounted) setState(() => _loaded = true);
      }).then((ad) {
        if (!mounted) {
          ad?.dispose();
          return;
        }
        setState(() => _ad = ad);
      });
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    // The medium template needs real height to draw its media view; 320 is
    // the SDK's own recommended minimum for it.
    return SizedBox(height: 320, child: AdWidget(ad: ad));
  }
}
