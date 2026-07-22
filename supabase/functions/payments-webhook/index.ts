// Stripe webhook: keeps our payment metadata in sync with the source of truth.
// Handles payment success/failure, connected-account KYC updates, and payouts
// to the receiver's bank. Configure the endpoint in the Stripe Dashboard and
// set STRIPE_WEBHOOK_SECRET. Deploy with `--no-verify-jwt` (Stripe signs it).

import { admin, corsHeaders, stripe } from "../_shared/stripe.ts";

const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig!, webhookSecret);
  } catch (e) {
    return new Response(`bad signature: ${(e as Error).message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "payment_intent.succeeded":
      case "payment_intent.payment_failed":
      case "payment_intent.processing": {
        const pi = event.data.object as { id: string; status: string };
        await admin.from("payment_transactions").update({
          status: pi.status,
          updated_at: new Date().toISOString(),
        }).eq("id", pi.id);
        break;
      }
      case "account.updated": {
        const acct = event.data.object as {
          id: string;
          charges_enabled: boolean;
          payouts_enabled: boolean;
          details_submitted: boolean;
        };
        await admin.from("payment_accounts").update({
          charges_enabled: acct.charges_enabled,
          payouts_enabled: acct.payouts_enabled,
          details_submitted: acct.details_submitted,
          updated_at: new Date().toISOString(),
        }).eq("stripe_account_id", acct.id);
        break;
      }
      case "payout.created":
      case "payout.paid":
      case "payout.failed":
      case "payout.canceled": {
        const payout = event.data.object as {
          status: string;
          amount: number;
          arrival_date: number;
        };
        const accountId = event.account; // connected account id
        if (accountId) {
          await admin.from("payout_status").upsert({
            stripe_account_id: accountId,
            status: payout.status,
            amount_cents: payout.amount,
            arrival_date: new Date(payout.arrival_date * 1000).toISOString(),
            updated_at: new Date().toISOString(),
          });
        }
        break;
      }
    }
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(`handler error: ${(e as Error).message}`, { status: 500 });
  }
});
