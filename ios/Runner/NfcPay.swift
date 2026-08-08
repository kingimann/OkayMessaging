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
// Registered from AppDelegate alongside Mesh/NearbyFast. Registering only wires
// the channel; no session starts and no permission is asked until Dart calls
// "read" or "share". Requires the Near Field Communication Tag Reading
// capability (com.apple.developer.nfc.readersession.formats = [NDEF]) and an
// NFCReaderUsageDescription in Info.plist — without them CoreNFC refuses to
// start a session, which the Dart side treats as "unavailable".
final class NfcPay: NSObject {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "okay/nfcpay", binaryMessenger: messenger)
    let instance = NfcPay()
    // Held by the channel's handler closure, so it lives as long as the engine.
    channel.setMethodCallHandler(instance.handle)
  }

  // Strong refs so an in-flight session isn't deallocated mid-scan.
  private var session: NFCNDEFReaderSession?
  private var pending: FlutterResult?
  // Set when the session is a write; nil for a read.
  private var messageToWrite: NFCNDEFMessage?

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(NFCNDEFReaderSession.readingAvailable)
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

  private func beginRead(_ result: @escaping FlutterResult) {
    guard NFCNDEFReaderSession.readingAvailable else { return result(nil) }
    if busy() { return result(nil) }
    pending = result
    messageToWrite = nil
    let s = NFCNDEFReaderSession(
      delegate: self, queue: nil, invalidateAfterFirstRead: true)
    s.alertMessage = "Hold your phone near the pay tag."
    session = s
    s.begin()
  }

  private func beginWrite(_ tag: String, _ result: @escaping FlutterResult) {
    guard NFCNDEFReaderSession.readingAvailable, !tag.isEmpty,
      let url = URL(string: tag),
      let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
    else { return result(false) }
    if busy() { return result(false) }
    pending = result
    messageToWrite = NFCNDEFMessage(records: [payload])
    // invalidateAfterFirstRead:false so we can connect to the tag and write.
    let s = NFCNDEFReaderSession(
      delegate: self, queue: nil, invalidateAfterFirstRead: false)
    s.alertMessage = "Hold your phone near a blank tag to write it."
    session = s
    s.begin()
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

extension NfcPay: NFCNDEFReaderSessionDelegate {
  // Required. Fires when the session ends — cancelled, timed out, or done.
  func readerSession(
    _ session: NFCNDEFReaderSession, didInvalidateWithError error: Error
  ) {
    // A read that never resolved (user cancelled / timeout) answers nothing;
    // a write's success is reported from didDetect, so here it's just cleanup.
    if pending != nil { finish(messageToWrite == nil ? nil : false) }
  }

  // Read path: invalidateAfterFirstRead ended the session for us.
  func readerSession(
    _ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]
  ) {
    guard messageToWrite == nil else { return } // a write session ignores this
    finish(stringFrom(messages))
  }

  // Write path: connect to the first tag and write the pay link onto it.
  func readerSession(
    _ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]
  ) {
    guard let message = messageToWrite, let tag = tags.first else { return }
    session.connect(to: tag) { [weak self] error in
      guard let self = self else { return }
      if error != nil {
        session.invalidate(errorMessage: "Couldn't reach that tag.")
        self.finish(false)
        return
      }
      tag.queryNDEFStatus { status, _, error in
        if error != nil || status == .notSupported {
          session.invalidate(errorMessage: "That tag can't be written.")
          self.finish(false)
          return
        }
        if status == .readOnly {
          session.invalidate(errorMessage: "That tag is locked.")
          self.finish(false)
          return
        }
        tag.writeNDEF(message) { error in
          if error != nil {
            session.invalidate(errorMessage: "Couldn't write that tag.")
            self.finish(false)
          } else {
            session.alertMessage = "Your pay tag is ready."
            session.invalidate()
            self.finish(true)
          }
        }
      }
    }
  }
}
