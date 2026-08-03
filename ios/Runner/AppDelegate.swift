import AudioToolbox
import AVFoundation
import CallKit
import CryptoKit
import Flutter
import PushKit
import UIKit
import UserNotifications
import WebRTC

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

  /// PushKit: the VoIP pipe. A push through it launches this app in the
  /// background and MUST report a call to CallKit at once — that is Apple's
  /// contract for the privilege of waking a closed app — which is exactly
  /// what makes a call ring on the lock screen like the phone app.
  private var voipRegistry: PKPushRegistry?

  /// The VoIP token can arrive before the Flutter engine exists to hear
  /// about it; held here until Dart's push channel is up.
  private var pendingVoipToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = AppDelegate.callKit
    let voip = PKPushRegistry(queue: .main)
    voip.delegate = self
    voip.desiredPushTypes = [.voIP]
    voipRegistry = voip
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
    // When the phone is locked and iOS is hiding previews (the system's
    // "Show Previews: When Unlocked" — its default), an alert in this
    // category shows this placeholder instead of its title and body, so the
    // sender's name never sits on a locked screen. Empty options: the
    // .hiddenPreviewsShowTitle flag would put the title back, which is the
    // opposite of the point. The initializer is iOS 11+, under this app's
    // iOS 13 floor, so no availability guard.
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(
        identifier: "okay_msg",
        actions: [],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "New message",
        options: []
      )
    ])
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        // A VoIP token that arrived before Dart was listening goes now.
        if let held = self?.pendingVoipToken {
          self?.pendingVoipToken = nil
          channel.invokeMethod("voipToken", arguments: held)
        }
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async {
            // Registered EVEN WHEN DENIED: a device token needs no alert
            // permission, and without one the server has no row at all —
            // so a person who later flips notifications on in iOS Settings
            // stayed silent forever. With the token uploaded, the grant in
            // Settings is the only thing missing, and it works the moment
            // they give it.
            UIApplication.shared.registerForRemoteNotifications()
            result(granted)
          }
        }
      case "clearBadge":
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
          UIApplication.shared.applicationIconBadgeNumber = 0
        }
        result(nil)
      case "openChat":
        let digits = (call.arguments as? String) ?? ""
        self?.openChatDigits = digits.isEmpty ? nil : digits
        result(nil)
      case "clearDelivered":
        // Private notifications: nothing left behind in Notification Center
        // once the app has been opened — the alert already did its job.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
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
          // Screen RECORDING and AirPlay mirroring never fire the screenshot
          // notification, so without this the one capture that keeps running
          // is the one nothing notices. isCaptured is iOS 11+, below this
          // app's iOS 13 floor, so no availability guard is needed.
          NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
          ) { [weak self] _ in
            self?.screenshotChannel?.invokeMethod(
              "captured", arguments: UIScreen.main.isCaptured)
          }
          self?.watchAppSwitcher()
        }
        // The answer, not just future changes: a recording already running
        // when a chat opens has already fired its notification.
        result(UIScreen.main.isCaptured)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var watchingScreenshots = false
  private var privacyCover: UIView?

  /// Covers the app while it is not frontmost, so the snapshot iOS takes for
  /// the app switcher is not a page of somebody's conversations.
  ///
  /// This is the leak people mistake for screenshot blocking in banking apps,
  /// and unlike a screenshot it is genuinely preventable: the snapshot is
  /// taken after willResignActive and written to disk, where it outlives the
  /// session. Always on rather than per chat — the chat LIST is a page of
  /// names and message previews too.
  ///
  /// Driven off UIApplication's notifications rather than by overriding the
  /// scene delegate: these predate scenes, fire in a scene app all the same,
  /// and need no assumption about what FlutterSceneDelegate implements.
  private func watchAppSwitcher() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.showPrivacyCover() }
    center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.privacyCover?.removeFromSuperview()
      self?.privacyCover = nil
    }
  }

  private func showPrivacyCover() {
    guard privacyCover == nil, let host = coveredWindow() else { return }
    let cover = UIView(frame: host.bounds)
    cover.backgroundColor = UIColor.systemBackground
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let label = UILabel()
    label.text = "OkayMessenger"
    label.font = .systemFont(ofSize: 20, weight: .semibold)
    label.textColor = .label
    label.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
    ])
    host.addSubview(cover)
    privacyCover = cover
  }

  /// The window to cover. `window` is nil in a scene-based app, so fall back
  /// to whichever connected scene owns the key window.
  private func coveredWindow() -> UIWindow? {
    if let w = window { return w }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

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

extension AppDelegate: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    if let channel = pushChannel {
      channel.invokeMethod("voipToken", arguments: hex)
    } else {
      pendingVoipToken = hex
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType
  ) {}

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    // Report to CallKit IMMEDIATELY — Apple terminates apps that take a VoIP
    // push and show no call. The Flutter engine boots in parallel; the call
    // details it needs are queued in the relay mailbox, and the lock-screen
    // answer is parked as an intent until they arrive.
    let dict = payload.dictionaryPayload
    let callId = dict["callId"] as? String ?? UUID().uuidString
    let name = (dict["fromName"] as? String)?.isEmpty == false
      ? dict["fromName"] as! String : "OkayMessenger"
    let video = dict["video"] as? Bool ?? false
    AppDelegate.callKit.reportVoip(
      callId: callId, name: name, video: video, completion: completion)
  }
}

