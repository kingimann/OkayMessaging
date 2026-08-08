import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// "Tap to pay" over NFC (CoreNFC), the tag-based way to pay in person.
///
/// HONEST ABOUT iOS: an iPhone can READ an NFC tag and WRITE a blank one, but
/// it cannot pretend to BE a tag (no card-emulation/HCE for third-party apps),
/// so there is no iPhone-to-iPhone "hold them together" — that hardware isn't
/// exposed. This is therefore tag-based:
///   * [readTag]         — the payer taps a tag holding a pay link and gets it
///                         back, to open straight into paying that person;
///   * [shareReceiveTag] — the payee WRITES that pay link onto a blank NFC
///                         sticker, making a reusable "tap to pay me" tag.
/// The QR code stays the tap-free path for two phones with no sticker.
///
/// This is NOT Apple's *Tap to Pay on iPhone* (accepting contactless CARDS),
/// which needs Apple's separate program and ProximityReader — out of scope.
///
/// A TRANSPORT ONLY: it carries a public pay link, nothing about a chat or a
/// key — a test pins that this file imports no chat, relay or encryption code.
/// [available] is true only on an NFC-capable iPhone with the reader
/// entitlement; everywhere else it is false and the wallet falls back to QR.
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

  /// Writes [tag] — a PUBLIC pay link (okaymsg://…&pay=1), never a number or a
  /// key — onto a blank NFC sticker held to the phone, making a reusable "tap
  /// to pay me" tag. Returns whether the write succeeded; a no-op when NFC
  /// isn't available. The native session prompts the user to hold a tag.
  Future<bool> shareReceiveTag(String tag) async {
    if (tag.isEmpty || !await available()) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('share', {'tag': tag});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reads a nearby pay tag (to pay whoever it names) and returns the pay link
  /// it holds. Null when NFC isn't available or nothing was tapped. The native
  /// session prompts the user to hold their phone to a tag.
  Future<String?> readTag() async {
    if (!await available()) return null;
    try {
      return await _channel.invokeMethod<String>('read');
    } catch (_) {
      return null;
    }
  }
}
