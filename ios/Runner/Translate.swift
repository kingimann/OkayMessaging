import Flutter
import Foundation

/// On-device text translation channel (`okay/translate`).
///
/// COMPILE-SAFE STUB. Apple's Translation framework does not expose a
/// constructable `TranslationSession` — it is vended only through SwiftUI's
/// `.translationTask` modifier (iOS 18+), which means a working implementation
/// has to host an off-screen SwiftUI view and drive it from the channel. That
/// is deliberately NOT done here yet: an earlier attempt to construct the
/// session directly failed the Codemagic archive, and there is no Xcode on the
/// box these sessions run on to catch that before a build. So this reports
/// "unavailable", the Dart side (`TranslateService`) degrades to "translation
/// isn't available on this device", and nothing breaks. The real
/// `.translationTask` implementation is a follow-up whose only test is a device
/// build — write it carefully or not at all.
enum Translate {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "okay/translate", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "available":
        result(false)
      case "translate":
        // No on-device translator wired up yet — a null answer the Dart side
        // shows as "couldn't translate", never a crash.
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
