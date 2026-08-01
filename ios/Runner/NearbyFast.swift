import Flutter
import Foundation
import MultipeerConnectivity

/// The fast way to hand a file to somebody standing next to you.
///
/// MultipeerConnectivity is Apple's own framework for this, and underneath it
/// uses Bluetooth to find peers and then brings up a direct Wi-Fi link between
/// the two devices — the same trick AirDrop plays with AWDL, which is private
/// and has no public API. The difference is not small: Bluetooth LE moves a
/// few kilobytes a second, this moves megabytes.
///
/// IT IS A SECOND TRANSPORT, NOT A REPLACEMENT. It only exists between two
/// devices that found each other and agreed to connect, and connecting takes a
/// moment. The Bluetooth mesh still carries messages, still finds servers, and
/// still carries a file when this is not up — see NearbyShare on the Dart
/// side, which picks per transfer and falls back without telling anybody.
///
/// WHAT GOES IN THE AIR BEFORE A SESSION EXISTS: a random token, and nothing
/// else. A peer is advertised under a name of Dart's choosing, and Dart mints
/// a fresh meaningless one each time this starts — so browsing the service
/// tells a stranger that somebody nearby runs this app, which the Bluetooth
/// service UUID already tells them, and not who. Who is exchanged over the
/// session, which is encrypted, and only with people the user's findability
/// setting allows. That decision is Dart's; this file never makes it.
///
/// WHAT THIS FILE DOES NOT DO: look inside what it carries. Bytes arrive from
/// Dart and go back to Dart untouched, and nothing here logs them.
///
/// This is NOT AirDrop and cannot be: a third-party app cannot appear in the
/// iOS AirDrop sheet or receive from it. It is the same choreography and the
/// same speed, between two copies of this app.
final class NearbyFast: NSObject {
    /// Bonjour service type. Fifteen characters or fewer, letters, digits and
    /// hyphens — the OS rejects anything else, at runtime, with a crash. It
    /// must also match the NSBonjourServices entries in Info.plist, or iOS 14
    /// and later refuses to browse at all.
    private static let serviceType = "okay-nearby"

    private var channel: FlutterMethodChannel?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var localPeer: MCPeerID?

    /// Connected peers, by the token they are advertised under.
    private var connected: [String: MCPeerID] = [:]

    static func register(with messenger: FlutterBinaryMessenger) -> NearbyFast {
        let fast = NearbyFast()
        let channel = FlutterMethodChannel(
            name: "okay/nearbyfast", binaryMessenger: messenger)
        fast.channel = channel
        channel.setMethodCallHandler { [weak fast] call, result in
            guard let fast = fast else {
                result(nil)
                return
            }
            switch call.method {
            case "available":
                // The framework is on every iPhone this runs on. Whether a
                // peer is reachable is a different question, answered by the
                // peer list rather than by a capability check.
                result(true)
            case "start":
                guard let args = call.arguments as? [String: Any],
                    let token = args["token"] as? String, !token.isEmpty
                else {
                    result(FlutterError(
                        code: "bad_args", message: "token required", details: nil))
                    return
                }
                fast.start(token: token,
                           advertise: (args["advertise"] as? Bool) ?? false)
                result(nil)
            case "advertise":
                fast.setAdvertising((call.arguments as? Bool) ?? false)
                result(nil)
            case "stop":
                fast.stop()
                result(nil)
            case "send":
                guard let args = call.arguments as? [String: Any],
                    let to = args["to"] as? String,
                    let body = args["body"] as? String
                else {
                    result(FlutterError(
                        code: "bad_args", message: "to and body required",
                        details: nil))
                    return
                }
                result(fast.send(to: to, body: body))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        return fast
    }

    private func start(token: String, advertise: Bool) {
        // A restart under a new token is a real request — Dart mints one per
        // run — so tear down rather than ignore it.
        if let peer = localPeer, peer.displayName == token, session != nil {
            setAdvertising(advertise)
            return
        }
        stop()

        // MCPeerID caps displayName at 63 bytes and throws past it. Dart's
        // tokens are twelve hex characters; the trim is here so a future
        // caller cannot crash the app from the Dart side.
        var name = token
        while name.utf8.count > 63 { name = String(name.dropLast()) }
        let peer = MCPeerID(displayName: name)
        localPeer = peer

        // Encrypted whatever else is true. What rides on this is already
        // sealed by Dart, but a transport that can be required to encrypt
        // should be — and the identities exchanged on it are not sealed.
        let session = MCSession(
            peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(
            peer: peer, serviceType: NearbyFast.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        setAdvertising(advertise)
    }

    /// Browsing continues either way. Advertising is what makes this device
    /// answerable by a stranger, so it is the half that the user's findability
    /// setting turns off — and turning it off does not stop them connecting
    /// out to somebody who is advertising.
    private func setAdvertising(_ on: Bool) {
        if on {
            guard advertiser == nil, let peer = localPeer else { return }
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peer, discoveryInfo: nil, serviceType: NearbyFast.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        } else {
            advertiser?.stopAdvertisingPeer()
            advertiser = nil
        }
    }

    private func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        localPeer = nil
        connected.removeAll()
        reportPeers()
    }

    /// Sends one whole body to one peer. Returns whether there was anybody to
    /// send it to — false means Dart should use Bluetooth instead.
    private func send(to: String, body: String) -> Bool {
        guard let session = session, let peer = connected[to],
            let data = body.data(using: .utf8)
        else { return false }
        do {
            // Reliable: a file arriving with a hole in it is worse than one
            // that took a moment longer.
            try session.send(data, toPeers: [peer], with: .reliable)
            return true
        } catch {
            return false
        }
    }

    private func reportPeers() {
        channel?.invokeMethod("peers", arguments: Array(connected.keys))
    }
}

extension NearbyFast: MCSessionDelegate {
    func session(
        _ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState
    ) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.connected[peerID.displayName] = peerID
            case .notConnected:
                self.connected.removeValue(forKey: peerID.displayName)
            case .connecting:
                break
            @unknown default:
                break
            }
            self.reportPeers()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let body = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.channel?.invokeMethod(
                "body", arguments: ["from": peerID.displayName, "body": body])
        }
    }

    // Streams and resources are not used: everything goes as one reliable
    // message, which is what makes the Dart side identical to the Bluetooth
    // path.
    func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {}

    func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
}

extension NearbyFast: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Accepting a SESSION is not accepting a file, and it is not telling
        // them who you are. Everything that arrives on it is still offered to
        // the user first, by NearbyShare — refusing here would mean nobody
        // could ever reach you to ask.
        invitationHandler(true, session)
    }
}

extension NearbyFast: MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard let session = session, let me = localPeer else { return }
        // One side invites, or two phones invite each other and both sessions
        // are torn down. The lower display name does the inviting.
        if me.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.connected.removeValue(forKey: peerID.displayName)
            self.reportPeers()
        }
    }
}