/// Reports OkayMessenger calls to CallKit and forwards the system's call
/// actions back to Dart.
///
/// Audio: once a call is reported to CallKit, iOS owns the AVAudioSession —
/// it activates it when the call is answered and hands it over through
/// `provider(_:didActivate:)`. WebRTC must wait for that handoff, so the
/// bridge puts RTCAudioSession in manual mode and only enables the audio
/// unit inside didActivate. Starting it any earlier fails against the
/// not-yet-active session and the call connects silent — which is exactly
/// what the deliberately-empty hooks here used to cause.
class CallKitBridge: NSObject, CXProviderDelegate {
  private let provider: CXProvider
  private let controller = CXCallController()
  private var channel: FlutterMethodChannel?

  /// Which relay call each CallKit UUID stands for, so a lock-screen action
  /// can tell Dart WHICH call — the VoIP wake acts before Dart has any.
  private var callIdByUuid: [UUID: String] = [:]

  /// Calls already reported by a VoIP push, so Dart's own report of the
  /// same call (it computes the same UUID) is a no-op instead of a second
  /// ring.
  private var reportedVoip: Set<UUID> = []

  /// SHA-256(callId), truncated and stamped into UUID shape. Deterministic
  /// on purpose, and byte-for-byte the same derivation as Dart's
  /// CallKitBridge.uuidFor — a VoIP push (Swift, app closed) and the relay
  /// offer (Dart, app open) must name the SAME system call.
  static func uuidFor(callId: String) -> UUID {
    var b = [UInt8](SHA256.hash(data: Data(callId.utf8)))
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
  }

  /// Rings a call straight off a VoIP push, before any Dart exists.
  func reportVoip(
    callId: String, name: String, video: Bool,
    completion: @escaping () -> Void
  ) {
    let uuid = CallKitBridge.uuidFor(callId: callId)
    callIdByUuid[uuid] = callId
    reportedVoip.insert(uuid)
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: name)
    update.localizedCallerName = name
    update.hasVideo = video
    provider.reportNewIncomingCall(with: uuid, update: update) { _ in
      completion()
    }
  }

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
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = true
    rtc.isAudioEnabled = false
  }

  /// A CallKit report failed (blocked caller, call-group limit), so the
  /// didActivate handoff will never come: let WebRTC drive its own audio
  /// session again or the call would stay silent forever.
  private func audioWithoutCallKit() {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = false
    rtc.isAudioEnabled = true
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
      if let cid = args["callId"] as? String, !cid.isEmpty {
        self.callIdByUuid[uuid] = cid
      }
      switch call.method {
      case "outgoing":
        let handle = CXHandle(type: .generic, value: name)
        let start = CXStartCallAction(call: uuid, handle: handle)
        start.isVideo = video
        self.controller.request(CXTransaction(action: start)) { error in
          if error != nil { self.audioWithoutCallKit() }
        }
        result(nil)
      case "incoming":
        // A VoIP push already rang this exact call (same derived UUID);
        // reporting it again would stack a second system call.
        if self.reportedVoip.contains(uuid) {
          result(nil)
          return
        }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        self.provider.reportNewIncomingCall(with: uuid, update: update) { error in
          if error != nil { self.audioWithoutCallKit() }
        }
        result(nil)
      case "accepted":
        // The user answered in the app's own UI. Answer the CallKit call too,
        // so the system stops ringing and activates the audio session (the
        // didActivate below). When the answer originated from CallKit this
        // duplicate action just errors, which is the desired no-op.
        self.controller.request(
            CXTransaction(action: CXAnswerCallAction(call: uuid))) { _ in }
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
        self.callIdByUuid.removeValue(forKey: uuid)
        self.reportedVoip.remove(uuid)
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
    channel?.invokeMethod("answer", arguments: [
      "uuid": action.callUUID.uuidString,
      "callId": callIdByUuid[action.callUUID] ?? "",
    ])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    channel?.invokeMethod("end", arguments: [
      "uuid": action.callUUID.uuidString,
      "callId": callIdByUuid[action.callUUID] ?? "",
    ])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    channel?.invokeMethod("mute", arguments: action.isMuted)
    action.fulfill()
  }

  // The audio-session handoff. iOS activates the session when the call is
  // answered (or the outgoing call starts) and only then may WebRTC's audio
  // unit run.
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(audioSession)
    rtc.isAudioEnabled = true
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidDeactivate(audioSession)
    rtc.isAudioEnabled = false
  }
}
