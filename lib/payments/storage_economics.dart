/// The unit economics behind cloud storage, so prices are derived from real
/// costs instead of guessed — and provably profitable after the store's cut,
/// *including* once the project outgrows its included allowance.
///
/// Two costs bite into every paid GB:
///   1. The **store cut**: Apple / Google keep 30% of each in-app purchase, so
///      the developer nets only 70% of the price shown.
///   2. **Supabase**, at the rates that apply once the $25 Pro plan's included
///      allowances are used up:
///        * file storage (Storage buckets): $0.0213 / GB  ← the right backend
///        * database disk (Postgres):       $0.125  / GB  ← the current one
///        * egress:                         $0.09   / GB  (250 GB included)
///
/// The key property this file enforces: **every GB sold is priced above its
/// own marginal overage cost.** That's what makes going past the project's
/// included 100 GB safe — the user who pushed usage over has already paid more
/// than the extra Supabase bill for their own GB, so growth never costs money.
/// There is no retroactive surcharge (the App Store can't bill variable
/// amounts anyway); the margin is built into the per-GB price up front.
class StorageEconomics {
  StorageEconomics._();

  /// Apple / Google take 30% of every in-app purchase.
  static const double storeCut = 0.30;

  /// Supabase Pro marginal rates (what a GB costs *beyond* the included
  /// allowances — i.e. exactly the overage the project starts paying).
  static const double fileStoragePerGb = 0.0213; // Storage buckets
  static const double dbDiskPerGb = 0.125; // Postgres disk
  static const double egressPerGb = 0.09;

  /// Storage included in the $25 Pro plan. Past this, every GB bills at the
  /// overage rates above — which the per-GB price already covers.
  static const int includedGb = 100;

  /// How much monthly egress to budget per stored GB. A real user restores
  /// rarely — half a copy a month is a conservative-but-sane allowance.
  static const double egressAllowance = 0.5;

  /// The most egress a stored GB can pull in a month before it stops paying
  /// for itself. Above [maxEgressMultiple] the download bill overtakes what
  /// the plan earns after Apple's cut, so the fair-use ceiling has to sit
  /// under it — an allowance the price can't cover isn't fair use, it's a
  /// loss the user is entitled to take.
  static double get breakEvenEgressMultiple =>
      (developerNet(pricePerGb) - fileStoragePerGb) / egressPerGb;

  /// The fair-use ceiling actually enforced (see `docs/storage_usage_setup.sql`
  /// and the Terms). Deliberately below [breakEvenEgressMultiple], with room
  /// to spare, while still allowing a full restore of everything you store
  /// every single month.
  static const double fairUseEgressMultiple = 1.0;

  /// The retail rate: what a user pays per GB per month, before Apple's cut.
  /// Set well above [costPerGb] so every GB — included or overage — profits.
  static const double pricePerGb = 0.20;

  /// What the developer actually keeps from a [grossPrice] after the store cut.
  static double developerNet(double grossPrice) => grossPrice * (1 - storeCut);

  /// Marginal Supabase cost to serve one stored GB for a month, egress
  /// budgeted in. Buckets by default; pass useBuckets:false for the pricier
  /// current Postgres-disk backend.
  static double costPerGb({bool useBuckets = true}) =>
      (useBuckets ? fileStoragePerGb : dbDiskPerGb) +
      egressAllowance * egressPerGb;

  /// The lowest price per GB that merely breaks even after the store's cut.
  /// [pricePerGb] must sit above this for the model to work.
  static double breakEvenPricePerGb({bool useBuckets = true}) =>
      costPerGb(useBuckets: useBuckets) / (1 - storeCut);

  /// Infra cost to hold [gb] of backup for a month.
  static double monthlyCost(int gb, {bool useBuckets = true}) =>
      gb * costPerGb(useBuckets: useBuckets);

  /// Profit (USD/month) from selling [gb] at [grossPrice], after the store cut
  /// and Supabase cost. Positive means the plan makes money.
  static double monthlyProfit(double grossPrice, int gb,
          {bool useBuckets = true}) =>
      developerNet(grossPrice) - monthlyCost(gb, useBuckets: useBuckets);

  /// True when a plan is profitable on the given backend.
  static bool isProfitable(double grossPrice, int gb,
          {bool useBuckets = true}) =>
      monthlyProfit(grossPrice, gb, useBuckets: useBuckets) > 0;

  /// Whether [grossPrice] for [gb] still covers cost when those GB are
  /// *overage* — i.e. the project has already used its included allowance and
  /// Supabase is billing per GB. Since the included and overage rates are the
  /// same marginal numbers, this is the honest test that growth is safe.
  static bool coversOverage(double grossPrice, int gb,
          {bool useBuckets = true}) =>
      isProfitable(grossPrice, gb, useBuckets: useBuckets);
}

