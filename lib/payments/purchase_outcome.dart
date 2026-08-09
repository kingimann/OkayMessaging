/// Why a store purchase ended the way it did.
///
/// WHY THIS EXISTS. Every one of these used to collapse into `false`, and the
/// screen rendered `false` as "Purchase cancelled." — so an account whose
/// products have not been created in App Store Connect yet was told it had
/// changed its mind. Four of the five outcomes below are not a cancellation,
/// and the one that is says so on its own.
enum PurchaseOutcome {
  /// Paid for, and Apple's signed transaction is in hand.
  bought,

  /// The person dismissed the sheet. The only one that is actually a cancel.
  cancelled,

  /// No store on this device, or nobody signed in to it.
  unavailable,

  /// The store has never heard of this product — it has not been created in
  /// App Store Connect, or is not yet approved for sale. Nothing was charged
  /// and nothing was shown; the sheet never opened.
  notOffered,

  /// The store opened and refused, or the purchase errored on its way through.
  failed;

  bool get ok => this == PurchaseOutcome.bought;

  /// What to tell somebody, in words that are true.
  ///
  /// Deliberately says what happened rather than what to do about it: three of
  /// these are the developer's job, not theirs, and inventing an action for
  /// somebody who has none is worse than saying plainly that it is not on sale.
  String get message => switch (this) {
        PurchaseOutcome.bought => 'Done.',
        PurchaseOutcome.cancelled => 'Purchase cancelled.',
        PurchaseOutcome.unavailable =>
          'The App Store isn\'t available here. Check you\'re signed in to it, '
              'or turn on payments test mode in Wallet to try the flow.',
        PurchaseOutcome.notOffered =>
          'This isn\'t on sale yet — it still has to be set up in App Store '
              'Connect. Nothing was charged.',
        PurchaseOutcome.failed =>
          'The App Store couldn\'t complete that. Nothing was charged.',
      };
}

/// What the store answered when asked which of a set of products it sells
/// here — the difference between "the ID doesn't match", "the store can't be
/// reached" and "Apple isn't offering it yet", which a failed purchase alone
/// cannot tell apart.
class StoreQueryResult {
  /// False when there is no store on this device or nobody is signed in to it.
  final bool storeReachable;

  /// Product id → the store's own localized price, for everything it offered.
  final Map<String, String> onSale;

  /// Product id → the ISO currency code behind that price ('USD', 'CAD').
  ///
  /// Carried separately because the localized string cannot be trusted to
  /// say which currency it is: the US and Canadian stores BOTH format as a
  /// bare '$', so "$1.99" on a Canadian device is CAD and looks identical to
  /// USD. The code is the only thing that distinguishes them.
  final Map<String, String> currencies;

  /// The ids the store has never heard of.
  final List<String> notOffered;

  const StoreQueryResult({
    required this.storeReachable,
    this.onSale = const {},
    this.currencies = const {},
    this.notOffered = const [],
  });
}

/// A purchase attempt: how it ended, and Apple's signed transaction when it
/// ended in a purchase.
class PurchaseResult {
  const PurchaseResult(this.outcome, [this.jws]);

  const PurchaseResult.bought(String this.jws)
      : outcome = PurchaseOutcome.bought;

  final PurchaseOutcome outcome;

  /// StoreKit's signed transaction, or null for every outcome but [bought].
  /// What it granted is decided by `iap-validate`, never here.
  final String? jws;

  bool get ok => outcome.ok;
  String get message => outcome.message;
}
