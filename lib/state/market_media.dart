import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../crypto/e2e.dart';
import '../relay/relay_config.dart';
import '../state/community_store.dart';

/// Listing videos, stored sealed in a Supabase Storage bucket.
///
/// A video cannot ride the relay: one broadcast caps out around a quarter
/// megabyte and even a short clip is tens of them, each a mailbox row per
/// offline member, one lost chunk a broken video. So video is the first
/// marketplace media that goes through the Storage bucket instead — the same
/// bucket machinery chat backups use, and under the same rule: **the bucket
/// only ever holds sealed blobs.** A video is encrypted with its server's
/// secret before upload, so only members of that server — the listing's
/// entire audience — can play it. The bucket operator sees ciphertext.
///
/// It is also the first marketplace feature that costs real money to host
/// (storage + egress per view), which is why uploading requires the cloud
/// storage subscription — the thing whose unit economics the test suite
/// already proves. Watching is free; hosting is what's paid for.
class MarketMedia {
  MarketMedia._();
  static final MarketMedia instance = MarketMedia._();

  /// Bucket holding sealed listing videos. Provision once with
  /// docs/market_media_bucket.sql.
  static const bucket = 'market-media';

  /// The most raw bytes one listing video may be — roughly 30 seconds of
  /// 720p phone video. The cap is what keeps the numbers sane: at the bucket
  /// rate ($0.0213/GB-mo) a full 12MB video stores for ~$0.0003/month, and a
  /// view's egress ($0.09/GB, ~16MB sealed) costs ~$0.0014 — small against
  /// the storage subscription that gates uploading. No cap, no such claim.
  static const int maxVideoBytes = 12 * 1024 * 1024;

  /// Test hook: replaces the bucket round trip with an in-memory map.
  @visibleForTesting
  static Map<String, String>? debugBucketOverride;

  /// Where a listing's sealed video lives. Deterministic, so replacing a
  /// video overwrites rather than orphaning the old object.
  static String pathFor(String communityId, String listingId) =>
      '$communityId/$listingId.sealed';

  /// True when [bytes] begin like a video container this app will accept:
  /// MP4/MOV (an `ftyp` box) or WebM. Pure. A cheap honesty check, not a
  /// codec validation — the player is the final judge.
  static bool looksLikeVideo(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // ISO-BMFF (mp4/mov): size (4 bytes) then 'ftyp'.
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return true;
    }
    // WebM/Matroska EBML header.
    return bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3;
  }

  List<int>? _secretFor(String communityId) {
    final community = CommunityStore.instance.byId(communityId);
    final secret = community?.secret ?? '';
    if (secret.isEmpty) return null;
    try {
      return base64.decode(secret);
    } catch (_) {
      return null;
    }
  }

  /// Whether a video could be sealed for [communityId] at all.
  ///
  /// Asked before an "Attach video" button is drawn: a server with no shared
  /// key has nowhere to put a sealed video, and offering the button anyway
  /// means a picker, an upload, and a failure at the end of it.
  static bool canSeal(String communityId) =>
      MarketMedia.instance._secretFor(communityId) != null;

  /// Seals and uploads [bytes] for a listing. Returns the bucket path, or
  /// throws [MarketMediaError] with a reason a person can act on.
  Future<String> uploadVideo({
    required String communityId,
    required String listingId,
    required Uint8List bytes,
  }) async {
    if (!looksLikeVideo(bytes)) {
      throw MarketMediaError('That file doesn\'t look like a video.');
    }
    if (bytes.length > maxVideoBytes) {
      throw MarketMediaError(
          'Videos can be up to ${maxVideoBytes ~/ (1024 * 1024)} MB — about '
          '30 seconds. Trim it and try again.');
    }
    final secret = _secretFor(communityId);
    if (secret == null) {
      throw MarketMediaError(
          'This server has no shared key, so its videos can\'t be sealed.');
    }
    final sealed = E2eCrypto.encrypt(secret, base64.encode(bytes));
    final path = pathFor(communityId, listingId);

    final debug = debugBucketOverride;
    if (debug != null) {
      debug[path] = sealed;
      return path;
    }
    if (!RelayConfig.isEnabled) {
      throw MarketMediaError('No server configured.');
    }
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
        .timeout(const Duration(minutes: 3));
    if (res.statusCode == 404 && res.body.contains('Bucket not found')) {
      throw MarketMediaError('Video storage isn\'t provisioned yet — run '
          'docs/market_media_bucket.sql once in the Supabase SQL editor.');
    }
    if (res.statusCode >= 300) {
      throw MarketMediaError('Upload failed (${res.statusCode}).');
    }
    return path;
  }

  /// Downloads and unseals a listing video. Null when it is missing, the
  /// device is offline, or the seal doesn't verify (wrong key, tampering).
  Future<Uint8List?> downloadVideo(String communityId, String path) async {
    final secret = _secretFor(communityId);
    if (secret == null) return null;

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
        ).timeout(const Duration(minutes: 3));
        if (res.statusCode >= 300 || res.body.isEmpty) return null;
        sealed = res.body;
      } catch (_) {
        return null;
      }
    }
    if (sealed == null) return null;
    final plain = E2eCrypto.decrypt(secret, sealed);
    if (plain == null) return null;
    try {
      return base64.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// Removes a listing's video object. Best-effort: a listing must delete
  /// cleanly even when the bucket is unreachable, so failures are swallowed —
  /// the object is also unreachable garbage at that point, not a leak of
  /// anything readable.
  Future<void> deleteVideo(String path) async {
    final debug = debugBucketOverride;
    if (debug != null) {
      debug.remove(path);
      return;
    }
    if (!RelayConfig.isEnabled) return;
    try {
      await http.delete(
        Uri.parse(
            '${RelayConfig.supabaseUrl}/storage/v1/object/$bucket/$path'),
        headers: {
          'apikey': RelayConfig.supabaseAnonKey,
          'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
        },
      ).timeout(const Duration(seconds: 30));
    } catch (_) {}
  }
}

/// A video upload/consume failure a person can be told about.
class MarketMediaError implements Exception {
  final String reason;
  MarketMediaError(this.reason);
  @override
  String toString() => reason;
}