/// The economics of peer-to-peer transfers (the Stripe side).
///
/// Mirrors `supabase/functions/_shared/stripe.ts` so the margin is verifiable
/// in the test suite and the app can quote an honest fee before someone pays.
///
/// Transfers are **direct charges**: the PaymentIntent is created on the
/// recipient's connected account, so the money never passes through the
/// platform's balance. Three things follow, and they are why it is done this
/// way:
///
///   1. The platform is not in the flow of funds and is not merchant of
///      record — it never holds anyone's money.
///   2. The recipient's account pays Stripe's processing fee, so the
///      application fee is what the platform keeps, in full. A transfer
///      cannot lose the platform money, whatever card the sender used.
///   3. Disputes land on the recipient. Under a destination charge a
///      chargeback clawed funds back out of the platform's balance after it
///      had already paid them away.
///
/// The trade is that the recipient receives the amount minus BOTH fees, so
/// the send sheet has to say so plainly rather than quote the typed amount.
class PaymentEconomics {
  PaymentEconomics._();

  /// What Stripe charges *the recipient's account* per successful charge on a
  /// domestic card. The platform never pays this on a direct charge; it is
  /// modelled only so the sender can be shown a realistic landing amount.
  static const double stripePercent = 2.9;
  static const int stripeFixedCents = 30;

  /// Stripe surcharges cards issued abroad. Also the recipient's cost, not the
  /// platform's — kept so the quoted estimate can be honest about the range.
  static const double internationalSurchargePercent = 0.8;

  static double get worstCasePercent =>
      stripePercent + internationalSurchargePercent;

  /// What the platform charges. On a direct charge this is pure revenue: no
  /// floor is needed, because there is no platform-side cost for it to clear.
  ///
  /// The fixed part is deliberately small. It used to be 35¢, which on a $5
  /// transfer was 10.4% on its own — the fixed components dominate small
  /// amounts, and someone splitting a coffee shouldn't watch a fifth of it
  /// disappear. Since a transfer costs the platform nothing to carry, there
  /// is no floor to respect: the fee can be whatever is fair.
  static const double platformPercent = 3.4;
  static const int platformFixedCents = 10;

  /// Stripe's cost to the RECIPIENT for an [amountCents] charge, domestic card.
  static int stripeCostCents(int amountCents) =>
      (amountCents * stripePercent / 100).round() + stripeFixedCents;

  /// Stripe's cost to the recipient when the sender's card was issued abroad.
  static int worstCaseStripeCostCents(int amountCents) =>
      (amountCents * worstCasePercent / 100).round() + stripeFixedCents;

  /// The platform's application fee.
  static int applicationFeeCents(int amountCents) =>
      (amountCents * platformPercent / 100).round() + platformFixedCents;

  /// What the platform keeps: the whole application fee. Stripe's cut comes
  /// out of the recipient's account, not the platform's.
  static int netCents(int amountCents) => applicationFeeCents(amountCents);

  /// Same on a foreign card — the platform's side does not vary by card.
  static int worstCaseNetCents(int amountCents) => netCents(amountCents);

  /// Every transfer leaves the platform ahead, by construction.
  static bool isProfitable(int amountCents) => netCents(amountCents) > 0;

  /// The smallest transfer worth making.
  ///
  /// Stripe's own floor is 50¢, but the fixed parts of both fees (10¢ + 30¢)
  /// would eat 86% of that — send 50¢ and 7¢ lands, which is not a payment,
  /// it is a complaint waiting to happen. This is the first round amount
  /// where the recipient keeps at least three quarters of it.
  static const int minimumSendCents = 300;

  /// Whether [amountCents] leaves enough of itself to be worth sending.
  static bool isWorthSending(int amountCents) =>
      amountCents >= minimumSendCents;

  /// What the sender must be charged so [targetCents] actually reaches the
  /// recipient.
  ///
  /// Both fees come out of the transfer, so charging exactly what was typed
  /// delivers less than that — send \$5 and \$4.28 lands. Grossing up moves
  /// the fees onto the sender, which is what "pay the amount plus the fees"
  /// means and what people expect when they type a number.
  ///
  /// Solved by search rather than algebra: the fees round to whole cents, so
  /// a closed form lands a cent out either way. This walks up from the
  /// arithmetic estimate to the first total that genuinely clears the target,
  /// which is exact by construction.
  static int grossUpCents(int targetCents) {
    if (targetCents <= 0) return 0;
    const rate = 1 - (platformPercent + stripePercent) / 100;
    var total =
        ((targetCents + platformFixedCents + stripeFixedCents) / rate).floor();
    // A handful of steps at most; the estimate is never far off.
    for (var i = 0; i < 8; i++) {
      if (estimatedReceivedCents(total) >= targetCents) return total;
      total++;
    }
    return total;
  }

  /// Roughly what lands in the recipient's account: the amount less the
  /// platform fee and Stripe's processing fee. Approximate because the card's
  /// issuing country — which moves Stripe's rate — is not known until the
  /// charge is made.
  static int estimatedReceivedCents(int amountCents) {
    final left = amountCents -
        applicationFeeCents(amountCents) -
        stripeCostCents(amountCents);
    return left < 0 ? 0 : left;
  }

  /// The low end of that estimate, if the sender pays with a foreign card.
  static int worstCaseReceivedCents(int amountCents) {
    final left = amountCents -
        applicationFeeCents(amountCents) -
        worstCaseStripeCostCents(amountCents);
    return left < 0 ? 0 : left;
  }
}
