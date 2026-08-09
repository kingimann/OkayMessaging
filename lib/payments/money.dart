/// Formats the money this app itself moves — a Stripe wallet balance, a
/// transfer, a cash-out — in the currency it is actually denominated in.
///
/// Why this exists: every one of those amounts already CARRIED its currency
/// (`WalletStatus.currency` off the Stripe account, `PaymentRecord.currency`
/// off the transaction, `PaymentService.sendCurrency` off the sender's own
/// choice) and every screen threw it away and printed a bare '\$'. A Canadian
/// wallet holding CA$50 read as "$50.00", which a reader takes for USD — the
/// same ambiguity that made a store price unreadable, in the one place the
/// app has nobody to blame but itself.
///
/// Distinct from [StorePrices.labelled], which appends an ISO code instead.
/// That one is handed a string Apple already formatted and may not rewrite;
/// here the app owns the whole label, so the symbol can carry the country and
/// no suffix is needed.
abstract class Money {
  /// The symbol for [code], never a bare '\$' where the '\$' is shared.
  ///
  /// USD, CAD and AUD all render as '\$' in their own locales, so a lone '\$'
  /// names no currency at all. Each dollar gets its country: 'US\$', 'CA\$',
  /// 'A\$'. Currencies with a symbol of their own keep it.
  static String symbolFor(String code) => switch (code.toLowerCase()) {
        'usd' => 'US\$',
        'cad' => 'CA\$',
        'aud' => 'A\$',
        'gbp' => '£',
        'eur' => '€',
        // An unknown code names itself rather than borrowing a '$' it may
        // not be entitled to.
        _ => code.isEmpty ? '\$' : '${code.toUpperCase()} ',
      };

  /// [cents] in [currency], symbol first: 'CA\$50.00', 'US\$2.99', '£4.00'.
  ///
  /// [trimWhole] drops the '.00' on a round amount, for the compact places
  /// that showed '\$12' rather than '\$12.00'.
  static String format(int cents, String currency, {bool trimWhole = false}) {
    final amount = trimWhole && cents % 100 == 0
        ? '${cents ~/ 100}'
        : (cents / 100).toStringAsFixed(2);
    return '${symbolFor(currency)}$amount';
  }
}
