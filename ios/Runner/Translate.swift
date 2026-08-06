import Flutter
import Foundation

#if canImport(Translation)
  import Translation
#endif

/// On-device text translation, backed by Apple's Translation framework.
///
/// TWO GUARDS, NOT ONE — the same shape SmartReplies uses. `canImport` is the
/// compile-time guard: the Translation framework's programmatic API only
/// exists in a recent SDK, so an older Xcode compiles this into a stub rather
/// than failing the archive. `@available(iOS 17.4, *)` is the runtime guard:
/// the app deploys to iOS 13, so most phones running this binary have no such
/// API to call into and must get a clean "not available" rather than a crash.
///
/// Nothing here leaves the device. The text arrives from Dart, goes into the
/// on-device translator, and the result comes back — no network, and no
/// `print` of message text. This is what lets a Translate button sit on an
/// end-to-end-encrypted chat without breaking the promise that message bodies
/// are never readable off-device.
enum Translate {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "okay/translate", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "available":
        result(isAvailable)
      case "translate":
        guard let args = call.arguments as? [String: Any],
          let text = args["text"] as? String,
          let target = args["target"] as? String
        else {
          result(FlutterError(
            code: "bad_args", message: "text and target required",
            details: nil))
          return
        }
        translate(text: text, target: target, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static var isAvailable: Bool {
    #if canImport(Translation)
      if #available(iOS 17.4, *) { return true }
      return false
    #else
      return false
    #endif
  }

  private static func translate(
    text: String, target: String, result: @escaping FlutterResult
  ) {
    #if canImport(Translation)
      if #available(iOS 17.4, *) {
        Task {
          do {
            // A session with no fixed source language lets the framework
            // detect it; the target is the language the reader picked.
            let session = TranslationSession(
              installedSource: nil,
              target: Locale.Language(identifier: target))
            let response = try await session.translate(text)
            result(response.targetText)
          } catch {
            // A missing language pack the user declined to download, or an
            // unsupported pair — a null answer the Dart side shows as
            // "couldn't translate", never an error banner.
            result(nil)
          }
        }
        return
      }
    #endif
    result(nil)
  }
}
