// Reads and updates this account's payment controls.
//
// POST {}                          -> current settings
// POST { acceptsFrom }             -> 'anyone' | 'nobody'
// POST { paused }                  -> stop/resume everything, both directions
// POST { dailySendLimitCents }     -> the rolling-24h cap
// POST { maxSendCents }            -> the most one transfer may be (0 = no cap)
// POST { block } / { unblock }     -> adjust the refusal list
//
// Enforced in payments-create-intent, not here: this only stores the choice.
//
// Lowering a limit takes effect at once; raising one waits (RAISE_DELAY_MS) and
// comes back as `pendingDaily`/`pendingMax` until it does. The rule lives in
// _shared/payment_limits.ts, where it is tested.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import {
  effectiveLimits,
  type LimitRow,
  limitPatch,
} from "../_shared/payment_limits.ts";

const COLUMNS =
  "accepts_from, paused, daily_send_limit_cents, max_send_cents, " +
  "pending_daily_send_limit_cents, pending_daily_effective_at, " +
  "pending_max_send_cents, pending_max_effective_at";

// The row as this function uses it. Built by hand because the column list is a
// composed string, which supabase-js cannot infer a row shape from.
type SettingsRow = LimitRow & {
  accepts_from?: string | null;
  paused?: boolean | null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let body: {
    acceptsFrom?: string;
    paused?: boolean;
    dailySendLimitCents?: number;
    maxSendCents?: number;
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

  const readSettings = async (): Promise<SettingsRow | null> => {
    const { data } = await admin
      .from("payment_settings")
      .select(COLUMNS)
      .eq("phone", phone)
      .maybeSingle();
    return (data ?? null) as SettingsRow | null;
  };

  const before = await readSettings();

  const patch: Record<string, unknown> = {};
  if (body.acceptsFrom === "anyone" || body.acceptsFrom === "nobody") {
    patch.accepts_from = body.acceptsFrom;
  }
  if (typeof body.paused === "boolean") patch.paused = body.paused;
  // Clamped, delayed when it loosens — a client cannot hand itself an
  // unlimited day, nor a bigger one that starts working immediately.
  Object.assign(patch, limitPatch(before, body, Date.now()));

  if (Object.keys(patch).length > 0) {
    await admin.from("payment_settings").upsert({
      phone,
      ...patch,
      updated_at: new Date().toISOString(),
    });
  }

  // Re-read rather than merging the patch by hand: the row is what the charge
  // path will see, and a scheduled raise is not in the patch at all.
  const data = Object.keys(patch).length > 0 ? await readSettings() : before;
  const { data: blocks } = await admin
    .from("payment_blocks")
    .select("blocked_phone")
    .eq("phone", phone);

  const limits = effectiveLimits(data, Date.now());

  return json({
    acceptsFrom: data?.accepts_from ?? "anyone",
    paused: data?.paused === true,
    // What is live, and what is still waiting — never merged into one number,
    // or the app would show a limit that does not hold yet.
    dailySendLimitCents: limits.dailyCents,
    maxSendCents: limits.maxSendCents,
    pendingDaily: limits.pendingDaily,
    pendingMax: limits.pendingMax,
    blocked: (blocks ?? []).map((b: { blocked_phone: string }) =>
      b.blocked_phone
    ),
  });
});
