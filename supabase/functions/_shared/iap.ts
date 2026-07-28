// Entitlement bookkeeping shared by the in-app-purchase functions.
//
// One row per Apple subscription, keyed by originalTransactionId (stable for
// the life of a subscription, and the only identifier Apple's renewal
// notifications carry). The phone on the row is what links it back to an
// account, recorded when the app validates the first purchase — Apple's
// notifications never mention it.

// deno-lint-ignore no-explicit-any
type Db = any;

export interface SubscriptionRow {
  originalTransactionId: string;
  phone: string;
  productId: string;
  gb: number;
  expiresAt: string | null;
  status: string;
  environment: string;
}

/// Whether sandbox purchases count towards entitlement.
///
/// They must NOT in production: a sandbox purchase costs nothing and Apple
/// signs it with the same certificate chain as a real one, so without this
/// anyone able to run the app against a Sandbox Apple ID would get paid
/// storage for free. Set IAP_ALLOW_SANDBOX=true only while testing, and take
/// it off before release.
export function sandboxAllowed(): boolean {
  return Deno.env.get("IAP_ALLOW_SANDBOX") === "true";
}

/// The storage size a product grants, or 0 when it isn't a storage product
/// (the tip consumables land here).
export function gbForProduct(productId: string): number {
  const m = /\.storage\.gb(\d+)\.monthly$/.exec(productId);
  return m ? parseInt(m[1], 10) : 0;
}

export async function upsertSubscription(db: Db, row: SubscriptionRow) {
  await db.from("subscriptions").upsert({
    original_transaction_id: row.originalTransactionId,
    phone: row.phone,
    product_id: row.productId,
    gb: row.gb,
    expires_at: row.expiresAt,
    status: row.status,
    environment: row.environment,
    updated_at: new Date().toISOString(),
  });
}

export interface Entitlement {
  active: boolean;
  gb: number;
  expiresAt: string | null;
  productId: string | null;
}

/// What [phone] is entitled to right now: the largest size among their
/// unexpired, unrevoked subscriptions. Taking the largest (rather than the
/// newest) means a mid-cycle downgrade never strands data the user is still
/// paying to keep until the bigger plan actually lapses.
export async function entitlementFor(db: Db, phone: string): Promise<Entitlement> {
  const { data } = await db
    .from("subscriptions")
    .select("product_id, gb, expires_at, status, environment")
    .eq("phone", phone);

  const now = Date.now();
  let best: Entitlement = { active: false, gb: 0, expiresAt: null, productId: null };
  for (const row of data ?? []) {
    if (row.status === "refunded" || row.status === "expired") continue;
    if (row.environment === "Sandbox" && !sandboxAllowed()) continue;
    const expires = row.expires_at ? Date.parse(row.expires_at) : 0;
    if (!expires || expires <= now) continue;
    if (row.gb > best.gb) {
      best = {
        active: true,
        gb: row.gb,
        expiresAt: row.expires_at,
        productId: row.product_id,
      };
    }
  }
  return best;
}

/// Maps an App Store Server Notification type onto the row status we keep.
/// Anything unrecognised leaves the row alone — Apple adds notification types
/// over time and an unknown one must never silently revoke someone's storage.
export function statusForNotification(
  notificationType: string,
  subtype: string,
): string | null {
  switch (notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW":
    case "OFFER_REDEEMED":
      return "active";
    case "DID_CHANGE_RENEWAL_STATUS":
      // AUTO_RENEW_DISABLED means "won't renew", NOT "access ends now" — the
      // paid-for period still has to run out. Keep it active; EXPIRED will
      // arrive when it actually lapses.
      return subtype === "AUTO_RENEW_DISABLED" ? "canceled" : "active";
    case "DID_FAIL_TO_RENEW":
      // In the billing-retry grace period the subscription is still usable.
      return subtype === "GRACE_PERIOD" ? "grace" : "expired";
    case "EXPIRED":
      return "expired";
    case "REFUND":
    case "REVOKE":
      return "refunded";
    default:
      return null;
  }
}
