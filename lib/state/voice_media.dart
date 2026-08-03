import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../crypto/e2e.dart';
import '../relay/relay_config.dart';

/// Long voice notes, stored sealed in a Supabase Storage bucket.
///
/// A short note rides the relay inline (a `data:` URI on the message, sealed
/// like a photo). A long one is too big for one broadcast, so it goes here
/// instead — the same bucket machinery marketplace videos use, under the same
/// rule: **the bucket only ever holds sealed blobs.**
///
/// Unlike a listing video (sealed with the server's shared key, whose audience
/// is the whole server), a voice note is for one conversation. So each note is
/// sealed with its OWN random key, and that key travels inside the E2E chat
/// message that names the object — never to the bucket. The operator sees
/// ciphertext, and the object path alone unseals nothing. This keeps the note
/// exactly as private as the message that points at it.
class VoiceMedia {
  VoiceMedia._();
  static final VoiceMedia instance = VoiceMedia._();

  /// Bucket holding sealed voice notes. Provision once with
  /// docs/voice_notes_bucket.sql.
  static const bucket = 'voice-notes';

  /// The most raw bytes one note may be — at the low bitrate voice is
  /// recorded at (~20 kbps mono) this is well over an hour, so the real limit
  /// a person meets is the duration cap in the composer, not this. It exists
  /// to stop a runaway upload and keep the hosting numbers sane, matching the
  /// listing-video ceiling.
  static const int maxBytes = 12 * 1024 * 1024;

  static final Random _rng = Random.secure();

  /// Test hook: replaces the bucket round trip with an in-memory map.
  @visibleForTesting
  static Map<String, String>? debugBucketOverride;

  static String _newPath() {
    final id = base64Url
        .encode(List.generate(18, (_) => _rng.nextInt(256)))
        .replaceAll('=', '');
    return '$id.sealed';
  }

  static String _newKeyB64() =>
      base64.encode(List.generate(32, (_) => _rng.nextInt(256)));

  /// Seals [bytes] under a fresh random key and uploads the ciphertext.
  /// Returns the bucket path and the base64 key to carry in the sealed
  /// message, or throws [VoiceMediaError] with a reason a person can act on.
  Future<({String path, String key})> upload(Uint8List bytes) async {
    if (bytes.isEmpty) throw VoiceMediaError('Nothing was recorded.');
    if (bytes.length > maxBytes) {
      throw VoiceMediaError(
          'That note is longer than can be sent. Record a shorter one.');
    }
    final key = _newKeyB64();
    final sealed = E2eCrypto.encrypt(base64.decode(key), base64.encode(bytes));
    final path = _newPath();

    final debug = debugBucketOverride;
    if (debug != null) {
      debug[path] = sealed;
      return (path: path, key: key);
    }
    if (!RelayConfig.isEnabled) throw VoiceMediaError('No server configured.');
    final res = await http
        .post(
          Uri.parse(
              '${RelayConfig.supabaseUrl}/storage/v1/object/$bucket/$path'),
          headers: {
            'apikey': RelayConfig.supabaseAnonKey,
            'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
            'Content-Type': 'text/plain',
            'x-upsert': 'true',
          },
          body: sealed,
        )
        .timeout(const Duration(minutes: 2));
    if (res.statusCode == 404 && res.body.contains('Bucket not found')) {
      throw VoiceMediaError('Voice-note storage isn\'t provisioned yet — run '
          'docs/voice_notes_bucket.sql once in the Supabase SQL editor.');
    }
    if (res.statusCode >= 300) {
      throw VoiceMediaError('Upload failed (${res.statusCode}).');
    }
    return (path: path, key: key);
  }

  /// Downloads and unseals a note. Null when it is missing, the device is
  /// offline, or the seal doesn't verify (wrong key, tampering).
  Future<Uint8List?> download(String path, String keyB64) async {
    List<int> key;
    try {
      key = base64.decode(keyB64);
    } catch (_) {
      return null;
    }

    String? sealed;
    final debug = debugBucketOverride;
    if (debug != null) {
      sealed = debug[path];
    } else {
      if (!RelayConfig.isEnabled) return null;
      try {
        final res = await http.get(
          Uri.parse(
              '${RelayConfig.supabaseUrl}/storage/v1/object/$bucket/$path'),
          headers: {
            'apikey': RelayConfig.supabaseAnonKey,
            'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
          },
        ).timeout(const Duration(minutes: 2));
        if (res.statusCode >= 300 || res.body.isEmpty) return null;
        sealed = res.body;
      } catch (_) {
        return null;
      }
    }
    if (sealed == null) return null;
    final plain = E2eCrypto.decrypt(key, sealed);
    if (plain == null) return null;
    try {
      return base64.decode(plain);
    } catch (_) {
      return null;
    }
  }
}

/// A voice-note upload/consume failure a person can be told about.
class VoiceMediaError implements Exception {
  final String reason;
  VoiceMediaError(this.reason);
  @override
  String toString() => reason;
}
