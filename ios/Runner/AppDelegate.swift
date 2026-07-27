import CallKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?

  // Incoming im: links (default-messaging-app taps). A link can arrive at
  // cold launch before Dart is up, so buffer it until Dart asks.
  static var linkChannel: FlutterMethodChannel?
  static var pendingLink: String?

  /// Delivers an im: URL to Dart, or parks it for the "getInitial" pull.
  static func deliverLink(_ url: URL) {
    let s = url.absoluteString
    if let channel = linkChannel {
      channel.invokeMethod("link", arguments: s)
    } else {
      pendingLink = s
    }
  }

  // Default-calling-app review requires linking CallKit (or PushKit); the
  // referenced type keeps the framework from being stripped as unused.
  private static let callHandleType: CXHandle.HandleType = .phoneNumber

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = AppDelegate.callHandleType
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Default-messaging-app links: Dart listens for "link" pushes and pulls
    // any URL that arrived before it was ready.
    let linkMessenger = engineBridge.pluginRegistry.registrar(forPlugin: "OkayLinks")!.messenger()
    let links = FlutterMethodChannel(name: "okay/links", binaryMessenger: linkMessenger)
    AppDelegate.linkChannel = links
    links.setMethodCallHandler { call, result in
      if call.method == "getInitial" {
        result(AppDelegate.pendingLink)
        AppDelegate.pendingLink = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    // Minimal push bridge (no third-party plugin): Dart calls "register",
    // we ask iOS for permission + an APNs token and send it back as hex.
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "OkayPush")!.messenger()
    let channel = FlutterMethodChannel(name: "okay/push", binaryMessenger: messenger)
    pushChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "register" {
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async {
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            result(granted)
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod("token", arguments: hex)
    super.application(application,
        didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
