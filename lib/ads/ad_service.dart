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

  /// Google's published TEST banner units — safe for anyone to load, never
  /// paid, clearly labeled "Test Ad". Debug-only, so a release build with
  /// no real ids shows NOTHING rather than test filler (the no-fake-data
  /// rule, wearing yet another hat).
  static const String _testBannerIos =
      'ca-app-pub-3940256099942544/2934735716';
  static const String _testBannerAndroid =
      'ca-app-pub-3940256099942544/6300978111';

  /// The unit this build should use, or null when ads are off here.
  /// Pure-ish and static so a test can pin every rule.
  static String? bannerUnitFor({
    required bool isWeb,
    required TargetPlatform platform,
    required bool releaseMode,
    String? configuredIos,
    String? configuredAndroid,
  }) {
    if (isWeb) return null; // no AdMob on web, by SDK and by choice
    final configured = switch (platform) {
      TargetPlatform.iOS => configuredIos ?? _bannerIos,
      TargetPlatform.android => configuredAndroid ?? _bannerAndroid,
      _ => '',
    };
    if (configured.isNotEmpty) return configured;
    if (releaseMode) return null; // no ids in release = no ads at all
    return switch (platform) {
      TargetPlatform.iOS => _testBannerIos,
      TargetPlatform.android => _testBannerAndroid,
      _ => null,
    };
  }

  String? get _bannerUnit => bannerUnitFor(
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
        releaseMode: kReleaseMode,
      );

  /// Whether this build shows ads anywhere.
  bool get enabled => _bannerUnit != null;

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
