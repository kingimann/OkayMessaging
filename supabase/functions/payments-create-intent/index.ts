// Creates a PaymentIntent that routes money straight to the RECEIVER's Stripe
// connected account (destination charge), taking the platform's application fee
// — the platform never touches the funds. The client confirms this natively
// with the Stripe Payment Sheet (card / Apple Pay / Google Pay), no redirect to
// Stripe Checkout.
//
// POST { toPhone, amountCents, currency?, note? }
//   -> { clientSecret, paymentIntentId, amountCents, feeCents, currency }

import {
  admin,
  applicationFee,
  callerPhone,
  corsHeaders,
  json,
  stripe,
} from "../_shared/stripe.ts";

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
