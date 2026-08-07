import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Phone-to-phone "tap to pay" over NFC — the wallet's tap-free way to be paid
/// in person: you advertise your receive tag, the other phone taps and reads
/// it, and pays you through the normal money flow.
///
/// This is NOT Apple's *Tap to Pay on iPhone* (accepting contactless CARDS),
/// which needs Apple's program and a special entitlement and can't be built or
/// tested here — it is two copies of THIS app tapping, the same shape the
/// Bluetooth "Okay Drop" uses on a different radio.
///
/// A TRANSPORT ONLY: it carries a public receive handle, nothing about a chat
/// or a key — a test pins that this file imports no chat, relay or encryption
/// code. The native CoreNFC half is a follow-up — it needs an NFC entitlement
/// and a real device build, like the mesh — so until it is wired [available] is
/// false and the wallet falls back to the QR code.
class NfcPay {
  NfcPay._();
  static final NfcPay instance = NfcPay._();

  static const _channel = MethodChannel('okay/nfcpay');

  /// Test seam: stands in for the native radio's availability.
  @visibleForTesting
  static bool? debugAvailable;

  /// Whether this device can tap to pay. False off iOS, and until the native
  /// CoreNFC handler is wired — so, honestly, false today on every build.
  Future<bool> available() async {
    final o = debugAvailable;
    if (o != null) return o;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Advertise [tag] — a PUBLIC receive handle, never a number or a key — for a
  /// nearby phone to read and pay. Returns whether it started; a no-op when NFC
  /// isn't available.
  Future<bool> shareReceiveTag(String tag) async {
    if (tag.isEmpty || !await available()) return false;
    try {
      await _channel.invokeMethod<void>('share', {'tag': tag});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Read a nearby phone's receive tag (to pay them). Null when NFC isn't
  /// available or nothing was tapped.
  Future<String?> readTag() async {
    if (!await available()) return null;
    try {
      return await _channel.invokeMethod<String>('read');
    } catch (_) {
      return null;
    }
  }
}
