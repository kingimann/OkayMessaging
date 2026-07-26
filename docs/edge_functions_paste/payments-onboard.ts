// PASTE-READY, self-contained version of payments-onboard for the Supabase
// Dashboard editor (Edge Functions -> Deploy a new function -> Via Editor).
// Name the function EXACTLY: payments-onboard
// Identical logic to supabase/functions/payments-onboard/index.ts with the
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

// Creates (or reuses) a Stripe Express connected account for the caller and
// returns a Stripe-hosted onboarding link (account_link) for KYC. This is the
// only hosted step — Stripe requires it for Express identity verification. The
// actual sending of money is fully native (see payments-create-intent).
//
// POST  ->  { url, accountId, chargesEnabled, payoutsEnabled, detailsSubmitted }


Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  try {
    // Reuse an existing account, or create a new Canadian Express account.
    const { data: existing } = await admin
      .from("payment_accounts")
      .select("stripe_account_id")
      .eq("phone", phone)
      .maybeSingle();

    let accountId = existing?.stripe_account_id as string | undefined;
    if (!accountId) {
      const account = await stripe.accounts.create({
        type: "express",
        country: "CA",
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
        business_type: "individual",
        metadata: { phone },
      });
      accountId = account.id;
      await admin.from("payment_accounts").upsert({
        phone,
        stripe_account_id: accountId,
        updated_at: new Date().toISOString(),
      });
    }

    const returnUrl = Deno.env.get("APP_RETURN_URL") ?? "okaymsg://payments/return";
    const link = await stripe.accountLinks.create({
      account: accountId,
      refresh_url: returnUrl,
      return_url: returnUrl,
      type: "account_onboarding",
    });

    const account = await stripe.accounts.retrieve(accountId);
    await admin.from("payment_accounts").update({
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      updated_at: new Date().toISOString(),
    }).eq("phone", phone);

    return json({
      url: link.url,
      accountId,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
