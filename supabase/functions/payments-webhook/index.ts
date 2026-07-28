// Stripe webhook: keeps our payment metadata in sync with the source of truth.
// Handles payment success/failure, connected-account KYC updates, and payouts
// to the receiver's bank. Configure the endpoint in the Stripe Dashboard and
// set STRIPE_WEBHOOK_SECRET. Deploy with `--no-verify-jwt` (Stripe signs it).

import { admin, corsHeaders, stripe } from "../_shared/stripe.ts";
import { type CardVerdict, judgeCard } from "../_shared/cardholder.ts";

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
      // A chargeback on a peer-to-peer transfer is not a billing dispute with
      // a merchant: the money reached another person who has already been
      // paid, and clawing it back through the card network leaves them
      // carrying the loss. Filing one ends the sender's ability to send.
      //
      // It protects the platform too — Stripe closes accounts whose dispute
      // ratio climbs, and that ratio counts disputes whether they are won or
      // lost.
      // The card is authorised but not yet charged. This is the only moment
      // the cardholder name and funding type are knowable *before* money
      // moves, so both rules are enforced here: capture a card that passes,
      // cancel one that doesn't. A cancelled authorisation releases the hold
      // and the sender is never charged.
      case "payment_intent.amount_capturable_updated": {
        const pi = event.data.object as {
          id: string;
          payment_method?: string;
          metadata?: { verified_name?: string };
        };
        const account = event.account; // direct charges live on the recipient
        const opts = account ? { stripeAccount: account } : undefined;
        let verdict: CardVerdict = { ok: false, reason: "unknown_card" };
        try {
          const pm = pi.payment_method
            ? await stripe.paymentMethods.retrieve(pi.payment_method, opts)
            : null;
          verdict = judgeCard(
            pm?.card as { funding?: string | null } | null,
            pm?.billing_details?.name,
            pi.metadata?.verified_name,
          );
        } catch (_) {
          // Anything we can't inspect, we don't capture.
        }

        if (verdict.ok) {
          await stripe.paymentIntents.capture(pi.id, opts);
          await admin.from("payment_transactions").update({
            status: "succeeded",
            updated_at: new Date().toISOString(),
          }).eq("id", pi.id);
        } else {
          await stripe.paymentIntents.cancel(pi.id, opts);
          await admin.from("payment_transactions").update({
            status: `blocked_${verdict.reason}`,
            updated_at: new Date().toISOString(),
          }).eq("id", pi.id);
        }
        break;
      }
      case "charge.dispute.created": {
        const dispute = event.data.object as {
          id: string;
          charge: string;
          amount: number;
          payment_intent?: string;
        };
        const intentId = dispute.payment_intent;
        if (intentId) {
          const { data: tx } = await admin
            .from("payment_transactions")
            .select("from_phone")
            .eq("id", intentId)
            .maybeSingle();
          if (tx?.from_phone) {
            await admin.from("payment_bans").upsert({
              phone: tx.from_phone,
              reason: "chargeback",
              dispute_id: dispute.id,
              charge_id: dispute.charge,
              amount_cents: dispute.amount,
              banned_at: new Date().toISOString(),
            });
          }
          await admin.from("payment_transactions").update({
            status: "disputed",
            updated_at: new Date().toISOString(),
          }).eq("id", intentId);
        }
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
      // Identity — what actually earns the blue check. Verified is the only
      // status that grants it; everything else (requires_input, canceled,
      // processing) leaves or takes the badge away.
      case "identity.verification_session.verified":
      case "identity.verification_session.requires_input":
      case "identity.verification_session.canceled":
      case "identity.verification_session.processing": {
        const session = event.data.object as {
          id: string;
          status: string;
          metadata?: { phone?: string };
        };
        const phone = session.metadata?.phone;
        if (phone) {
          // On a pass, keep the legal name Stripe read off the document. It
          // is the only trustworthy thing to check a cardholder name against,
          // and verified_outputs has to be asked for explicitly.
          let verifiedName: string | null = null;
          if (session.status === "verified") {
            try {
              const full = await stripe.identity.verificationSessions.retrieve(
                session.id,
                { expand: ["verified_outputs"] },
              );
              const out = (full as { verified_outputs?: { name?: string } })
                .verified_outputs;
              verifiedName = out?.name ?? null;
            } catch (_) {
              // A missing name means the name check can't pass; it must never
              // mean the name check is skipped.
            }
          }
          await admin.from("identity_verifications").upsert({
            phone,
            session_id: session.id,
            status: session.status,
            ...(verifiedName ? { verified_name: verifiedName } : {}),
            updated_at: new Date().toISOString(),
          });
        }
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
