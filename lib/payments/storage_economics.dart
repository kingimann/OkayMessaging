/// The unit economics behind the storage plans, so prices are derived from
/// real costs instead of guessed — and provably profitable after the store's
/// cut. All figures are USD per month; keep them in sync with the Supabase
/// plan and the App Store agreement.
///
/// Two costs bite into every paid plan:
///   1. The **store cut**: Apple / Google keep 30% of each in-app purchase, so
///      the developer nets only 70% of the price shown.
///   2. **Supabase**, beyond the amounts the $25 Pro plan already includes:
///        * file storage (Storage buckets): $0.0213 / GB  ← the right backend
///        * database disk (Postgres):       $0.125  / GB  ← the current one
///        * egress:                         $0.09   / GB  (250 GB included)
///
/// Chat backups should live in Storage buckets, not the Postgres sync table —
/// buckets are ~6× cheaper per GB and are what makes selling storage
/// profitable at competitive prices. [monthlyProfit] can be evaluated against
/// either backend so the difference is explicit.
class StorageEconomics {
  StorageEconomics._();

  /// Apple / Google take 30% of every in-app purchase.
  static const double storeCut = 0.30;

  /// Supabase Pro marginal rates (beyond the included allowances).
  static const double fileStoragePerGb = 0.0213; // Storage buckets
  static const double dbDiskPerGb = 0.125; // Postgres disk
  static const double egressPerGb = 0.09;

  /// How much monthly egress to budget per stored GB. The fair-use limit caps
  /// downloads at 3× stored, but a real user restores rarely — half a copy a
  /// month is a conservative-but-sane allowance.
  static const double egressAllowance = 0.5;

  /// What the developer actually keeps from a [grossPrice] after the store cut.
  static double developerNet(double grossPrice) => grossPrice * (1 - storeCut);

  /// Marginal Supabase cost to serve one stored GB for a month, egress
  /// budgeted in. Buckets by default; pass useBuckets:false for the pricier
  /// current Postgres-disk backend.
  static double costPerGb({bool useBuckets = true}) =>
      (useBuckets ? fileStoragePerGb : dbDiskPerGb) +
      egressAllowance * egressPerGb;

  /// Infra cost to hold [gb] of backup for a month.
  static double monthlyCost(int gb, {bool useBuckets = true}) =>
      gb * costPerGb(useBuckets: useBuckets);

  /// Profit (USD/month) from selling [gb] at [grossPrice], after the store cut
  /// and Supabase cost. Positive means the plan makes money.
  static double monthlyProfit(double grossPrice, int gb,
          {bool useBuckets = true}) =>
      developerNet(grossPrice) - monthlyCost(gb, useBuckets: useBuckets);

  /// True when a plan is profitable on the given backend.
  static bool isProfitable(double grossPrice, int gb, {bool useBuckets = true}) =>
      monthlyProfit(grossPrice, gb, useBuckets: useBuckets) > 0;
}
