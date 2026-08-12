import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/key_exchange.dart';
import '../crypto/notification_preview.dart';

/// The one thing the app hands the Notification Service Extension: a
/// per-contact key for opening a sealed push preview.
///
/// **Why this is a separate store and not [SecureStore].** These items live in
/// a SHARED keychain access group, because an extension is a different
/// process with a keychain of its own — a key written the ordinary way is
/// invisible to it. Everything else the app keeps secret (the identity
/// private key, ratchet chain keys, sender-key roots) deliberately stays out
/// of that group: a shared group is reachable by every target that declares
/// it, so the less that sits there the better. What is here opens a clipped
/// first line of a notification and nothing else.
///
/// The keys are DERIVED, never invented — HKDF over the static ECDH secret
/// this device already shares with each peer (see [NotificationPreview]). So
/// this store is a cache for the extension's benefit, not a source of truth:
/// losing it costs nothing but a rebuild, and there is no distribution step
/// that can go wrong.
class PreviewKeyStore {
  PreviewKeyStore._();
  static final PreviewKeyStore instance = PreviewKeyStore._();

  /// Must match `NotificationService.keychainGroup` in the Swift. A mismatch
  /// is silent: the extension's lookup simply finds nothing and every banner
  /// keeps its fallback body, which looks exactly like the feature not being
  /// there.
  static const String accessGroup = 'com.okaymessaging.shared';

  /// Must match `NotificationService.keyPrefix`.
  static const String keyPrefix = 'okay_notify_key_';

  static const _keychain = FlutterSecureStorage(
    iOptions: IOSOptions(
      // The extension runs while the phone sits locked in a pocket — that is
      // the entire point — so the key has to survive a locked screen. Same
      // reasoning as SecureStore's own choice.
      accessibility: KeychainAccessibility.first_unlock,
      groupId: accessGroup,
    ),
  );

  /// Set once a keychain write proves impossible, so the web build and the
  /// test suite do not pay a try/catch per contact.
  bool _unavailable = kIsWeb;

  /// Test seam: what WOULD have been written, so the wiring is provable
  /// without a keychain or an iPhone — which is everywhere this can be run.
  @visibleForTesting
  static Map<String, String>? debugWrites;

  /// Derives and stores the preview key for [peerDigits] from the peer's
  /// public key. A no-op where there is no shared secret to derive from,
  /// which is the honest outcome for a peer whose identity key this device
  /// has never seen.
  Future<void> remember(String peerDigits, String peerPublicKeyB64) async {
    final secret = SecureKeyExchange.instance.sharedSecretWith(peerPublicKeyB64);
    if (secret == null) return;
    final value = base64.encode(NotificationPreview.keyFor(secret));
    final hook = debugWrites;
    if (hook != null) {
      hook['$keyPrefix$peerDigits'] = value;
      return;
    }
    if (_unavailable) return;
    try {
      await _keychain.write(key: '$keyPrefix$peerDigits', value: value);
    } catch (_) {
      // No keychain here (web, tests, a simulator without the entitlement).
      // Previews simply stay unopened; nothing else depends on this.
      _unavailable = true;
    }
  }

  /// Drops a peer's key. Called when their identity key changes — the old key
  /// derives from a secret that is gone, so leaving it would mean the
  /// extension confidently failing to open every future preview while a
  /// stale entry sat in a shared keychain.
  Future<void> forget(String peerDigits) async {
    final hook = debugWrites;
    if (hook != null) {
      hook.remove('$keyPrefix$peerDigits');
      return;
    }
    if (_unavailable) return;
    try {
      await _keychain.delete(key: '$keyPrefix$peerDigits');
    } catch (_) {
      _unavailable = true;
    }
  }

  /// Test hook for [testWrite]: installing ANY function (even one that
  /// returns null, meaning success) replaces the real keychain call — there
  /// is no keychain to hit in a test.
  @visibleForTesting
  static Future<String?> Function()? debugTestWrite;

  /// Writes and reads back a throwaway entry, bypassing [_unavailable] —
  /// [remember] latches that flag on the FIRST failure and never retries for
  /// the rest of the app's run, which is right for the real feature (no
  /// per-contact try/catch spam) and wrong for a diagnostic, which needs
  /// THIS run's true answer, not a cached one from minutes or hours ago.
  ///
  /// Returns null on success, or the platform's own error string — this is
  /// the one place that can tell "the shared keychain group isn't writable
  /// by this app" apart from every other reason a preview might not show,
  /// since it is the same write [remember] does, just observed rather than
  /// swallowed.
  Future<String?> testWrite() async {
    final hook = debugTestWrite;
    if (hook != null) return hook();
    if (kIsWeb) return 'no keychain on the web build';
    const probeKey = '${keyPrefix}selftest';
    try {
      await _keychain.write(key: probeKey, value: 'ok');
      final readBack = await _keychain.read(key: probeKey);
      if (readBack != 'ok') {
        return 'wrote but read back ${readBack == null ? 'nothing' : '"$readBack"'}';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }
}
