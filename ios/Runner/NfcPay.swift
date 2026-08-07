import Flutter
import UIKit

// Phone-to-phone "tap to pay" over NFC — the native half of lib/payments/
// nfc_pay.dart. COMPILE-SAFE STUB for now: it answers the `okay/nfcpay` channel
// and reports NFC unavailable, so the Dart side falls back to the QR code. The
// real implementation is a follow-up whose only real test is a device build:
//
//   * it needs the Near Field Communication Tag Reading capability + the
//     `com.apple.developer.nfc.readersession.formats` entitlement (and, to be
//     read back, an NDEF write session — CoreNFC's writeNDEF, iOS 13+);
//   * `NFCNDEFReaderSession` reads a nearby phone's advertised receive tag;
//     writing/advertising a tag from an iPhone is limited, so the shipping
//     shape is likely a reader on the payer's side and a QR on the payee's.
//
// This is NOT Apple's Tap to Pay on iPhone (accepting contactless CARDS), which
// needs Apple's separate program and ProximityReader — out of scope here.
//
// Registered from AppDelegate the same way Mesh/NearbyFast are, when the native
// implementation lands. Until then leaving it unregistered is harmless: the
// Dart channel call throws MissingPluginException, which NfcPay catches and
// treats as "unavailable".
final class NfcPay: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "okay/nfcpay", binaryMessenger: registrar.messenger())
    let instance = NfcPay()
    channel.setMethodCallHandler(instance.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      // The real check is NFCNDEFReaderSession.readingAvailable once the
      // capability is added; the stub reports false so the QR fallback runs.
      result(false)
    case "share", "read":
      result(FlutterError(
        code: "unavailable",
        message: "Tap to pay isn't built on this device yet.",
        details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
