# Ads setup (AdMob, non-personalized)

**The stance, baked into the code:** ads exist only on the two
world-readable surfaces — the public newsfeed and the marketplace — as
banners at the bottom of the screen, plus **native cards inside the
newsfeed timeline** (one after every 8 posts, never as the last item).
Never in chats, calls, or servers (a test enforces it). Every request is
**non-personalized** (`npa=1`): no tracking, no App Tracking Transparency
prompt, and the App Store privacy label stays free of "data used to track
you". Release builds with no ad ids show **nothing** — not placeholders,
not test ads.

## What's already wired

- `google_mobile_ads` dependency (a NEW iOS pod — first place to look if
  the next Codemagic build fails).
- `lib/ads/ad_service.dart` + `AdBannerSlot` on the two surfaces, and
  `NativeAdCard` (SDK medium template — no platform factory code) dealt
  into the newsfeed by `AdService.timelineWithAds`; both are zero height
  until an ad actually loads.
- `Info.plist` carries the app's real `GADApplicationIdentifier`; debug
  builds show Google's labeled test ads.
- `codemagic.yaml` passes `--dart-define=ADMOB_BANNER_IOS=$ADMOB_BANNER_IOS`
  and `--dart-define=ADMOB_NATIVE_IOS=$ADMOB_NATIVE_IOS` (empty until the
  variables exist → that ad format stays off). Each format is independent:
  a banner id alone shows banners only; a native id alone shows feed cards
  only.
- The build scripts strip ALL whitespace from UI-sourced variables first: a
  trailing newline pasted into the Codemagic field once made flutter read
  the whole `--dart-define` flag as the build target ("Target file ... not
  found", 2026-08-04).

## Turning real ads on

1. Create an AdMob account at <https://admob.google.com> (uses your Google
   account; payouts need AdSense payment details).
2. Add an **app** (iOS, `com.okaymessaging`). AdMob issues an
   **App ID** like `ca-app-pub-XXXX~YYYY`.
3. In `ios/Runner/Info.plist`, replace the sample `GADApplicationIdentifier`
   value with that App ID. (This is the one step that edits the repo.)
4. In the app's AdMob page, create a **Banner** ad unit (and optionally a
   **Native** one). Each issues a **unit id** like `ca-app-pub-XXXX/ZZZZ`.
5. In Codemagic, add `ADMOB_BANNER_IOS` = the banner unit id and
   `ADMOB_NATIVE_IOS` = the native unit id to the **test** variable group
   (same place as `KLIPY_API_KEY`). Paste carefully — no trailing
   spaces/newlines (the build strips them anyway, but keep the value clean).
6. Build. Banners appear on Newsfeed and Marketplace, native cards inside
   the Newsfeed timeline, once AdMob starts serving (new accounts/units can
   take hours to fill; blank is normal on day one).

New apps must also be **verified in AdMob** (App Store listing link once
the app is public) before payouts; test ads in debug builds work with no
account at all.
