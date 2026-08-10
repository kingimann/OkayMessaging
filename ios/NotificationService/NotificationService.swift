import CryptoKit
import UserNotifications

/// Turns "New message" into what somebody actually said, without the words
/// ever being readable off this device.
///
/// A push is composed on the SENDER's phone and travels through the relay and
/// then Apple. Anything legible in it is plaintext handed to both, which is
/// the one promise this app does not break — so the banner has always carried
/// a content-free label. Here the words arrive sealed, under a key only this
/// device can derive, and this extension opens them in the moment between
/// delivery and the banner being drawn. The relay forwarded bytes it could
/// not read, exactly as it does for the message itself.
///
/// **Why this does not run the ratchet.** An extension is a separate process
/// with a hard memory ceiling near 24 MB. It cannot host a Flutter engine, so
/// it cannot run the Double Ratchet, which lives in Dart. Reimplementing the
/// ratchet here would mean a SECOND crypto implementation with its own state
/// to keep in step with the app's — the way "Couldn't unlock this message"
/// happened once already. So the preview rides a key both devices derive
/// independently from identity keys they already hold, and all this code does
/// is one AES-GCM open.
///
/// The payload is base64 `nonce(12) ‖ ciphertext ‖ tag(16)`, which is exactly
/// what `AES.GCM.SealedBox(combined:)` takes. That is not a coincidence — the
/// Dart side emits that layout so there is no framing code here to get wrong,
/// in a language the project's own gates cannot compile.
///
/// **Every failure lands on the same branch: leave the alert alone.** A
/// missing key, a wrong key, a touched payload, a sender this device has
/// never exchanged keys with — all of them fall through to the content-free
/// body the push already carried. A wrong banner is worse than a vague one,
/// so there is no path here that invents text.
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    /// Shared with the app so both read the same keys. The app writes one
    /// entry per contact; nothing else in the keychain is reachable from
    /// here.
    static let keychainGroup = "$(AppIdentifierPrefix)com.okaymessaging.shared"

    /// Must match `NotificationPreview` on the Dart side.
    static let keyPrefix = "okay_notify_key_"

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttempt = mutable
        guard let content = mutable else {
            contentHandler(request.content)
            return
        }

        let info = request.content.userInfo
        // `p` is the sealed preview, `from` the sender's digits — both sit
        // beside `aps`, never inside it, because Apple owns that dictionary.
        guard let sealed = info["p"] as? String, !sealed.isEmpty,
              let from = info["from"] as? String, !from.isEmpty,
              let key = Self.previewKey(forSender: from),
              let text = Self.open(sealed: sealed, key: key)
        else {
            // Nothing to open, or it would not open. The push's own body
            // stands — it was written to be safe on its own precisely so
            // this branch is never a broken-looking notification.
            contentHandler(content)
            return
        }

        content.body = text
        // Stack this conversation's alerts together instead of interleaving
        // them with every other chat. Only set once there is real text: a
        // thread of identical "New message" rows is worse than a list.
        content.threadIdentifier = from
        contentHandler(content)
    }

    /// iOS is about to run out of patience. Hand back whatever we have —
    /// which is the original alert if the open has not finished.
    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    /// The 32-byte AES key the app derived for this sender and left in the
    /// shared keychain. Returns nil for a sender this device holds no key
    /// for, which is a real and expected case — an identity key it has never
    /// seen means there was no secret to derive from.
    static func previewKey(forSender digits: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyPrefix + digits,
            kSecAttrAccessGroup as String: keychainGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    /// One AES-GCM open over the combined box. Any throw means the tag failed
    /// — wrong key or a touched payload — and the caller leaves the alert as
    /// it arrived.
    static func open(sealed: String, key: SymmetricKey) -> String? {
        guard let raw = Data(base64Encoded: sealed), raw.count > 12 + 16,
              let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}
