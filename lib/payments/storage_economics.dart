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
/// On a destination charge the platform is merchant of record: Stripe's
/// processing fee comes out of the platform's balance, and only the
/// application fee comes back in — so the fee must exceed Stripe's cut or
/// every transfer loses money.
class PaymentEconomics {
  PaymentEconomics._();

  /// What Stripe charges the platform per successful charge on a card issued
  /// in the platform's own country.
  static const double stripePercent = 2.9;
  static const int stripeFixedCents = 30;

  /// Stripe surcharges cards issued abroad. The sender picks the card, not us,
  /// so this is the rate that has to be planned for — budgeting on the
  /// domestic one and hoping is how a fee schedule quietly goes underwater.
  static const double internationalSurchargePercent = 0.8;

  /// The worst realistic rate: an international card.
  static double get worstCasePercent =>
      stripePercent + internationalSurchargePercent;

  /// What the platform charges. Clears Stripe's domestic cut comfortably; the
  /// floor below is what handles the international case.
  static const double platformPercent = 3.4;
  static const int platformFixedCents = 35;

  /// Stripe's cost for an [amountCents] charge on a domestic card.
  static int stripeCostCents(int amountCents) =>
      (amountCents * stripePercent / 100).round() + stripeFixedCents;

  /// Stripe's cost when the sender pays with a card issued abroad.
  static int worstCaseStripeCostCents(int amountCents) =>
      (amountCents * worstCasePercent / 100).round() + stripeFixedCents;

  /// The platform's application fee.
  ///
  /// Floored at the *international* cost rather than the domestic one. At
  /// 3.4% + 35¢ against an international card's 3.7% + 30¢ the two cross at
  /// about \$17.75, and every transfer above that lost money — invisibly,
  /// since nothing about the charge says which country issued the card.
  /// The floor makes the worst case break even instead of bleed, and leaves
  /// smaller transfers untouched.
  static int applicationFeeCents(int amountCents) {
    final fee =
        (amountCents * platformPercent / 100).round() + platformFixedCents;
    final floor = worstCaseStripeCostCents(amountCents) + 1;
    return fee > floor ? fee : floor;
  }

  /// What the platform keeps on an [amountCents] transfer paid by a domestic
  /// card.
  static int netCents(int amountCents) =>
      applicationFeeCents(amountCents) - stripeCostCents(amountCents);

  /// What the platform keeps when the card was issued abroad — the thin case.
  static int worstCaseNetCents(int amountCents) =>
      applicationFeeCents(amountCents) - worstCaseStripeCostCents(amountCents);

  /// Every transfer must leave the platform ahead, whichever card is used.
  static bool isProfitable(int amountCents) =>
      netCents(amountCents) > 0 && worstCaseNetCents(amountCents) > 0;
}
