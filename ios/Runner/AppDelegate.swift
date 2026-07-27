import AudioToolbox
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

  // Default-calling-app review (ITMS-91120) requires the binary to actually
  // link CallKit. An enum-case reference constant-folds to an integer and
  // leaves no linkage, which is exactly how build 23 got rejected — so hold
  // a real CallKit object: instantiating the class forces the framework
  // into the load commands.
  private let callObserver = CXCallObserver()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = callObserver
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Ring tones: Dart's ringer loop asks for one native burst at a time.
    // System sound IDs need no bundled audio; the vibrate call is the real
    // ringer vibration, far stronger than a haptic tap.
    let ringMessenger = engineBridge.pluginRegistry.registrar(forPlugin: "OkayRingtone")!.messenger()
    let ring = FlutterMethodChannel(name: "okay/ringtone", binaryMessenger: ringMessenger)
    ring.setMethodCallHandler { call, result in
      if call.method == "burst" {
        let incoming = (call.arguments as? Bool) ?? true
        if incoming {
          AudioServicesPlaySystemSound(1007) // double-chirp alert
          AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        } else {
          AudioServicesPlaySystemSound(1074) // soft ring-back beat
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

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
