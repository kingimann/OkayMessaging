import AudioToolbox
import CallKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  private var screenshotChannel: FlutterMethodChannel?

  /// Digits of the conversation on screen right now, or nil. Dart keeps this
  /// up to date so a push for the chat you are already reading does not draw
  /// a banner over the message the app has already put there.
  private var openChatDigits: String?

  /// Held for the app's lifetime: the mesh owns the two CoreBluetooth
  /// managers, and a released Mesh takes the radio down with it.
  private var mesh: Mesh?

  /// Held for the same reason: the fast nearby transport owns an MCSession
  /// and its advertiser and browser, none of which survive it being released.
  private var nearbyFast: NearbyFast?

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
    // The fast nearby transport, for handing a file to somebody in the room.
    // Same shape: registering wires a channel and nothing else — no radio,
    // no Bonjour, and no Local Network prompt until Dart calls "start".
    let fastMessenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "OkayNearbyFast")!.messenger()
    nearbyFast = NearbyFast.register(with: fastMessenger)
    // Minimal push bridge (no third-party plugin): Dart calls "register",
    // we ask iOS for permission + an APNs token and send it back as hex.
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "OkayPush")!.messenger()
    let channel = FlutterMethodChannel(name: "okay/push", binaryMessenger: messenger)
    pushChannel = channel
    // Taps and foreground arrivals come back through here. Set before the
    // first push can land, and before the permission prompt, so a launch from
    // a notification is not raced by the delegate being assigned late.
    UNUserNotificationCenter.current().delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async {
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            result(granted)
          }
        }
      case "openChat":
        let digits = (call.arguments as? String) ?? ""
        self?.openChatDigits = digits.isEmpty ? nil : digits
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Screenshots. iOS gives NO way to prevent one — only this notification
    // after the fact — so the app's answer is to tell the other person rather
    // than to pretend it can block anything. userDidTakeScreenshotNotification
    // is iOS 7+, so no availability guard is needed here.
    let shotMessenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "OkayScreenshot")!.messenger()
    let shots = FlutterMethodChannel(
      name: "okay/screenshot", binaryMessenger: shotMessenger)
    screenshotChannel = shots
    shots.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "watch":
        // Registered once. A second observer would report every screenshot
        // twice, which reads as two screenshots.
        if self?.watchingScreenshots != true {
          self?.watchingScreenshots = true
          NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
          ) { [weak self] _ in
            self?.screenshotChannel?.invokeMethod("taken", arguments: nil)
          }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var watchingScreenshots = false

  /// The conversation a push belongs to, as the im: URL the app already knows
  /// how to open — the same path a default-messaging-app tap arrives on, so
  /// there is one way into a chat from outside rather than two.
  private static func chatLink(from payload: [AnyHashable: Any]) -> URL? {
    guard let from = payload["from"] as? String else { return nil }
    let digits = from.filter(\.isNumber)
    guard !digits.isEmpty else { return nil }
    return URL(string: "im:+\(digits)")
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

extension AppDelegate {
  /// A push that lands while the app is open.
  ///
  /// Without this iOS shows NOTHING for one — the default is to assume the
  /// app is already telling the user — so somebody on the Servers tab got no
  /// hint that a message had arrived. It is shown unless the chat it belongs
  /// to is the one on screen, where the message itself is already visible and
  /// a banner over it is noise.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let payload = notification.request.content.userInfo
    if let from = payload["from"] as? String,
       !from.isEmpty, from == openChatDigits {
      completionHandler([])
      return
    }
    // .banner is iOS 14; .alert is what says the same thing before that, and
    // this app still ships to iOS 13. Deprecated on 14+, which is why the
    // newer name is used where it exists rather than everywhere.
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  /// A tap on the alert, from the lock screen or anywhere else.
  ///
  /// Lands in the conversation rather than wherever the app happened to be —
  /// through the same im: path a default-messaging-app tap uses, which also
  /// means a tap at cold launch is buffered until Dart asks for it.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
       let url = AppDelegate.chatLink(
        from: response.notification.request.content.userInfo) {
      AppDelegate.deliverLink(url)
    }
    completionHandler()
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
