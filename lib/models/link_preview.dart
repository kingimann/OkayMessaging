import 'dart:convert';

/// Where a shared link points, when the app knows enough about it to do more
/// than draw a rectangle.
enum LinkKind {
  /// A YouTube video (watch, youtu.be, /shorts, /embed). The one kind that
  /// really plays in the app: YouTube publishes an embed player and a
  /// thumbnail at predictable URLs, so no key, no API and no token.
  youtube,

  /// An Instagram or Facebook reel. Recognised so the card can say what it
  /// is and use the right verb — but see [LinkPreview.playable]: these do
  /// NOT play in the app, and the card says so rather than pretending.
  reel,

  /// Anything else: whatever the page's own Open Graph tags describe.
  page,
}

/// A link, as a card rather than a line of blue text.
///
/// **Built on the SENDER's device and carried inside the message.** This is
/// the Signal/WhatsApp rule and it is the whole privacy argument: if the
/// RECIPIENT's phone fetched the page to draw a preview, then opening a
/// chat would tell that site — and anyone watching the recipient's network
/// — that they had read the message, and roughly when. So the sender (who
/// already chose to visit the link) does the fetching, the result rides
/// inside the same end-to-end encrypted envelope as the words, and the
/// receiving device draws it having contacted nobody.
///
/// The thumbnail is embedded as a data URI for the same reason. A remote
/// image URL on a card would be a request to the host every time the
/// recipient scrolled past it.
class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.kind,
    this.title = '',
    this.description = '',
    this.host = '',
    this.thumbnail = '',
    this.videoId = '',
  });

  /// The link exactly as it was typed — what a tap opens, and never a
  /// rewritten or shortened form of it.
  final String url;
  final LinkKind kind;
  final String title;
  final String description;

  /// The site, for the line under the title. Shown even when nothing else
  /// could be read: "youtube.com" is worth more than an empty card.
  final String host;

  /// A `data:image/...;base64,...` thumbnail, fetched by the sender. Empty
  /// is normal — plenty of pages publish no image, and a card without one
  /// is a card, not a failure.
  final String thumbnail;

  /// The YouTube id, when [kind] is [LinkKind.youtube].
  final String videoId;

  /// Whether tapping this plays it inside the app.
  ///
  /// True for YouTube only, and the limit is real rather than laziness:
  /// Instagram and Facebook serve reels behind a login and their oEmbed
  /// needs an app token, so nothing this app can do will play one. The card
  /// says "Open in Instagram" instead of showing a play button that would
  /// lie about what the tap does.
  bool get playable => kind == LinkKind.youtube && videoId.isNotEmpty;

  /// The page the in-app player loads. `playsinline` keeps it in the frame
  /// instead of handing it to the system full-screen player.
  String get embedUrl =>
      'https://www.youtube.com/embed/$videoId?playsinline=1&rel=0';

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind.name,
        if (title.isNotEmpty) 'title': title,
        if (description.isNotEmpty) 'description': description,
        if (host.isNotEmpty) 'host': host,
        if (thumbnail.isNotEmpty) 'thumbnail': thumbnail,
        if (videoId.isNotEmpty) 'videoId': videoId,
      };

  static LinkPreview fromJson(Map<String, dynamic> j) => LinkPreview(
        url: j['url'] as String? ?? '',
        // An unknown kind from a newer build reads as a plain page rather
        // than throwing: the card still draws, it just claims less.
        kind: LinkKind.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => LinkKind.page),
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        host: j['host'] as String? ?? '',
        thumbnail: j['thumbnail'] as String? ?? '',
        videoId: j['videoId'] as String? ?? '',
      );

  String encode() => jsonEncode(toJson());

  static LinkPreview? decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final p = LinkPreview.fromJson(Map<String, dynamic>.from(decoded));
      return p.url.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }
}

/// The first http(s) link in [text], or null. Pure.
///
/// One per message on purpose — a card each for five links is a wall, and
/// the first is the one somebody meant. Trailing punctuation is trimmed
/// because "see youtube.com/watch?v=x." is a sentence, not a URL ending in
/// a full stop.
Uri? firstLinkIn(String text) {
  final match =
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(text);
  if (match == null) return null;
  var raw = match.group(0)!;
  while (raw.isNotEmpty && '.,;:!?)]}\'"'.contains(raw[raw.length - 1])) {
    raw = raw.substring(0, raw.length - 1);
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasAuthority) return null;
  return uri;
}

