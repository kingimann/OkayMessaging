// Cash out to a debit card, in minutes rather than days.
//
// Stripe's standard payout goes to a bank account and settles on a schedule.
// An INSTANT payout goes to a debit card the account has already attached, and
// lands in minutes — for a fee Stripe charges the connected account, never the
// platform. That is the whole reason this can exist without a fee of ours on
// top: there is no platform-side cost to clear.
//
// Two things this deliberately does NOT do:
//
//   * It does not invent a maximum. Stripe reports what is instantly
//     available for this specific account and that number is the ceiling;
//     an amount picked here would be wrong for somebody.
//   * It does not attach the card. Card details must never reach this
//     function or the app — the debit card is added through Stripe's own
//     `payouts` embedded component (see payments-account-session), which is
//     also where Stripe asks the questions it needs to ask.
//
// POST { amountCents?, method? }  ->  { ok, payoutId, status, amountCents,
//                                       feeCents, arrivalDate, method }
// POST { what: "quote" }          ->  { instantAvailable, currency, country,
//                                       hasDebitCard, cardLast4, cardBrand }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";
import { cardPolicy } from "../_shared/card_policy.ts";

/// Stripe's published instant-payout rate by country, mirroring
/// InstantPayoutEconomics on the client. Quoted here too so the receipt the
/// app stores is the server's number, not one the client worked out.
const INSTANT_PERCENT: Record<string, number> = {
  CA: 1.0,
  US: 1.5,
  AU: 1.5,
  GB: 1.0,
  SG: 1.0,
};
const FALLBACK_PERCENT = 1.5;

function feeCentsFor(amountCents: number, country: string | null): number {
  const pct = INSTANT_PERCENT[(country ?? "").toUpperCase()] ?? FALLBACK_PERCENT;
  return Math.ceil((amountCents * pct) / 100);
}

/// The attached external account that a card payout can actually go to.
/// Stripe allows several; the default for the currency is the one it would
/// pick itself, so picking anything else would surprise somebody.
function pickDebitCard(
  account: { external_accounts?: { data?: unknown[] } },
): { id: string; last4?: string; brand?: string; currency?: string } | null {
  const list = account.external_accounts?.data ?? [];
  const cards = list.filter((e) => (e as { object?: string }).object === "card");
  if (cards.length === 0) return null;
  const preferred = cards.find((c) => (c as { default_for_currency?: boolean })
    .default_for_currency) ?? cards[0];
  return preferred as { id: string; last4?: string; brand?: string };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  // Cashing out is money leaving, so it carries the same lock the wallet's
  // other write does: a banned account does not get to move funds while a
  // dispute against it is open.
  const { data: ban } = await admin
    .from("payment_bans")
    .select("reason")
    .eq("phone", phone)
    .maybeSingle();
  if (ban) return json({ error: "sender_banned" }, 403);

  const { data: acct } = await admin
    .from("payment_accounts")
    .select("stripe_account_id")
    .eq("phone", phone)
    .maybeSingle();
  if (!acct?.stripe_account_id) return json({ error: "not_onboarded" }, 400);
  const accountId = acct.stripe_account_id as string;

  let body: { amountCents?: number; method?: string; what?: string } = {};
  try {
    body = await req.json();
  } catch { /* an empty body means "quote" */ }

  try {
    const account = await stripe.accounts.retrieve(accountId);
    const country = (account as { country?: string }).country ?? null;
    const card = pickDebitCard(account as { external_accounts?: { data?: unknown[] } });

    // The card's standing under the takeover safeguards: a newly attached
    // card waits seven business days, and too many changes lock instants.
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
    const policy = cardPolicy({ attachedAts: ats("card"), now: new Date() });
    // The bank's own hold: a changed direct deposit is the other half of
    // the drain, and no manual payout goes to it while the hold runs.
    const bankPolicy = cardPolicy({
      attachedAts: ats("bank"),
      now: new Date(),
    });

    const balance = await stripe.balance.retrieve({ stripeAccount: accountId });
    // `instant_available` is its own bucket and is NOT a slice of
    // `available` — reading the ordinary available balance here would offer
    // people money Stripe will refuse to move instantly.
    const instant = ((balance as {
      instant_available?: { amount: number; currency: string }[];
    }).instant_available ?? []);
    const instantAvailable = instant.reduce((n, b) => n + b.amount, 0);
    const currency = instant[0]?.currency ??
      balance.available[0]?.currency ?? "cad";

    if (body.what === "quote") {
      return json({
        instantAvailable,
        currency,
        country,
        hasDebitCard: card !== null,
        cardLast4: card?.last4 ?? null,
        cardBrand: card?.brand ?? null,
        // So the wallet says WHY the instant button is off, with a number.
        cardHoldBusinessDaysLeft: policy.businessDaysLeft,
        cardLocked: policy.locked,
        bankHoldBusinessDaysLeft: bankPolicy.businessDaysLeft,
        payoutsEnabled: account.payouts_enabled,
      });
    }

    const method = body.method === "standard" ? "standard" : "instant";
    const amountCents = Math.round(Number(body.amountCents ?? 0));
    if (!Number.isFinite(amountCents) || amountCents <= 0) {
      return json({ error: "invalid amount" }, 400);
    }

    if (method === "standard" && bankPolicy.held) {
      return json({
        error: "bank_hold",
        businessDaysLeft: bankPolicy.businessDaysLeft,
      }, 403);
    }
    if (method === "instant") {
      if (!card) return json({ error: "no_debit_card" }, 400);
      // The takeover safeguards, at the moment money would actually move.
      // Standard bank payouts are untouched: a card swap does not redirect
      // where those land.
      if (policy.locked) {
        return json({ error: "card_changes_locked" }, 429);
      }
      if (policy.held) {
        return json({
          error: "card_hold",
          businessDaysLeft: policy.businessDaysLeft,
        }, 403);
      }
      if (amountCents > instantAvailable) {
        return json({
          error: "over_instant_balance",
          instantAvailable,
        }, 400);
      }
    }

    const payout = await stripe.payouts.create({
      amount: amountCents,
      currency,
      method,
      ...(method === "instant" && card ? { destination: card.id } : {}),
      metadata: {
        phone,
        // Recorded at the time, like the transfer evidence is: what somebody
        // was told the fee would be is not reconstructable afterwards.
        quoted_fee_cents: String(feeCentsFor(amountCents, country)),
      },
    }, { stripeAccount: accountId });

    // The webhook keeps payout_status current, but it arrives when it
    // arrives; writing here means the wallet reflects the tap immediately
    // rather than looking like nothing happened.
    await admin.from("payout_status").upsert({
      stripe_account_id: accountId,
      status: payout.status,
      amount_cents: payout.amount,
      arrival_date: new Date(payout.arrival_date * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    });

    return json({
      ok: true,
      payoutId: payout.id,
      status: payout.status,
      amountCents: payout.amount,
      feeCents: feeCentsFor(amountCents, country),
      arrivalDate: new Date(payout.arrival_date * 1000).toISOString(),
      method,
    });
  } catch (e) {
    // Stripe's own words. Its refusals here are specific and useful —
    // "insufficient funds", "no such external account", instant payouts not
    // enabled — and paraphrasing them costs the person the one sentence that
    // says what to fix.
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
