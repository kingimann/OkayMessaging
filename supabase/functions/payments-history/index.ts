// The caller's money history: transfers sent and received, and cash-outs.
//
// Transfers come from payment_transactions, which the webhook keeps current
// — only the caller's own rows; the table is RLS-locked and this is the only
// way in. Cash-outs come from Stripe directly: payouts live on the connected
// account, not in our database, and mirroring them into a table would be a
// second copy that drifts.
//
// POST { limit? } -> {
//   transactions: [{ id, direction, otherPhone, amountCents, feeCents,
//                    currency, status, note, at }],
//   payouts:      [{ id, amountCents, feeCents, currency, status, method, at }],
// }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let limit = 100;
  try {
    const body = await req.json();
    if (typeof body.limit === "number") {
      limit = Math.min(Math.max(body.limit, 1), 200);
    }
  } catch { /* no body is fine */ }

  const { data } = await admin
    .from("payment_transactions")
    .select(
      "id, from_phone, to_phone, amount_cents, fee_cents, currency, status, note, updated_at",
    )
    .or(`from_phone.eq.${phone},to_phone.eq.${phone}`)
    .order("updated_at", { ascending: false })
    .limit(limit);

  // Cash-outs, straight from the connected account. Best-effort: an account
  // that was never onboarded has no payouts, and a Stripe hiccup should not
  // take the transfer list down with it.
  let payouts: Record<string, unknown>[] = [];
  try {
    const { data: acct } = await admin
      .from("payment_accounts")
      .select("stripe_account_id")
      .eq("phone", phone)
      .maybeSingle();
    if (acct?.stripe_account_id) {
      const listed = await stripe.payouts.list(
        { limit: 30 },
        { stripeAccount: acct.stripe_account_id as string },
      );
      payouts = (listed.data ?? []).map((p: {
        id: string;
        amount: number;
        currency: string;
        status: string;
        method: string;
        created: number;
        metadata?: Record<string, string> | null;
      }) => ({
        id: p.id,
        amountCents: p.amount,
        // What the payout was quoted at the time it was made — the fee is
        // not a Stripe field, so it rides the payout's own metadata.
        feeCents: Number(p.metadata?.quoted_fee_cents ?? 0) || 0,
        currency: p.currency,
        status: p.status,
        method: p.method,
        at: new Date(p.created * 1000).toISOString(),
      }));
    }
  } catch { /* payouts stay empty */ }

  return json({
    transactions: (data ?? []).map((t: Record<string, unknown>) => {
      const sent = t.from_phone === phone;
      return {
        id: t.id,
        direction: sent ? "sent" : "received",
        // Never expose the other party's number back to someone who only has
        // one side of the transfer — they already know who they paid.
        otherPhone: sent ? t.to_phone : t.from_phone,
        amountCents: t.amount_cents,
        feeCents: t.fee_cents,
        currency: t.currency,
        status: t.status,
        note: t.note ?? "",
        at: t.updated_at,
      };
    }),
    payouts,
  });
});
