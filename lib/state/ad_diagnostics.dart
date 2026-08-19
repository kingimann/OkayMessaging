import 'package:flutter/foundation.dart';

import '../ads/ad_service.dart';
import 'self_test.dart';

/// "Check ads" — the probe that answers why no ad is on screen.
///
/// It exists because every way this can fail LOOKS THE SAME. `AdBannerSlot`
/// renders `SizedBox.shrink()` — nothing at all, deliberately, since an empty
/// grey box is a worse thing to show than no box — whether the build was
/// compiled with no unit ids, the SDK never started, or Google simply had no
/// ad to serve. On a phone those three are one symptom; here they are three
/// different sentences with three different fixes.
///
/// The distinction it was built for: **an ad unit id is not the App ID.**
/// `Info.plist` carries `ca-app-pub-…~…` (a tilde) and the SDK needs it to
/// start, but it displays nothing on its own. Every slot needs a unit id
/// (`ca-app-pub-…/…`, a slash) injected at build time. Having the first and
/// not the second is a build that shows no ads and reports nothing wrong.
///
/// Same shape as the other three admin probes: pure [stepsFor] / [verdictFor]
/// feeding the shared [SelfTestScreen], so the reasoning is tested without an
/// ad network.
class AdsSelfTest {
  AdsSelfTest._();

  /// Runs the real thing: reads what this binary was compiled with, then asks
  /// Google for one banner and disposes it.
  static Future<SelfTestReport> run() async {
    final probe = await AdService.instance.probeBanner();
    return reportFor(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      releaseMode: kReleaseMode,
      testAdsFlag: AdService.testAdsFlag,
      bannerUnit: AdService.instance.bannerUnit,
      nativeUnit: AdService.instance.nativeUnit,
      probe: probe,
    );
  }

  /// The whole report, from facts rather than from a device — so a test can
  /// drive every branch.
  static SelfTestReport reportFor({
    required bool isWeb,
    required TargetPlatform platform,
    required bool releaseMode,
    required bool testAdsFlag,
    required String? bannerUnit,
    required String? nativeUnit,
    required AdProbe probe,
  }) {
    final (verdict, faulty) = verdictFor(
      isWeb: isWeb,
      releaseMode: releaseMode,
      testAdsFlag: testAdsFlag,
      bannerUnit: bannerUnit,
      probe: probe,
    );
    return SelfTestReport(
      title: 'Check ads',
      steps: stepsFor(
        isWeb: isWeb,
        platform: platform,
        releaseMode: releaseMode,
        testAdsFlag: testAdsFlag,
        bannerUnit: bannerUnit,
        nativeUnit: nativeUnit,
        probe: probe,
      ),
      verdict: verdict,
      faulty: faulty,
    );
  }

  /// How a unit id reads on the report. An ad unit id is NOT a secret — it is
  /// compiled into every copy of the app and the publisher half is already
  /// public in app-ads.txt — and printing it is the point: "which unit did
  /// this build actually ask with" is the question.
  static String describeUnit(String? unit, String defineName) {
    if (unit == null || unit.isEmpty) {
      return 'not configured — $defineName was empty when this was built';
    }
    return AdService.isTestUnit(unit)
        ? 'Google test unit ($unit) — real ads never serve on this'
        : 'configured ($unit)';
  }

