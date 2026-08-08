import CoreNFC
import Flutter
import UIKit

// Phone-to-tag "tap to pay" over NFC — the native half of lib/payments/
// nfc_pay.dart. CoreNFC, iOS 13+.
//
// HONEST ABOUT WHAT NFC CAN DO ON iPhone. An iPhone can READ an NFC tag and
// WRITE to a blank one, but it cannot pretend to BE a tag (there is no public
// card-emulation / HCE for third-party apps). So there is no iPhone-to-iPhone
// "hold them together" here — that would need hardware Apple doesn't expose.
// What this does instead is tag-based and real:
//   * read  — the payer taps a tag that holds a pay link (okaymsg://…&pay=1)
//             and the app opens straight into paying that person;
//   * share — the payee writes that same pay link to a blank NFC sticker, so
//             it becomes a reusable "tap to pay me" tag.
// The QR code stays the tap-free path for two phones with no sticker between
// them.
//
// WHY NFCTagReaderSession, NOT NFCNDEFReaderSession. App Store validation
// (Xcode 26 SDK, min iOS 13) rejects the NDEF reader entitlement: it demands
// the `TAG` reader format and DISALLOWS `NDEF` (upload error 90778). So this
// reads and writes NDEF through the *tag* protocol instead — the tag session
// hands us an NFCTag whose associated value conforms to NFCNDEFTag, which is
// where queryNDEFStatus / readNDEF / writeNDEF live. The entitlement is
// therefore `com.apple.developer.nfc.readersession.formats = [TAG]` and there
// is an NFCReaderUsageDescription in Info.plist; without them CoreNFC refuses
// to start a session, which the Dart side treats as "unavailable".
//
// Registered from AppDelegate alongside Mesh/NearbyFast. Registering only wires
// the channel; no session starts and no permission is asked until Dart calls
// "read" or "share". NFCTagReaderSession is iOS 13.0+, the app's deployment
// floor, so it needs no #available guard.
final class NfcPay: NSObject {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "okay/nfcpay", binaryMessenger: messenger)
    let instance = NfcPay()
    // Held by the channel's handler closure, so it lives as long as the engine.
    channel.setMethodCallHandler(instance.handle)
  }

  // Strong refs so an in-flight session isn't deallocated mid-scan.
  private var session: NFCTagReaderSession?
  private var pending: FlutterResult?
  // Set when the session is a write; nil for a read.
  private var messageToWrite: NFCNDEFMessage?

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      // The real runtime check: an NFC-capable iPhone with the reader
      // entitlement. False on iPad / older hardware, and the Dart side then
      // falls back to the QR code.
      result(NFCTagReaderSession.readingAvailable)
    case "read":
      beginRead(result)
    case "share":
      let tag = (call.arguments as? [String: Any])?["tag"] as? String ?? ""
      beginWrite(tag, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Only one NFC operation at a time; a second call while one is live is a no.
  private func busy() -> Bool { pending != nil }

  private func finish(_ value: Any?) {
    let done = pending
    pending = nil
    session = nil
    messageToWrite = nil
    DispatchQueue.main.async { done?(value) }
  }

  // NDEF stickers are almost all ISO 14443 Type A (NTAG21x); ISO 15693 covers
  // the Type 5 tags. Both are polled so the common pay/contact sticker is read.
  private static let polling: NFCTagReaderSession.PollingOption = [
    .iso14443, .iso15693,
  ]

  private func beginRead(_ result: @escaping FlutterResult) {
    guard NFCTagReaderSession.readingAvailable else { return result(nil) }
    if busy() { return result(nil) }
    pending = result
    messageToWrite = nil
    let s = NFCTagReaderSession(
      pollingOption: NfcPay.polling, delegate: self, queue: nil)
    s?.alertMessage = "Hold your phone near the pay tag."
    session = s
    s?.begin()
  }

  private func beginWrite(_ tag: String, _ result: @escaping FlutterResult) {
    guard NFCTagReaderSession.readingAvailable, !tag.isEmpty,
      let url = URL(string: tag),
      let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
    else { return result(false) }
    if busy() { return result(false) }
    pending = result
    messageToWrite = NFCNDEFMessage(records: [payload])
    let s = NFCTagReaderSession(
      pollingOption: NfcPay.polling, delegate: self, queue: nil)
    s?.alertMessage = "Hold your phone near a blank tag to write it."
    session = s
    s?.begin()
  }

  /// The NDEF face of a detected tag, whichever radio protocol found it.
  private func ndef(from tag: NFCTag) -> NFCNDEFTag? {
    switch tag {
    case let .miFare(t): return t
    case let .iso7816(t): return t
    case let .iso15693(t): return t
    case let .feliCa(t): return t
    @unknown default: return nil
    }
  }

  /// The string a read should return: the tag's URI record, or its text record.
  private func stringFrom(_ messages: [NFCNDEFMessage]) -> String? {
    for message in messages {
      for record in message.records {
        if let url = record.wellKnownTypeURIPayload() {
          return url.absoluteString
        }
        let (text, _) = record.wellKnownTypeTextPayload()
        if let text = text, !text.isEmpty {
          return text
        }
      }
    }
    return nil
  }
}

extension NfcPay: NFCTagReaderSessionDelegate {
  // Required. The session is up and polling; nothing to do until a tag lands.
  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  // Required. Fires when the session ends — cancelled, timed out, or done.
  func tagReaderSession(
    _ session: NFCTagReaderSession, didInvalidateWithError error: Error
  ) {
    // A read that never resolved (user cancelled / timeout) answers nothing;
    // a write reports its own success from didDetect, so this is cleanup.
    if pending != nil { finish(messageToWrite == nil ? nil : false) }
  }

  func tagReaderSession(
    _ session: NFCTagReaderSession, didDetect tags: [NFCTag]
  ) {
    guard let tag = tags.first, let ndefTag = ndef(from: tag) else {
      session.invalidate(errorMessage: "That tag isn't supported.")
      return
    }
    session.connect(to: tag) { [weak self] error in
      guard let self = self else { return }
      if error != nil {
        session.invalidate(errorMessage: "Couldn't reach that tag.")
        return  // didInvalidate does the finish
      }
      ndefTag.queryNDEFStatus { status, _, error in
        if let message = self.messageToWrite {
          // Write path: refuse an unusable or locked tag, else write the link.
          if error != nil || status == .notSupported {
            session.invalidate(errorMessage: "That tag can't be written.")
            return
          }
          if status == .readOnly {
            session.invalidate(errorMessage: "That tag is locked.")
            return
          }
          ndefTag.writeNDEF(message) { error in
            if error != nil {
              session.invalidate(errorMessage: "Couldn't write that tag.")
            } else {
              session.alertMessage = "Your pay tag is ready."
              session.invalidate()
              self.finish(true)
            }
          }
        } else {
          // Read path: pull the NDEF message and hand back its link.
          if error != nil || status == .notSupported {
            session.invalidate(errorMessage: "There's nothing on that tag.")
            return
          }
          ndefTag.readNDEF { message, _ in
            let value = message.flatMap { self.stringFrom([$0]) }
            if let value = value {
              session.alertMessage = "Got it."
              session.invalidate()
              self.finish(value)
            } else {
              session.invalidate(errorMessage: "Couldn't read that tag.")
            }
          }
        }
      }
    }
  }
}
