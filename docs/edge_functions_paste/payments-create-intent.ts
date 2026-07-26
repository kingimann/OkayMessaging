// PASTE-READY, self-contained version of payments-create-intent for the Supabase
// Dashboard editor (Edge Functions -> Deploy a new function -> Via Editor).
// Name the function EXACTLY: payments-create-intent
// Identical logic to supabase/functions/payments-create-intent/index.ts with the
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

function applicationFee(amountCents: number): number {
  const pct = parseFloat(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "1.5");
  const fixed = parseInt(Deno.env.get("PLATFORM_FEE_FIXED_CENTS") ?? "0", 10);
  return Math.round((amountCents * pct) / 100) + fixed;
}

// Creates a PaymentIntent that routes money straight to the RECEIVER's Stripe
// connected account (destination charge), taking the platform's application fee
// — the platform never touches the funds. The client confirms this natively
// with the Stripe Payment Sheet (card / Apple Pay / Google Pay), no redirect to
// Stripe Checkout.
//
// POST { toPhone, amountCents, currency?, note? }
//   -> { clientSecret, paymentIntentId, amountCents, feeCents, currency }


Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const fromPhone = await callerPhone(req);
  if (!fromPhone) return json({ error: "unauthorized" }, 401);

  let body: { toPhone?: string; amountCents?: number; currency?: string; note?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }

  const toPhone = (body.toPhone ?? "").replace(/\D/g, "");
  const amountCents = Math.round(Number(body.amountCents ?? 0));
  const currency = (body.currency ?? "cad").toLowerCase();
  if (!toPhone || amountCents <= 0) return json({ error: "invalid amount" }, 400);
  if (toPhone === fromPhone) return json({ error: "cannot pay yourself" }, 400);

  // The receiver must have an onboarded, payout-enabled connected account.
  const { data: dest } = await admin
    .from("payment_accounts")
    .select("stripe_account_id, charges_enabled, payouts_enabled")
    .eq("phone", toPhone)
    .maybeSingle();
  if (!dest?.stripe_account_id || !dest.charges_enabled) {
    return json({ error: "receiver_not_onboarded" }, 409);
  }

  try {
    const feeCents = applicationFee(amountCents);
    const intent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency,
      // Enables cards + Apple/Google Pay in the native Payment Sheet.
      automatic_payment_methods: { enabled: true },
      application_fee_amount: feeCents,
      transfer_data: { destination: dest.stripe_account_id },
      metadata: { from_phone: fromPhone, to_phone: toPhone, note: body.note ?? "" },
    });

    await admin.from("payment_transactions").upsert({
      id: intent.id,
      from_phone: fromPhone,
      to_phone: toPhone,
      amount_cents: amountCents,
      fee_cents: feeCents,
      currency,
      status: intent.status,
      updated_at: new Date().toISOString(),
    });

    return json({
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      amountCents,
      feeCents,
      currency,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
