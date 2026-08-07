// Pays a recipient straight from the caller's WALLET BALANCE — no card sheet,
// because the money is already on the balance. Used by the marketplace "Pay
// from wallet" button. The client confirms nothing natively; this moves the
// money server-side and returns whether it worked.
//
// POST { toPhone, amountCents, currency?, note?, acknowledged? }
//   -> { ok, transferId, amountCents, feeCents, currency }
//
// SAFE BY DEFAULT. This function moves money between Stripe Connect accounts,
// and the exact flow depends on where wallet balances live in THIS project's
// Connect topology (top-ups may accrue to the platform balance earmarked per
// user, or to each user's own connected account). Getting that wrong mis-moves
// real money, so the function REFUSES unless WALLET_PAY_ENABLED === "true".
// Turn it on only after verifying the transfer below against your setup. Until
// then the client's test mode simulates the purchase and nothing real happens.

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

  // The owner turns this on once they've verified the Connect flow. Off by
  // default so a deploy can never quietly start moving real money.
  if ((Deno.env.get("WALLET_PAY_ENABLED") ?? "").toLowerCase() !== "true") {
    return json({ error: "not_enabled" }, 503);
  }

  const fromPhone = await callerPhone(req);
  if (!fromPhone) return json({ error: "unauthorized" }, 401);

  let body: {
    toPhone?: string;
    amountCents?: number;
    currency?: string;
    note?: string;
    acknowledged?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }

  // A banned sender cannot move money, same as a card send.
  const { data: ban } = await admin
    .from("payment_bans")
    .select("reason")
    .eq("phone", fromPhone)
    .maybeSingle();
  if (ban) return json({ error: "sender_banned" }, 403);

  // Spending money requires a checked identity, exactly like a card send.
  const { data: identity } = await admin
    .from("identity_verifications")
    .select("status, verified_name")
    .eq("phone", fromPhone)
    .maybeSingle();
  if (identity?.status !== "verified" || !identity.verified_name) {
    return json({ error: "identity_required" }, 403);
  }

  const toPhone = (body.toPhone ?? "").replace(/\D/g, "");
  const amountCents = Math.round(Number(body.amountCents ?? 0));
  const currency = (body.currency ?? "cad").toLowerCase();
  if (!["cad", "usd", "gbp", "eur", "aud"].includes(currency)) {
    return json({ error: "bad_currency" }, 400);
  }
  if (!toPhone || amountCents <= 0) return json({ error: "invalid amount" }, 400);
  if (toPhone === fromPhone) return json({ error: "cannot pay yourself" }, 400);

  // Both sides need onboarded connected accounts: the buyer to spend from, the
  // seller to receive into.
  const { data: from } = await admin
    .from("payment_accounts")
    .select("stripe_account_id")
    .eq("phone", fromPhone)
    .maybeSingle();
  if (!from?.stripe_account_id) {
    return json({ error: "wallet_not_onboarded" }, 409);
  }
  const { data: dest } = await admin
    .from("payment_accounts")
    .select("stripe_account_id, charges_enabled")
    .eq("phone", toPhone)
    .maybeSingle();
  if (!dest?.stripe_account_id || !dest.charges_enabled) {
    return json({ error: "receiver_not_onboarded" }, 409);
  }

  // The recipient's rules first, like create-intent: a paused or not-accepting
  // account, or one that blocked this sender, refuses — and the sender is told
  // the same thing either way.
  const { data: recipientSettings } = await admin
    .from("payment_settings")
    .select("accepts_from, paused")
    .eq("phone", toPhone)
    .maybeSingle();
  if (recipientSettings?.accepts_from === "nobody" ||
      recipientSettings?.paused === true) {
    return json({ error: "recipient_not_accepting" }, 403);
  }
  const { data: blocked } = await admin
    .from("payment_blocks")
    .select("blocked_phone")
    .eq("phone", toPhone)
    .eq("blocked_phone", fromPhone)
    .maybeSingle();
  if (blocked) return json({ error: "recipient_not_accepting" }, 403);

  // The sender's own limits — the same per-transfer and rolling-day caps a card
  // send obeys. A wallet is not a way around them.
  const { data: senderRow } = await admin
    .from("payment_settings")
    .select(
      "paused, daily_send_limit_cents, max_send_cents, " +
        "pending_daily_send_limit_cents, pending_daily_effective_at, " +
        "pending_max_send_cents, pending_max_effective_at",
    )
    .eq("phone", fromPhone)
    .maybeSingle();
  const senderSettings =
    (senderRow ?? null) as (LimitRow & { paused?: boolean | null }) | null;
  if (senderSettings?.paused === true) {
    return json({ error: "payments_paused" }, 403);
  }
  const limits = effectiveLimits(senderSettings, Date.now());

  let spent = 0;
  if (limits.dailyCents > 0) {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { data: recent } = await admin
      .from("payment_transactions")
      .select("amount_cents, status")
      .eq("from_phone", fromPhone)
      .gte("updated_at", since);
    spent = (recent ?? [])
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
  }
  // The recipient should receive amountCents; both fees come out of the total,
  // so the balance is charged the grossed-up figure — same rule as a card send.
  const chargeCents = grossUp(amountCents);
  const refusal = refusalFor(limits, chargeCents, spent);
  if (refusal) return json(refusal, 403);

  try {
    // The buyer must actually have the money on their balance.
    const balance = await stripe.balance.retrieve(
      {},
      { stripeAccount: from.stripe_account_id },
    );
    const availableForCurrency =
      (balance.available ?? []).find((b: { currency?: string; amount?: number }) =>
        (b.currency ?? "").toLowerCase() === currency)?.amount ?? 0;
    if (availableForCurrency < chargeCents) {
      return json({ error: "insufficient_balance" }, 402);
    }

    const feeCents = applicationFee(chargeCents);
    // Move the money. This is the ONE line whose exact shape depends on the
    // project's Connect topology and MUST be verified before WALLET_PAY_ENABLED
    // is set: it debits the buyer's connected balance and credits the seller's.
    // Modelled as a connected-account transfer to the seller, with the platform
    // taking its application fee. If your top-ups instead accrue to the platform
    // balance, replace this with a platform-level transfer to dest and a
    // matching debit of the buyer — see the header note.
    const transfer = await stripe.transfers.create(
      {
        amount: amountCents,
        currency,
        destination: dest.stripe_account_id,
        metadata: {
          from_phone: fromPhone,
          to_phone: toPhone,
          note: body.note ?? "",
          source: "wallet",
          fee_cents: String(feeCents),
          acknowledged_final: body.acknowledged === true ? "yes" : "no",
          acknowledged_at: new Date().toISOString(),
        },
      },
      { stripeAccount: from.stripe_account_id },
    );

    await admin.from("payment_transactions").upsert({
      id: transfer.id,
      from_phone: fromPhone,
      to_phone: toPhone,
      amount_cents: chargeCents,
      fee_cents: feeCents,
      currency,
      status: "succeeded",
      note: body.note ?? "",
      updated_at: new Date().toISOString(),
    });

    return json({
      ok: true,
      transferId: transfer.id,
      amountCents: chargeCents,
      targetCents: amountCents,
      feeCents,
      currency,
    });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e) }, 400);
  }
});
