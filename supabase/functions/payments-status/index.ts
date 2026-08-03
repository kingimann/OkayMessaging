// Returns the caller's payment/KYC status and their connected-account balance
// (available + pending) plus the latest payout status, so the app can show a
// wallet with a "cash out" state. Balance is read live from Stripe; funds are
// never held by the platform.
//
// POST  ->  { onboarded, chargesEnabled, payoutsEnabled, available, pending,
//             currency, payout: { status, amount, arrivalDate } | null }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";
import { cardPolicy } from "../_shared/card_policy.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  const { data: acct } = await admin
    .from("payment_accounts")
    .select("stripe_account_id")
    .eq("phone", phone)
    .maybeSingle();

  if (!acct?.stripe_account_id) {
    return json({ onboarded: false, chargesEnabled: false, payoutsEnabled: false });
  }
  const accountId = acct.stripe_account_id as string;

  try {
    const account = await stripe.accounts.retrieve(accountId);
    const balance = await stripe.balance.retrieve({ stripeAccount: accountId });

    const sum = (arr: { amount: number }[]) =>
      arr.reduce((n, b) => n + b.amount, 0);
    const currency = balance.available[0]?.currency ?? "cad";

    // What can be cashed out to a debit card right now. Its own bucket, not
    // a slice of `available` — showing the ordinary balance beside a "cash
    // out instantly" button would offer money Stripe will refuse to move.
    const instantAvailable = sum(
      (balance as { instant_available?: { amount: number }[] })
        .instant_available ?? [],
    );
    const externals = (account.external_accounts?.data ?? []) as {
      object?: string;
      last4?: string;
      brand?: string;
      default_for_currency?: boolean;
    }[];
    const cards = externals.filter((e) => e.object === "card");
    // The default for the currency is the one Stripe would pick itself, so
    // picking anything else would surprise somebody.
    const card = cards.find((c) => c.default_for_currency) ?? cards[0];
    const banks = externals.filter((e) => e.object === "bank_account");
    const bank = banks.find((b) => b.default_for_currency) ?? banks[0];

    // The takeover safeguards' verdicts, so the wallet can say WHY a button
    // is off with a number instead of a refusal three taps later.
    const { data: attachEvents } = await admin
      .from("payment_card_events")
      .select("created_at, kind")
      .eq("phone", phone)
      .order("created_at", { ascending: false })
      .limit(24);
    const ats = (kind: string) =>
      (attachEvents ?? [])
        .filter((e) => ((e as { kind?: string }).kind ?? "card") === kind)
        .map((e) => new Date((e as { created_at: string }).created_at));
    const now = new Date();
    const cardVerdict = cardPolicy({ attachedAts: ats("card"), now });
    const bankVerdict = cardPolicy({ attachedAts: ats("bank"), now });

    // A bank change paused automatic payouts for the hold; the moment the
    // hold has passed, the next wallet visit turns them back on. This app
    // never sets the schedule to manual for any other reason.
    const interval = (account as {
      settings?: { payouts?: { schedule?: { interval?: string } } };
    }).settings?.payouts?.schedule?.interval;
    if (
      !bankVerdict.held && ats("bank").length > 0 && interval === "manual"
    ) {
      try {
        await stripe.accounts.update(accountId, {
          settings: { payouts: { schedule: { interval: "daily" } } },
        });
      } catch (_) { /* the next visit tries again */ }
    }

    // Keep our cached KYC flags fresh.
    await admin.from("payment_accounts").update({
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      updated_at: new Date().toISOString(),
    }).eq("phone", phone);

    const { data: payout } = await admin
      .from("payout_status")
      .select("status, amount_cents, arrival_date")
      .eq("stripe_account_id", accountId)
      .maybeSingle();

    return json({
      onboarded: account.details_submitted,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      available: sum(balance.available),
      pending: sum(balance.pending),
      instantAvailable,
      currency,
      country: (account as { country?: string }).country ?? null,
      hasDebitCard: card !== undefined,
      cardLast4: card?.last4 ?? null,
      cardBrand: card?.brand ?? null,
      cardHoldBusinessDaysLeft: cardVerdict.businessDaysLeft,
      cardLocked: cardVerdict.locked,
      bankLast4: bank?.last4 ?? null,
      bankHoldBusinessDaysLeft: bankVerdict.businessDaysLeft,
      payout: payout
        ? {
          status: payout.status,
          amount: payout.amount_cents,
          arrivalDate: payout.arrival_date,
        }
        : null,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
