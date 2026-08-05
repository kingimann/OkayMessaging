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
  /// 720p phone video. Listing media is FREE to the seller (the owner's
  /// call, 2026-08-04): the caps are what make that affordable — at the
  /// bucket rate ($0.0213/GB-mo) a full 12MB video stores for ~$0.0003 a
  /// month, and a view's egress ($0.09/GB, ~16MB sealed) costs ~$0.0014.
  /// No caps, no free.
  static const int maxVideoBytes = 12 * 1024 * 1024;

  /// The longest a listing video may run. Enforced from the file's own
  /// header wherever it can be read ([videoDurationSeconds]); the byte cap
  /// stays as the floor for what can't be.
  static const int maxVideoSeconds = 30;

  /// The clip's length in seconds, read from the MP4/MOV header (the moov
  /// box's mvhd), or null when it can't be known — WebM, a truncated
  /// buffer, or a moov the file keeps at the very end. Null means "fall
  /// back to the byte cap"; it never blocks on its own. Pure.
  static double? videoDurationSeconds(Uint8List b) {
    final data = ByteData.sublistView(b);
    (int, int)? box(int pos, int end) {
      if (pos + 8 > end) return null;
      var size = data.getUint32(pos);
      var header = 8;
      if (size == 1) {
        if (pos + 16 > end) return null;
        size = data.getUint32(pos + 8) * 4294967296 + data.getUint32(pos + 12);
        header = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < header || pos + size > end) return null;
      return (size, header);
    }

    String type(int pos) => String.fromCharCodes(b.sublist(pos + 4, pos + 8));

    var pos = 0;
    while (true) {
      final s = box(pos, b.length);
      if (s == null) return null;
      final (size, header) = s;
      if (type(pos) == 'moov') {
        final moovEnd = pos + size;
        var inner = pos + header;
        while (true) {
          final t = box(inner, moovEnd);
          if (t == null) return null;
          final (innerSize, innerHeader) = t;
          if (type(inner) == 'mvhd') {
            final at = inner + innerHeader;
            final version = at < b.length ? b[at] : 0;
            if (version == 1) {
              if (at + 32 > b.length) return null;
              final timescale = data.getUint32(at + 20);
              final duration = data.getUint32(at + 24) * 4294967296 +
                  data.getUint32(at + 28);
              return timescale == 0 ? null : duration / timescale;
            }
            if (at + 20 > b.length) return null;
            final timescale = data.getUint32(at + 12);
            final duration = data.getUint32(at + 16);
            return timescale == 0 ? null : duration / timescale;
          }
          inner += innerSize;
        }
      }
      pos += size;
    }
  }

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
    final seconds = videoDurationSeconds(bytes);
    if (seconds != null && seconds > maxVideoSeconds) {
      throw MarketMediaError(
          'Videos can be up to $maxVideoSeconds seconds — this one runs '
          '${seconds.round()}s. Trim it and try again.');
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
