import 'package:flutter/material.dart';

import '../models/listing_card.dart';
import '../theme/app_theme.dart';
import 'chat_photo.dart';

/// A marketplace listing shared into a chat, drawn the way Facebook draws
/// one: the photo, the price, the title, and a tap that opens the listing.
///
/// Shows the SNAPSHOT the message carried, never a live lookup. Two reasons,
/// and the second is the one that matters: a live lookup would blank the
/// card on any device that has not fetched the marketplace yet, and it would
/// silently rewrite what somebody sent if the seller changed the price
/// afterwards. The live listing is one tap away and speaks for itself.
class ListingCardContent extends StatelessWidget {
  const ListingCardContent({
    super.key,
    required this.card,
    required this.textColor,
    required this.metaColor,
    this.onOpen,
  });

  final ListingCard card;
  final Color textColor;
  final Color metaColor;

  /// Opens the listing. Null while the bubble is in selection mode.
  final VoidCallback? onOpen;

  /// The price, formatted here rather than imported from the marketplace
  /// screen: a chat bubble reaching into a 6,000-line screen file for a
  /// string helper is how two copies of a screen's logic get written.
  static String priceLabel(int cents) {
    if (cents <= 0) return 'Free';
    final dollars = cents ~/ 100;
    final rem = cents % 100;
    return rem == 0
        ? '\$$dollars'
        : '\$$dollars.${rem.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final facts = [
      if (card.condition.isNotEmpty) card.condition,
      if (card.place.isNotEmpty) card.place,
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onOpen,
      child: Container(
        width: 250,
        decoration: BoxDecoration(
          color: metaColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: metaColor.withValues(alpha: 0.25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (card.photoUrl.isNotEmpty)
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ChatPhoto(url: card.photoUrl, fit: BoxFit.cover),
                  ),
                  if (card.sold)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: const Text('Sold',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(priceLabel(card.priceCents),
                      style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 1),
                  Text(card.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: textColor, fontSize: 14, height: 1.25)),
                  if (facts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: metaColor, fontSize: 12)),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.storefront_outlined,
                          size: 13, color: metaColor),
                      const SizedBox(width: 4),
                      // Flexible: the bubble can hand this less than the
                      // card's nominal width, and a fixed Text in a Row
                      // overflows rather than shrinking.
                      Flexible(
                        child: Text('Marketplace · tap to open',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: metaColor, fontSize: 11.5)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
