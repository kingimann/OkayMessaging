// The caller's transfers, sent and received.
//
// Reads payment_transactions, which the webhook keeps current, and returns
// both directions in one list so the app can show a single history. Only the
// caller's own rows — the table is RLS-locked and this is the only way in.
//
// POST { limit? } -> { transactions: [{ id, direction, otherPhone,
//                       amountCents, feeCents, status, at }] }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

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
    .select("id, from_phone, to_phone, amount_cents, fee_cents, currency, status, updated_at")
    .or(`from_phone.eq.${phone},to_phone.eq.${phone}`)
    .order("updated_at", { ascending: false })
    .limit(limit);

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
        at: t.updated_at,
      };
    }),
  });
});
