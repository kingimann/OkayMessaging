import AudioToolbox
import CallKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?

  /// Held for the app's lifetime: the mesh owns the two CoreBluetooth
  /// managers, and a released Mesh takes the radio down with it.
  private var mesh: Mesh?

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

  // Real CallKit integration: OkayMessenger calls get the system's call
  // UI — lock-screen answer/end, the green in-call indicator, mute from
  // anywhere. (Instantiating these also satisfies the ITMS-91120 linkage
  // check that bounced build 23.)
  static let callKit = CallKitBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = AppDelegate.callKit
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // CallKit bridge: Dart reports call lifecycle up, system actions
    // (answer / end / mute from the lock screen) flow back down.
    let ckMessenger = engineBridge.pluginRegistry.registrar(forPlugin: "OkayCallKit")!.messenger()
    AppDelegate.callKit.attach(
        FlutterMethodChannel(name: "okay/callkit", binaryMessenger: ckMessenger))
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
    // On-device suggested replies. Apple's model, running in this process —
    // the conversation is never uploaded, which is the only way a feature can
    // read a chat here at all.
    let replyMessenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "OkaySmartReplies")!.messenger()
    SmartReplies.register(with: replyMessenger)
    // Bluetooth mesh. Registering only wires the channel — no radio starts and
    // no permission is asked for until Dart calls "start", which happens only
    // if the user turned the mesh on.
    let meshMessenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "OkayMesh")!.messenger()
    mesh = Mesh.register(with: meshMessenger)
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

/// Reports OkayMessenger calls to CallKit and forwards the system's call
/// actions back to Dart. Audio stays owned by WebRTC — the provider's
/// audio-session hooks deliberately do nothing, since flutter_webrtc
/// configures its own AVAudioSession.
class CallKitBridge: NSObject, CXProviderDelegate {
  private let provider: CXProvider
  private let controller = CXCallController()
  private var channel: FlutterMethodChannel?

  override init() {
    // The argument-less init is iOS 14+; the app still targets 13, so fall
    // back to the (deprecated there, but working) named initializer.
    let config: CXProviderConfiguration
    if #available(iOS 14.0, *) {
      config = CXProviderConfiguration()
    } else {
      config = CXProviderConfiguration(localizedName: "OkayMessenger")
    }
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.phoneNumber, .generic]
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self,
            let args = call.arguments as? [String: Any],
            let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterMethodNotImplemented)
        return
      }
      let name = (args["name"] as? String) ?? "OkayMessenger"
      let video = (args["video"] as? Bool) ?? false
      switch call.method {
      case "outgoing":
        let handle = CXHandle(type: .generic, value: name)
        let start = CXStartCallAction(call: uuid, handle: handle)
        start.isVideo = video
        self.controller.request(CXTransaction(action: start)) { _ in }
        result(nil)
      case "incoming":
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        self.provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
        result(nil)
      case "connected":
        self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        result(nil)
      case "ended":
        let remote = (args["remote"] as? Bool) ?? true
        if remote {
          self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        } else {
          // Locally ended in the Flutter UI — retire it via a transaction so
          // the system UI closes cleanly.
          self.controller.request(
              CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func providerDidReset(_ provider: CXProvider) {
    channel?.invokeMethod("end", arguments: nil)
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    channel?.invokeMethod("answer", arguments: action.callUUID.uuidString)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    channel?.invokeMethod("end", arguments: action.callUUID.uuidString)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    channel?.invokeMethod("mute", arguments: action.isMuted)
    action.fulfill()
  }
}
