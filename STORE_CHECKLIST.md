# App Store & Play Store readiness

Every feature in Okay Messaging is built to run on real devices — WebRTC
audio/video calls and peer-to-peer file transfer are enabled on native
Android/iOS (not just web), and the required runtime permissions and SDK
floors are already configured. What remains are the account- and
identity-level steps that only you can complete, because they tie the app to
*your* developer accounts and domains.

## Already done (in this repo)

- **Android `minSdk` 23** — required by `flutter_webrtc`
  (`android/app/build.gradle.kts`).
- **Android permissions** — camera, microphone, internet, network state,
  Bluetooth, and modify-audio-settings, plus a non-required camera feature
  flag (`android/app/src/main/AndroidManifest.xml`).
- **iOS deployment target 13.0** and usage-description strings for the
  camera (`NSCameraUsageDescription`) and microphone
  (`NSMicrophoneUsageDescription`) in `ios/Runner/Info.plist`.
- End-to-end encryption of the full message payload, so nothing but routing
  data leaves the device in the clear.
- **Bundle identifier `com.okaymessaging`** set on Android (`applicationId`
  and `namespace`) and iOS (`PRODUCT_BUNDLE_IDENTIFIER`). Register this exact
  id when you create the app in App Store Connect and the Play Console.

## You need to do before submitting

1. **Signing**
   - Android: the `release` build is already wired to sign with a real upload
     key when one is available — no code change needed. Just provide the key:
     - **On Codemagic:** upload your keystore under Code signing (reference
       name `okay_keystore`); the build reads the `CM_*` env vars automatically.
     - **Locally:** copy `android/key.properties.example` to
       `android/key.properties` and fill in your keystore path/passwords
       (both are gitignored). Create the keystore with
       `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`.
     - Without either, release builds fall back to the debug key so
       `flutter run --release` still works during development.
   - iOS: set your Apple Developer team and a provisioning profile in Xcode
     (or let Codemagic manage it via the App Store Connect integration).

2. **App icons & splash** — done. A branded icon (white chat bubble + purple
   check) is generated for Android, iOS, and web, and a matching native
   splash screen (logo on brand purple, incl. Android 12) shows on launch.
   To change the art, edit `assets/icon/icon.png` /
   `assets/icon/splash_logo.png` and rerun `dart run flutter_launcher_icons`
   and `dart run flutter_native_splash:create`.

3. **Store metadata** — app name, description, privacy policy URL, and
   screenshots. Because the app is store-nothing and end-to-end encrypted,
   the data-safety / privacy forms should reflect that no message content is
   collected or stored on a server.

4. **Relay backend keys** — the release build reads `SUPABASE_URL` and
   `SUPABASE_ANON_KEY` via `--dart-define`. Make sure your CI / local build
   command passes your project's values (the anon/publishable key is safe to
   ship in the client bundle; never ship the database password).

5. **Optional TURN server** — 1:1 calls use public STUN by default. For
   reliable connectivity behind strict NATs, pass `TURN_URL`,
   `TURN_USERNAME`, and `TURN_CREDENTIAL` via `--dart-define`.

## Build commands

```sh
# Android App Bundle (Play Store)
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...

# iOS archive (App Store) — then distribute from Xcode Organizer
flutter build ipa --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```
