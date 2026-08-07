// Adds money to the caller's OWN wallet — a top-up. Unlike a peer transfer
// (payments-create-intent), which is a DIRECT charge on the recipient's
// connected account and keeps the platform out of the flow of funds, a
// self-top-up has no second party, so it is a DESTINATION charge: the card
// is charged on the platform and the net is transferred into the caller's
// own connected-account balance. The platform is briefly the merchant of
// record for its own user's funds — unavoidable when there is nobody else
// in the transaction — and keeps only its application fee.
//
// The amount TYPED is what lands in the balance: the charge is grossed up so
// the fees ride on the funder, which is what "add $50" is expected to mean.
//
// POST { amountCents, currency? }
//   -> { clientSecret, paymentIntentId, chargeCents, addedCents, feeCents, currency }

import {
  admin,
  applicationFee,
  callerPhone,
  corsHeaders,
  grossUp,
  json,
  stripe,
} from "../_shared/stripe.ts";
import {
  effectiveLimits,
  type LimitRow,
  refusalFor,
} from "../_shared/payment_limits.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let body: { amountCents?: number; currency?: string; receiptEmail?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }

  // A banned account cannot move money in either direction.
  const { data: ban } = await admin
    .from("payment_bans")
    .select("reason")
    .eq("phone", phone)
    .maybeSingle();
  if (ban) return json({ error: "sender_banned" }, 403);

  // The identity check that gates sending gates funding too — funding a wallet
  // with a stranger's card is the money-laundering shape the check refuses. But
  // for a TOP-UP, VERIFICATION is the bar, not a captured legal name: no name
  // rides this charge (the card is KYC'd by Stripe at charge time), so requiring
  // one only turned genuinely-verified accounts away when Stripe returned no
  // name to store. A person-to-person SEND still needs the name — it travels on
  // that intent — so this relaxation is top-up only.
  const { data: identity } = await admin
    .from("identity_verifications")
    .select("status, verified_name")
    .eq("phone", phone)
    .maybeSingle();
  if (identity?.status !== "verified") {
    return json({ error: "identity_required" }, 403);
  }

  // The caller's own connected account is where the money lands. It has to
  // exist and be able to receive — the same onboarding that lets them be
  // paid at all.
  const { data: acct } = await admin
    .from("payment_accounts")
    .select("stripe_account_id, charges_enabled, payouts_enabled")
    .eq("phone", phone)
    .maybeSingle();
  if (!acct?.stripe_account_id || !acct.payouts_enabled) {
    return json({ error: "not_onboarded" }, 409);
  }

  const addedCents = Math.round(Number(body.amountCents ?? 0));
  const currency = (body.currency ?? "cad").toLowerCase();
  if (!["cad", "usd", "gbp", "eur", "aud"].includes(currency)) {
    return json({ error: "bad_currency" }, 400);
  }
  if (addedCents <= 0) return json({ error: "invalid amount" }, 400);

  // The per-transfer and rolling-day caps apply to a top-up too: a phone in
  // the wrong hands funding a wallet to drain elsewhere is the case the
  // day-cap exists for. Reuse the sender's own limits.
  const { data: settings } = await admin
    .from("payment_settings")
    .select(
      "daily_send_limit_cents, max_send_cents, " +
        "pending_daily_send_limit_cents, pending_daily_effective_at, " +
        "pending_max_send_cents, pending_max_effective_at")
    .eq("phone", phone)
    .maybeSingle();
  const { data: spentRows } = await admin
    .from("payment_transactions")
    .select("amount_cents, created_at, status")
    .eq("from_phone", phone)
    .gte("created_at", new Date(Date.now() - 24 * 3600 * 1000).toISOString());
  // Only money that ACTUALLY MOVED counts against the daily cap. A top-up
  // whose card sheet was never completed sits at requires_payment_method
  // (and requires_confirmation / requires_action / canceled are likewise
  // uncharged) — counting those let a run of FAILED attempts lock the account
  // out of the very retry that would succeed. Count succeeded + in-flight
  // (processing / requires_capture) only.
  const countsTowardSpend = (s: unknown) =>
    s === "succeeded" || s === "processing" || s === "requires_capture";
  const spent = (spentRows ?? [])
    .filter((r) => countsTowardSpend(r.status))
    .reduce((n, r) => n + Number(r.amount_cents ?? 0), 0);

  const chargeCents = grossUp(addedCents);
  const limits = effectiveLimits((settings ?? {}) as LimitRow, Date.now());
  const refusal = refusalFor(limits, chargeCents, spent);
  if (refusal) return json(refusal, 403);

  const feeCents = chargeCents - addedCents;

  // HOSTED CHECKOUT: the native in-app Payment Sheet (flutter_stripe) proved
  // unable to present on some devices — it returned a silent cancel and no
  // card was ever collected. Stripe's own hosted Checkout page, loaded in the
  // app's WebView (the same surface Connect onboarding uses), sidesteps the
  // native sheet entirely. Same destination charge, just collected on Stripe's
  // page instead of in a native modal. The client asks for this with
  // { hosted: true, returnUrl } and gets a URL to open.
  if (body.hosted === true) {
    const returnUrl = typeof body.returnUrl === "string" && body.returnUrl
      ? body.returnUrl
      : "https://stripe.com";
    try {
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              currency,
              product_data: { name: "Add to wallet" },
              unit_amount: chargeCents,
            },
            quantity: 1,
          },
        ],
        payment_intent_data: {
          application_fee_amount: feeCents,
          transfer_data: { destination: acct.stripe_account_id },
          statement_descriptor_suffix:
            (Deno.env.get("STATEMENT_DESCRIPTOR") ?? "OKAYMSG").slice(0, 22),
          metadata: {
            kind: "topup",
            from_phone: phone,
            to_phone: phone,
            verified_name: identity.verified_name ?? "",
          },
        },
        ...(body.receiptEmail ? { customer_email: body.receiptEmail } : {}),
        // Checkout navigates to these when it finishes; the WebView catches
        // the navigation and returns the user to the app.
        success_url: `${returnUrl}?topup=ok`,
        cancel_url: `${returnUrl}?topup=cancel`,
      });
      return json({
        checkoutUrl: session.url,
        sessionId: session.id,
        chargeCents,
        addedCents,
        feeCents,
        currency,
      });
    } catch (e) {
      return json({ error: String((e as Error).message ?? e) }, 400);
    }
  }

  try {
    // application_fee_amount is what the platform KEEPS; the rest of the
    // charge transfers into the caller's balance. Set it to exactly the
    // grossed-up surplus so the balance receives what was typed. Stripe's
    // own processing fee comes out of the platform's cut, which grossUp
    // already sized to stay positive.
    // Card-only, deliberately NOT automatic_payment_methods. A top-up only
    // ever needs a card, and enabling Link (which automatic_payment_methods
    // turns on) makes the mobile Payment Sheet demand a return URL it hasn't
    // been given — so initPaymentSheet throws before it can render, and the
    // person sees "add money" fail the instant they tap it with no card ever
    // asked for. One payment method, no redirect surface, no failure.
    const intent = await stripe.paymentIntents.create({
      amount: chargeCents,
      currency,
      payment_method_types: ["card"],
      application_fee_amount: feeCents,
      transfer_data: { destination: acct.stripe_account_id },
      statement_descriptor_suffix:
        (Deno.env.get("STATEMENT_DESCRIPTOR") ?? "OKAYMSG").slice(0, 22),
      receipt_email: body.receiptEmail,
      metadata: {
        kind: "topup",
        from_phone: phone,
        to_phone: phone,
        verified_name: identity.verified_name,
      },
    });

    await admin.from("payment_transactions").upsert({
      id: intent.id,
      from_phone: phone,
      to_phone: phone,
      amount_cents: chargeCents,
      fee_cents: feeCents,
      currency,
      status: intent.status,
      note: "Added to wallet",
      updated_at: new Date().toISOString(),
    });

    return json({
      clientSecret: intent.client_secret,
      paymentIntentId: intent.id,
      chargeCents,
      addedCents,
      feeCents,
      currency,
      // A destination charge lives on the PLATFORM account, so — unlike a
      // direct charge — the SDK needs no connected-account id to confirm it.
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