/// The YouTube video id in [uri], or '' — `watch?v=`, `youtu.be/<id>`,
/// `/shorts/<id>` and `/embed/<id>`, with or without `www`/`m`. Pure.
String youtubeIdOf(Uri uri) {
  final host = uri.host.toLowerCase();
  final isYoutube = host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
  if (!isYoutube) return '';
  String candidate = '';
  if (host == 'youtu.be') {
    candidate = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
  } else if (uri.pathSegments.length >= 2 &&
      (uri.pathSegments.first == 'shorts' ||
          uri.pathSegments.first == 'embed' ||
          uri.pathSegments.first == 'live')) {
    candidate = uri.pathSegments[1];
  } else {
    candidate = uri.queryParameters['v'] ?? '';
  }
  // YouTube ids are 11 characters of an unreserved alphabet. Checking the
  // shape keeps a path like /shorts/about from becoming a dead player.
  return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate) ? candidate : '';
}

/// Whether [uri] is an Instagram or Facebook reel — recognised so the card
/// can name it, never so it can claim to play it. Pure.
bool isReelLink(Uri uri) {
  final host = uri.host.toLowerCase().replaceFirst('www.', '');
  final path = uri.path.toLowerCase();
  final instagram = host == 'instagram.com' || host.endsWith('.instagram.com');
  final facebook = host == 'facebook.com' ||
      host.endsWith('.facebook.com') ||
      host == 'fb.watch';
  if (instagram) {
    return path.startsWith('/reel') || path.startsWith('/p/');
  }
  return facebook && (path.contains('/reel') || path.contains('/videos'));
}

/// What kind of link [uri] is. Pure.
LinkKind linkKindOf(Uri uri) {
  if (youtubeIdOf(uri).isNotEmpty) return LinkKind.youtube;
  if (isReelLink(uri)) return LinkKind.reel;
  return LinkKind.page;
}

/// The host with a leading `www.` trimmed — what the card's second line
/// says. Pure.
String prettyHost(Uri uri) =>
    uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

/// YouTube's own thumbnail for [videoId]. A published, keyless URL — which
/// is why a YouTube card needs no page fetch at all, only the download of
/// this one image so it can ride the message as bytes.
String youtubeThumbnailUrl(String videoId) =>
    'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

/// Pulls `og:` / `twitter:` values and `<title>` out of a page.
///
/// A regex rather than an HTML parser, deliberately: adding a parser
/// dependency to read three tags is a lot of new code in the path that
/// touches arbitrary untrusted pages, and getting a preview slightly wrong
/// costs a nicer card, while a parser CVE costs more than that. Pure, so
/// the awkward real-world cases are testable without a network.
Map<String, String> parseOpenGraph(String html) {
  final out = <String, String>{};
  final meta = RegExp(r'<meta\s+[^>]*>', caseSensitive: false);
  for (final tag in meta.allMatches(html)) {
    final text = tag.group(0)!;
    // property= and name= are both used in the wild, and the attributes
    // come in either order.
    final key = RegExp(r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
            caseSensitive: false)
        .firstMatch(text)
        ?.group(1)
        ?.toLowerCase();
    final value = RegExp(r'''content\s*=\s*["']([^"']*)["']''',
            caseSensitive: false)
        .firstMatch(text)
        ?.group(1);
    if (key == null || value == null || value.isEmpty) continue;
    if (!out.containsKey(key)) out[key] = _unescape(value);
  }
  if (!out.containsKey('og:title')) {
    final title = RegExp(r'<title[^>]*>(.*?)</title>',
            caseSensitive: false, dotAll: true)
        .firstMatch(html)
        ?.group(1)
        ?.trim();
    if (title != null && title.isNotEmpty) out['og:title'] = _unescape(title);
  }
  return out;
}

/// The five entities worth handling — enough that a title reads as English
/// rather than markup. Anything rarer is left alone rather than guessed at.
String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .trim();
