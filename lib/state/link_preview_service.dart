import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/link_preview.dart';

/// Builds the card for a link, on the SENDER's device, before the message
/// leaves.
///
/// Nothing here ever runs on a receiving device — see [LinkPreview]'s own
/// note for why that is the whole point rather than an implementation
/// detail. The result rides inside the encrypted message; the recipient
/// draws it having contacted nobody.
///
/// Every failure is silent and ends the same way: no preview, and the
/// message sends as it always did. A link nobody could read is not worth
/// blocking a send over, and a spinner on the composer while some slow host
/// times out would be worse than no card at all.
class LinkPreviewService {
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  /// How long the whole thing may take. Short on purpose: this sits between
  /// tapping send and the message appearing.
  static const Duration timeout = Duration(seconds: 4);

  /// How much of a page to read. Open Graph tags live in `<head>`, so the
  /// first chunk is all that is ever needed, and a cap is what stops a
  /// hostile or merely enormous page from being downloaded in full.
  static const int maxHtmlBytes = 96 * 1024;

  /// The thumbnail budget. It is base64'd into an end-to-end encrypted
  /// message, which is sized for words — past this the card ships without
  /// a picture rather than making the message enormous.
  static const int maxThumbnailBytes = 120 * 1024;

  /// Test seam: stands in for the network so the whole build path can be
  /// exercised without one. Given a URL, returns the body, or null.
  @visibleForTesting
  static Future<String?> Function(Uri url)? debugFetchHtml;

  /// Test seam for the image half, returning raw bytes.
  @visibleForTesting
  static Future<Uint8List?> Function(Uri url)? debugFetchBytes;

  /// Turns the first link in [text] into a card, or null when there is no
  /// link or nothing could be learned about it.
  Future<LinkPreview?> forText(String text) async {
    final uri = firstLinkIn(text);
    if (uri == null) return null;
    return forUrl(uri);
  }

  Future<LinkPreview?> forUrl(Uri uri) async {
    try {
      final kind = linkKindOf(uri);
      if (kind == LinkKind.youtube) return _youtube(uri);
      return _page(uri, kind);
    } catch (_) {
      return null;
    }
  }

  /// A YouTube card needs NO page fetch: the id is in the URL and the
  /// thumbnail lives at a published, keyless address. So the only request
  /// is the picture, and even that failing still leaves a playable card.
  Future<LinkPreview> _youtube(Uri uri) async {
    final id = youtubeIdOf(uri);
    final thumb = await _thumbnail(Uri.parse(youtubeThumbnailUrl(id)));
    // The title needs the page, and a YouTube card is perfectly good
    // without one — the thumbnail says what the video is. Asked for anyway,
    // best-effort, because a name reads better than a bare host.
    String title = '';
    final html = await _html(uri);
    if (html != null) {
      final og = parseOpenGraph(html);
      title = og['og:title'] ?? '';
    }
    return LinkPreview(
      url: uri.toString(),
      kind: LinkKind.youtube,
      title: title,
      host: prettyHost(uri),
      thumbnail: thumb,
      videoId: id,
    );
  }

  Future<LinkPreview?> _page(Uri uri, LinkKind kind) async {
    final html = await _html(uri);
    // A reel is worth a card even when the page cannot be read — Instagram
    // serves a login wall to anything without a session, which is exactly
    // the case this branch exists for. A plain page with nothing readable
    // gets no card: a rectangle saying only "example.com" is worse than the
    // blue link it replaced.
    if (html == null) {
      return kind == LinkKind.reel
          ? LinkPreview(
              url: uri.toString(), kind: kind, host: prettyHost(uri))
          : null;
    }
    final og = parseOpenGraph(html);
    final title = og['og:title'] ?? og['twitter:title'] ?? '';
    final description =
        og['og:description'] ?? og['twitter:description'] ?? '';
    final imageUrl = og['og:image'] ?? og['twitter:image'] ?? '';
    if (title.isEmpty && description.isEmpty && imageUrl.isEmpty) {
      return kind == LinkKind.reel
          ? LinkPreview(
              url: uri.toString(), kind: kind, host: prettyHost(uri))
          : null;
    }
    final thumb = imageUrl.isEmpty
        ? ''
        : await _thumbnail(uri.resolve(imageUrl));
    return LinkPreview(
      url: uri.toString(),
      kind: kind,
      title: title,
      // Two lines' worth. A whole meta description would be a paragraph
      // under a link somebody sent instead of writing one.
      description:
          description.length > 160 ? description.substring(0, 160) : description,
      host: prettyHost(uri),
      thumbnail: thumb,
    );
  }

  Future<String?> _html(Uri uri) async {
    final hook = debugFetchHtml;
    if (hook != null) return hook(uri);
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    try {
      final response = await http.get(uri, headers: const {
        // Plain, honest, and not pretending to be a browser. Some hosts
        // serve a leaner page to a bot, which is the page this wants.
        'User-Agent': 'OkayMessenger/1.0 (+link preview)',
        'Accept': 'text/html',
      }).timeout(timeout);
      if (response.statusCode != 200) return null;
      final type = response.headers['content-type'] ?? '';
      if (!type.contains('html')) return null;
      final bytes = response.bodyBytes;
      final head = bytes.length > maxHtmlBytes
          ? bytes.sublist(0, maxHtmlBytes)
          : bytes;
      // allowMalformed: a truncated page can end mid-character, and a
      // preview is not worth throwing over one broken byte.
      return utf8.decode(head, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Downloads an image and returns it as a data URI, or '' — never a
  /// remote URL, which the recipient's device would have to fetch.
  Future<String> _thumbnail(Uri uri) async {
    try {
      final hook = debugFetchBytes;
      final Uint8List? bytes;
      if (hook != null) {
        bytes = await hook(uri);
      } else {
        final response = await http.get(uri).timeout(timeout);
        bytes = response.statusCode == 200 ? response.bodyBytes : null;
      }
      if (bytes == null || bytes.isEmpty) return '';
      if (bytes.length > maxThumbnailBytes) return '';
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return '';
    }
  }
}
