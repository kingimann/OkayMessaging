/// A GIF used as a profile picture — the one avatar in this app that is a
/// real, moving picture rather than something drawn on the phone.
///
/// **It is a URL, and that is the whole cost of the feature.** Every other
/// avatar here draws with no network at all: a colour, an emoji, a generated
/// Multiavatar SVG, a built face. A GIF avatar is fetched from whoever serves
/// it, by the device DRAWING it — so the host learns the IP of everyone who
/// sees that avatar, and roughly when. Stated rather than hidden, because it
/// is the opposite of how the rest of the avatar stack works.
///
/// Two things bound it, and neither is a guess:
///
/// * **It arrives only over the sealed profile share**, so the only people who
///   can point your phone at a URL are people you have exchanged messages
///   with — not a stranger in a feed, not the username directory (which
///   carries no avatar fields at all). Those same people can already send you
///   a GIF MESSAGE, which your phone fetches the same way; what this adds is
///   that it is fetched when you look at a list rather than when you open
///   their chat.
/// * **[looksValid] is strict about the shape**, in the same spirit as
///   `LightningAddress.parse`: this string arrives from another device and
///   becomes a network request on this one.
///
/// **There is deliberately no host allowlist.** The obvious one would be the
/// GIF provider's own CDN — but nothing in this repo has ever called that API
/// live (see `GifService`), so the real media host is unknown here, and an
/// allowlist built on a guess fails CLOSED: every GIF avatar silently never
/// appears, which is worse than the exposure it would be buying. If the host
/// is ever confirmed against the live API, adding it here is a two-line
/// change and worth making.
class AvatarGif {
  AvatarGif._();

  /// A ceiling on what may be stored or accepted from the wire. Real picker
  /// URLs are well under a hundred characters; this is the guard that stops a
  /// malformed or hostile profile carrying something enormous, since this
  /// string is broadcast to every contact.
  static const int maxLength = 400;

  /// Whether [url] is safe to hand to an image loader.
  ///
  /// **https only.** Not politeness: a `http:` avatar would announce to
  /// anybody on the network which profile picture — and so which person —
  /// this phone just drew. `data:` is refused for a different reason: it
  /// would let a profile carry megabytes of image inside the bundle that
  /// rides along with messages.
  static bool looksValid(String url) {
    final s = url.trim();
    if (s.isEmpty || s.length > maxLength || s != url.trim()) return false;
    // A control character or a space anywhere is not a URL somebody picked.
    if (s.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) return false;
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.isAbsolute) return false;
    if (uri.scheme != 'https') return false;
    // `https://real.host@evil.example/x` reads as the real host to a person
    // and resolves to the other one.
    if (uri.userInfo.isNotEmpty) return false;
    if (!uri.host.contains('.') || uri.host.startsWith('.')) return false;
    // A bare host is not a picture.
    if (uri.path.isEmpty || uri.path == '/') return false;
    return true;
  }
}
