// Returns the caller's payment/KYC status and their connected-account balance
// (available + pending) plus the latest payout status, so the app can show a
// wallet with a "cash out" state. Balance is read live from Stripe; funds are
// never held by the platform.
//
// POST  ->  { onboarded, chargesEnabled, payoutsEnabled, available, pending,
//             currency, payout: { status, amount, arrivalDate } | null }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";

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
      currency,
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
