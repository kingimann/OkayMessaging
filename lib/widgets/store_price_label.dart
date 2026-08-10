import 'package:flutter/material.dart';

import '../payments/store_prices.dart';
import '../theme/app_theme.dart';

/// A price on a purchase surface, and the one place that decides what to draw
/// when there isn't one yet.
///
/// **The rule: on a phone, the App Store's price or nothing at all.** Apple
/// charges what App Store Connect says, localized to the buyer's storefront,
/// and that string is the ONLY number the app is entitled to print next to a
/// Buy button. Anything computed from the cents in the source — the built-in
/// figure, an owner-published one — is the app's own guess, and a guess beside
/// a Buy button is a promise the charge need not keep.
///
/// Four states, and keeping them apart is the whole job:
///
///  * **the store's price** — what will be charged, already in the buyer's own
///    currency, with the ISO code appended when the symbol cannot say which
///    dollar it is ([StorePrices.labelled]);
///  * **loading** — a real store exists and has not answered yet. A SPINNER,
///    never a dash and never a figure. These used to share the '—', so a price
///    one second away was indistinguishable from one that was never coming;
///  * **unavailable** — the store answered and has never heard of the product,
///    which usually means it is not attached to the version in App Store
///    Connect;
///  * **unknown** — the store was asked and could not be reached.
///
/// Off-device (web, payments-test mode, the test suite) there is no store to
/// be contradicted by, so [StorePrices.money] keeps its plain USD figure and
/// this draws it like any other.
class StorePriceLabel extends StatelessWidget {
  /// What the code assumes, used ONLY where there is no store to ask.
  final int cents;

  /// The product whose real price to show. Empty means there is no store
  /// product behind this amount at all.
  final String productId;

  final TextStyle? style;

  /// Appended to a real price ('/mo'). Never appended to a placeholder — "/mo"
  /// after a spinner reads as a price of nothing per month.
  final String suffix;

  const StorePriceLabel({
    super.key,
    required this.cents,
    required this.productId,
    this.style,
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: StorePrices.instance,
      builder: (context, _) {
        final prices = StorePrices.instance;
        if (prices.awaitingStore && prices.priceFor(productId) == null) {
          return _Loading(style: style);
        }
        final label = prices.money(cents, productId: productId);
        final real = prices.priceFor(productId) != null;
        return Text(
          real && suffix.isNotEmpty ? '$label$suffix' : label,
          style: style,
        );
      },
    );
  }
}

/// Deliberately the size of the text it replaces, so a card does not jump when
/// the real price lands.
class _Loading extends StatelessWidget {
  final TextStyle? style;
  const _Loading({this.style});

  @override
  Widget build(BuildContext context) {
    final size = (style?.fontSize ?? 15) * 0.85;
    return SizedBox(
      height: size,
      width: size,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: AppColors.subtle(context),
      ),
    );
  }
}
