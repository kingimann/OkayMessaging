import 'dart:convert';

/// A marketplace listing as it travels INTO A CHAT — the Facebook-shaped
/// card, not a paragraph of text.
///
/// Forwarding a listing used to send [listingShareText]: a title, a price
/// and a sentence, which arrives as words somebody has to read and then go
/// and search for. This is the card instead — a photo, the price, the place
/// — and it is tappable, because the marketplace has been a GLOBAL table
/// since 2026-08-08, so the other device really can open the same listing by
/// id rather than being shown a picture of one.
///
/// **It carries a SNAPSHOT as well as the id, and that is deliberate.** The
/// id alone would render an empty card on any device that has not fetched
/// the marketplace yet, and nothing at all for a listing since deleted. The
/// snapshot means the card always says what was sent even when the live
/// listing cannot be resolved — the same choice Facebook makes, and the
/// honest one: what was shared is a fact about the past, and it should not
/// blank out because the seller took the item down.
///
/// The snapshot is small on purpose. It rides inside an ordinary end-to-end
/// encrypted message, which budgets its size for text: one photo URL, not
/// the gallery, and no description.
class ListingCard {
  const ListingCard({
    required this.id,
    required this.title,
    required this.priceCents,
    this.photoUrl = '',
    this.place = '',
    this.condition = '',
    this.sellerHandle = '',
    this.sold = false,
  });

  /// The listing's id in the global table — what makes the card openable
  /// rather than a picture of a listing.
  final String id;
  final String title;
  final int priceCents;

  /// The cover photo, exactly as the listing carries it. Empty is a normal
  /// listing, not a broken card — plenty are posted without one.
  final String photoUrl;
  final String place;
  final String condition;
  final String sellerHandle;

  /// What the listing said at the moment it was shared. Never refreshed on
  /// the card: the LIVE listing is one tap away and speaks for itself, and
  /// silently rewriting a message somebody sent is worse than a stale word.
  final bool sold;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'priceCents': priceCents,
        if (photoUrl.isNotEmpty) 'photoUrl': photoUrl,
        if (place.isNotEmpty) 'place': place,
        if (condition.isNotEmpty) 'condition': condition,
        if (sellerHandle.isNotEmpty) 'sellerHandle': sellerHandle,
        if (sold) 'sold': true,
      };

  static ListingCard fromJson(Map<String, dynamic> j) => ListingCard(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        priceCents: (j['priceCents'] as num?)?.toInt() ?? 0,
        photoUrl: j['photoUrl'] as String? ?? '',
        place: j['place'] as String? ?? '',
        condition: j['condition'] as String? ?? '',
        sellerHandle: j['sellerHandle'] as String? ?? '',
        sold: j['sold'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  /// Reads a card off a message's `listingCard` field. Null for anything
  /// that will not parse or names no listing — a malformed card must draw
  /// nothing rather than an empty box with a dead tap on it.
  static ListingCard? decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final card = ListingCard.fromJson(Map<String, dynamic>.from(decoded));
      return card.id.isEmpty ? null : card;
    } catch (_) {
      return null;
    }
  }
}
