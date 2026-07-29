// Reads and updates who may send this account money, and its daily send cap.
//
// POST {}                                   -> current settings
// POST { acceptsFrom, dailySendLimitCents } -> updated settings
// POST { block } / { unblock }              -> adjust the refusal list
//
// Enforced in payments-create-intent, not here: this only stores the choice.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const DEFAULT_DAILY_LIMIT_CENTS = 50000; // $500

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let body: {
    acceptsFrom?: string;
    dailySendLimitCents?: number;
    block?: string;
    unblock?: string;
  } = {};
  try {
    body = await req.json();
  } catch { /* a bare read */ }

  if (body.block) {
    const target = String(body.block).replace(/\D/g, "");
    if (target && target !== phone) {
      await admin.from("payment_blocks")
        .upsert({ phone, blocked_phone: target });
    }
  }
  if (body.unblock) {
    const target = String(body.unblock).replace(/\D/g, "");
    await admin.from("payment_blocks").delete()
      .eq("phone", phone).eq("blocked_phone", target);
  }

  const patch: Record<string, unknown> = {};
  if (body.acceptsFrom === "anyone" || body.acceptsFrom === "nobody") {
    patch.accepts_from = body.acceptsFrom;
  }
  if (typeof body.dailySendLimitCents === "number") {
    // Clamped, so a client can't hand itself an unlimited day.
    patch.daily_send_limit_cents =
      Math.min(Math.max(Math.round(body.dailySendLimitCents), 0), 200000);
  }
  if (Object.keys(patch).length > 0) {
    await admin.from("payment_settings").upsert({
      phone,
      ...patch,
      updated_at: new Date().toISOString(),
    });
  }

  const { data } = await admin
    .from("payment_settings")
    .select("accepts_from, daily_send_limit_cents")
    .eq("phone", phone)
    .maybeSingle();
  const { data: blocks } = await admin
    .from("payment_blocks")
    .select("blocked_phone")
    .eq("phone", phone);

  return json({
    acceptsFrom: data?.accepts_from ?? "anyone",
    dailySendLimitCents:
      data?.daily_send_limit_cents ?? DEFAULT_DAILY_LIMIT_CENTS,
    blocked: (blocks ?? []).map((b: { blocked_phone: string }) =>
      b.blocked_phone
    ),
  });
});
