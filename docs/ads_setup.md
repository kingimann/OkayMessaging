# Ads setup (AdMob, non-personalized)

**The stance, baked into the code:** ads exist only on the two
world-readable surfaces — the public newsfeed and the marketplace — as
banners at the bottom of the screen. Never in chats, calls, or servers (a
test enforces it). Every request is **non-personalized** (`npa=1`): no
tracking, no App Tracking Transparency prompt, and the App Store privacy
label stays free of "data used to track you". Release builds with no ad
ids show **nothing** — not placeholders, not test ads.

## What's already wired

- `google_mobile_ads` dependency (a NEW iOS pod — first place to look if
  the next Codemagic build fails).
- `lib/ads/ad_service.dart` + `AdBannerSlot` on the two surfaces; zero
  height until an ad actually loads.
- `Info.plist` carries Google's published **sample** application id so the
  SDK can exist; debug builds show Google's labeled test ads.
- `codemagic.yaml` passes `--dart-define=ADMOB_BANNER_IOS=$ADMOB_BANNER_IOS`
  (empty until the variable exists → ads stay off).

## Turning real ads on

1. Create an AdMob account at <https://admob.google.com> (uses your Google
   account; payouts need AdSense payment details).
2. Add an **app** (iOS, `com.okaymessaging`). AdMob issues an
   **App ID** like `ca-app-pub-XXXX~YYYY`.
3. In `ios/Runner/Info.plist`, replace the sample `GADApplicationIdentifier`
   value with that App ID. (This is the one step that edits the repo.)
4. In the app's AdMob page, create a **Banner** ad unit. It issues a
   **unit id** like `ca-app-pub-XXXX/ZZZZ`.
5. In Codemagic, add `ADMOB_BANNER_IOS` = that unit id to the **test**
   variable group (same place as `KLIPY_API_KEY`).
6. Build. Banners appear on Newsfeed and Marketplace once AdMob starts
   serving (new accounts/units can take hours to fill; blank is normal on
   day one).

New apps must also be **verified in AdMob** (App Store listing link once
the app is public) before payouts; test ads in debug builds work with no
account at all.
