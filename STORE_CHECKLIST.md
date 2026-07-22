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

## You need to do before submitting

1. **Change the bundle identifier** — both platforms currently use the
   Flutter placeholder `com.example.*`, which **both stores reject**. Pick a
   reverse-DNS id from a domain you control (e.g. `com.yourcompany.okay`):
   - Android: `applicationId` in `android/app/build.gradle.kts` (and the
     `namespace` if you want them to match).
   - iOS: `PRODUCT_BUNDLE_IDENTIFIER` in
     `ios/Runner.xcodeproj/project.pbxproj` (or via Xcode → Signing).

2. **Signing**
   - Android: create an upload keystore and wire a `release` `signingConfig`
     (it currently signs with the debug key). See
     <https://docs.flutter.dev/deployment/android#signing-the-app>.
   - iOS: set your Apple Developer team and a provisioning profile in Xcode.

3. **App icons & launch screen** — the project still ships the default
   Flutter launcher icon. Add your own (the `flutter_launcher_icons` package
   makes this a one-command step).

4. **Store metadata** — app name, description, privacy policy URL, and
   screenshots. Because the app is store-nothing and end-to-end encrypted,
   the data-safety / privacy forms should reflect that no message content is
   collected or stored on a server.

5. **Relay backend keys** — the release build reads `SUPABASE_URL` and
   `SUPABASE_ANON_KEY` via `--dart-define`. Make sure your CI / local build
   command passes your project's values (the anon/publishable key is safe to
   ship in the client bundle; never ship the database password).

6. **Optional TURN server** — 1:1 calls use public STUN by default. For
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
