// PASTE-READY, self-contained version of payments-status for the Supabase
// Dashboard editor (Edge Functions -> Deploy a new function -> Via Editor).
// Name the function EXACTLY: payments-status
// Identical logic to supabase/functions/payments-status/index.ts with the
// _shared/stripe.ts helpers inlined (the paste editor has no shared files).

import Stripe from "https://esm.sh/stripe@16.12.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function callerPhone(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const token = auth.replace("Bearer ", "");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  const phone = data.user.phone ?? "";
  return phone ? phone.replace(/\D/g, "") : null;
}

// Returns the caller's payment/KYC status and their connected-account balance
// (available + pending) plus the latest payout status, so the app can show a
// wallet with a "cash out" state. Balance is read live from Stripe; funds are
// never held by the platform.
//
// POST  ->  { onboarded, chargesEnabled, payoutsEnabled, available, pending,
//             currency, payout: { status, amount, arrivalDate } | null }


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