  static List<DiagnosticStep> stepsFor({
    required bool isWeb,
    required TargetPlatform platform,
    required bool releaseMode,
    required bool testAdsFlag,
    required String? bannerUnit,
    required String? nativeUnit,
    required AdProbe probe,
  }) {
    final bannerDefine = platform == TargetPlatform.android
        ? 'ADMOB_BANNER_ANDROID'
        : 'ADMOB_BANNER_IOS';
    final nativeDefine = platform == TargetPlatform.android
        ? 'ADMOB_NATIVE_ANDROID'
        : 'ADMOB_NATIVE_IOS';
    final onTest = bannerUnit != null && AdService.isTestUnit(bannerUnit);
    return [
      DiagnosticStep(
        'Platform',
        isWeb
            ? 'web — AdMob ships no web SDK, so ads are off here by '
                'construction, not by a setting'
            : platform.name,
        isWeb ? CheckState.fail : CheckState.pass,
      ),
      DiagnosticStep(
        'Build',
        '${releaseMode ? 'release' : 'debug'}'
            '${testAdsFlag ? ' · ADMOB_TEST_ADS=true' : ''}',
        CheckState.pass,
      ),
      DiagnosticStep(
        'Banner unit',
        describeUnit(bannerUnit, bannerDefine),
        bannerUnit == null ? CheckState.fail : CheckState.pass,
      ),
      DiagnosticStep(
        'Timeline ad unit',
        describeUnit(nativeUnit, nativeDefine),
        // Never a FAULT on its own: the banners are the ads people notice,
        // and a build can reasonably run without the in-timeline cards.
        nativeUnit == null ? CheckState.unknown : CheckState.pass,
      ),
      DiagnosticStep(
        'Live ad request',
        switch (probe) {
          AdProbe(configured: false) =>
            'not sent — this build has no unit to ask with',
          AdProbe(filled: true) => 'Google returned an ad',
          AdProbe(noFill: true) =>
            'Google had no ad to serve (code 3, "no fill"). Everything on '
                'this device worked; there was simply nothing to show.',
          AdProbe(code: final c, message: final m) => 'refused: $m (code $c)',
        },
        switch (probe) {
          AdProbe(filled: true) => CheckState.pass,
          // A no-fill is not this app's fault, and marking it one would send
          // somebody hunting a bug that isn't there.
          AdProbe(noFill: true) => CheckState.unknown,
          _ => CheckState.fail,
        },
      ),
      // Reported live 2026-08-18: the flag was set, the units were real, and
      // nothing said the flag was doing nothing. The precedence is
      // deliberate — forgetting to remove the flag must not be able to hide
      // real ads once fill starts — but silence about it reads as a setting
      // that did not take.
      if (testAdsFlag && !onTest && bannerUnit != null)
        const DiagnosticStep(
          'ADMOB_TEST_ADS',
          'set, but having no effect — a configured real unit id always '
              'wins, so this build is asking for real ads. Clear the unit '
              'ids if you want Google\'s test ads instead.',
          CheckState.unknown,
        ),
      if (onTest)
        const DiagnosticStep(
          'Test creatives',
          'This build shows Google\'s labelled "Test Ad" placeholders. Take '
              'ADMOB_TEST_ADS back off before shipping — test creatives must '
              'never reach App Store users.',
          CheckState.unknown,
        ),
    ];
  }

  /// The one sentence worth acting on. Ordered by what actually blocks: a
  /// build with no ids can never show an ad however healthy the account is,
  /// so it is named before anything about fill.
  static (String, bool) verdictFor({
    required bool isWeb,
    required bool releaseMode,
    required bool testAdsFlag,
    required String? bannerUnit,
    required AdProbe probe,
  }) {
    if (isWeb) {
      return (
        'Ads are off on the web build by construction — AdMob has no web SDK. '
        'Check on a phone.',
        false,
      );
    }
    if (bannerUnit == null) {
      return (
        'This build has NO ad unit ids compiled into it, so no ad can load '
        'however the AdMob account looks. Set ADMOB_BANNER_IOS and '
        'ADMOB_NATIVE_IOS in the Codemagic "test" variable group and build '
        'again — an ad unit id has a SLASH (ca-app-pub-…/…) and is not the '
        'App ID in Info.plist, which has a tilde. To check placement before '
        'the real ids exist, set ADMOB_TEST_ADS=true instead.',
        true,
      );
    }
    if (probe.noFill) {
      return (
        'Everything on this device is wired correctly — the request reached '
        'Google, which had no ad to serve. That is ordinary for an app with '
        'little traffic, and while app-ads.txt is unverified fewer buyers '
        'will bid. Nothing to fix here; try again later.',
        false,
      );
    }
    if (!probe.filled) {
      return (
        'The ad request was refused: ${probe.message}. A brand-new unit can '
        'take an hour or more before it serves; past that, check the unit id '
        'and that the AdMob app is not restricted.',
        true,
      );
    }
    return (
      'A real ad loaded on this device. If you still see none in the app, '
      'check you are on the Newsfeed or the Marketplace — those are the only '
      'two surfaces that carry ads, deliberately, and never a chat, a call '
      'or a server.',
      false,
    );
  }
}
