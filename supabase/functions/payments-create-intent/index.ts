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
  grossUp,
  json,
  stripe,
} from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const fromPhone = await callerPhone(req);
  if (!fromPhone) return json({ error: "unauthorized" }, 401);

  let body: {
    toPhone?: string;
    amountCents?: number;
    currency?: string;
    note?: string;
    receiptEmail?: string;
    // The sender ticked the box saying they understand the transfer is
    // final. Recorded as dispute evidence, not as a gate.
    acknowledged?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }

  // Banned senders cannot start a charge. A chargeback ends the ability to
  // send, and the check belongs here rather than in the app — a client-side
  // ban is a suggestion.
  const { data: ban } = await admin
    .from("payment_bans")
    .select("reason")
    .eq("phone", fromPhone)
    .maybeSingle();
  if (ban) return json({ error: "sender_banned" }, 403);

  // Sending money requires a checked identity. The phone is already verified —
  // callerPhone comes from a Supabase session whose JWT carries an SMS-verified
  // number — so this is the other half.
  const { data: identity } = await admin
    .from("identity_verifications")
    .select("status, verified_name")
    .eq("phone", fromPhone)
    .maybeSingle();
  if (identity?.status !== "verified") {
    return json({ error: "identity_required" }, 403);
  }
  // Without a name there is nothing to check the card against, and the card
  // check is not optional.
  if (!identity.verified_name) {
    return json({ error: "identity_required" }, 403);
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

  // The recipient's own rules come first: they decide who may pay them, and
  // refusing a specific person outranks accepting everyone.
  const { data: recipientSettings } = await admin
    .from("payment_settings")
    .select("accepts_from")
    .eq("phone", toPhone)
    .maybeSingle();
  if (recipientSettings?.accepts_from === "nobody") {
    return json({ error: "recipient_not_accepting" }, 403);
  }
  const { data: blocked } = await admin
    .from("payment_blocks")
    .select("blocked_phone")
    .eq("phone", toPhone)
    .eq("blocked_phone", fromPhone)
    .maybeSingle();
  if (blocked) return json({ error: "recipient_not_accepting" }, 403);

  // A rolling-day cap on the sender. It bounds what a phone someone else has
  // picked up can move, and what one bad afternoon can cost — neither of
  // which the per-transfer checks address.
  const { data: senderSettings } = await admin
    .from("payment_settings")
    .select("daily_send_limit_cents")
    .eq("phone", fromPhone)
    .maybeSingle();
  const dailyLimit = senderSettings?.daily_send_limit_cents ?? 50000;
  if (dailyLimit > 0) {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { data: recent } = await admin
      .from("payment_transactions")
      .select("amount_cents, status")
      .eq("from_phone", fromPhone)
      .gte("updated_at", since);
    // Only money that actually moved (or is still moving) counts. A blocked
    // or failed charge never left the account and must not use up the day.
    const spent = (recent ?? [])
      .filter((t: { status?: string }) =>
        !String(t.status ?? "").startsWith("blocked_") &&
        t.status !== "canceled" &&
        t.status !== "failed"
      )
      .reduce(
        (sum: number, t: { amount_cents?: number }) =>
          sum + (t.amount_cents ?? 0),
        0,
      );
    if (spent + amountCents > dailyLimit) {
      return json({
        error: "daily_limit_reached",
        limitCents: dailyLimit,
        spentCents: spent,
      }, 403);
    }
  }

  try {
    // amountCents is what the RECIPIENT should receive. Both fees come out of
    // the transfer, so the sender is charged the grossed-up total — paying
    // the amount plus the fees, rather than the recipient absorbing them.
    const chargeCents = grossUp(amountCents);
    const feeCents = applicationFee(chargeCents);
    // DIRECT charge, not a destination charge: the PaymentIntent is created
    // ON the recipient's connected account. The money goes straight there and
    // never lands in the platform's balance, so the platform is not in the
    // flow of funds and is not merchant of record.
    //
    // The consequences are the whole point of doing it this way:
    //   * the recipient's account pays Stripe's processing fee, so the
    //     platform's application fee is what it keeps, full stop;
    //   * chargebacks land on the recipient, not the platform — under a
    //     destination charge a dispute clawed money back out of a balance
    //     the platform had already paid away.
    const intent = await stripe.paymentIntents.create({
      amount: chargeCents,
      currency,
      // Enables cards + Apple/Google Pay in the native Payment Sheet.
      automatic_payment_methods: { enabled: true },
      application_fee_amount: feeCents,
      // Authorise now, capture only once the card has been judged. The
      // cardholder name and whether it is prepaid are not knowable until a
      // card is actually attached, so the alternative is checking after the
      // money has moved — which is not a check, it is a refund.
      capture_method: "manual",
      // A statement line the sender will recognise. "STRIPE* SOMETHING" is a
      // leading cause of friendly fraud: people dispute what they don't
      // recognise instead of asking about it.
      statement_descriptor_suffix:
        (Deno.env.get("STATEMENT_DESCRIPTOR") ?? "OKAYMSG").slice(0, 22),
      // Stripe emails a real receipt, which is the other half of the same
      // problem — a charge nobody has a record of is a charge worth
      // disputing.
      receipt_email: body.receiptEmail,
      metadata: {
        from_phone: fromPhone,
        to_phone: toPhone,
        note: body.note ?? "",
        // Evidence, gathered up front. A dispute is defended with what was
        // recorded at the time, so record it at the time: who sent what to
        // whom, and that they confirmed it was final.
        acknowledged_final: body.acknowledged === true ? "yes" : "no",
        acknowledged_at: new Date().toISOString(),
        // Carried on the intent so the capture gate can compare without
        // another round trip to our own database.
        verified_name: identity.verified_name,
      },
    }, { stripeAccount: dest.stripe_account_id });

    await admin.from("payment_transactions").upsert({
      id: intent.id,
      from_phone: fromPhone,
      to_phone: toPhone,
      amount_cents: chargeCents,
      fee_cents: feeCents,
      currency,
      status: intent.status,
      updated_at: new Date().toISOString(),
    });

    return json({
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      // What the sender is charged, and what the recipient is meant to get.
      amountCents: chargeCents,
      targetCents: amountCents,
      feeCents,
      currency,
      // A direct charge's client secret only means anything to the SDK when
      // it is told which connected account the intent lives on.
      stripeAccountId: dest.stripe_account_id,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
