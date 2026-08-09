// Owner-editable pricing — the owner's console for keeping the prices the APP
// assumes in step with App Store Connect, without shipping a build.
//
// POST { what: 'get' }
//   -> { prices }   (also served straight from the table via anon SELECT;
//      this verb exists for symmetry/debugging)
// POST { what: 'publish', prices } -> { ok: true }   OWNER ONLY.
//
// These numbers are NOT what anyone is charged: Apple charges what the SKU
// says, and the app shows StoreKit's own localized price whenever it has one.
// They fill in where there is no store price (web, payments-test mode, the
// frame before StoreKit answers) and set the tier ladder a creator picks
// from — so a bad value here cannot advertise a price different from the
// charge on a real purchase.
//
// OWNER ONLY for publish, checked HERE against platform_roles with a phone
// proven by JWT — the app's button decides nothing. Every value is clamped to
// a sane range, because a price is rendered straight into the UI.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

// A price point has to fit a real store: no negative, no runaway.
const MAX_CENTS = 100000; // $1000.00
const MAX_TIPS = 24;
const MAX_TIP_ID = 120;

function cents(v: unknown, fallback: number): number {
  const n = Math.round(Number(v));
  if (!Number.isFinite(n) || n < 0 || n > MAX_CENTS) return fallback;
  return n;
}

// Sanitizes the incoming price map into exactly the shape the app reads.
function cleanPrices(raw: unknown): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null) return {};
  const rec = raw as Record<string, unknown>;
  const out: Record<string, unknown> = {};

  if (rec.storagePerGbCents !== undefined) {
    // Per GB per month, in cents. 1..500 keeps it a storage price.
    const v = cents(rec.storagePerGbCents, 0);
    if (v > 0 && v <= 500) out.storagePerGbCents = v;
  }

  if (Array.isArray(rec.tierCents)) {
    // Exactly four levels, matching the four creatorsub/communitysub SKUs,
    // and increasing — a ladder that goes backwards is the App Store Connect
    // mistake this whole surface exists to keep out of the app.
    const t = rec.tierCents.slice(0, 4).map((v) => cents(v, 0));
    if (t.length === 4 && t.every((v) => v > 0)) {
      let rising = true;
      for (let i = 1; i < t.length; i++) if (t[i] <= t[i - 1]) rising = false;
      if (rising) out.tierCents = t;
    }
  }

  if (typeof rec.tipCents === "object" && rec.tipCents !== null) {
    const tips: Record<string, number> = {};
    let n = 0;
    for (const [k, v] of Object.entries(rec.tipCents as Record<string, unknown>)) {
      if (n++ >= MAX_TIPS) break;
      const id = String(k).slice(0, MAX_TIP_ID);
      const c = cents(v, 0);
      if (id && c > 0) tips[id] = c;
    }
    if (Object.keys(tips).length > 0) out.tipCents = tips;
  }

  return out;
}

async function roleOf(phone: string): Promise<string> {
  const { data } = await admin
    .from("platform_roles")
    .select("role")
    .eq("phone", phone)
    .maybeSingle();
  return (data?.role as string) ?? "member";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const what = String(body.what ?? "");

  if (what === "get") {
    const { data } = await admin
      .from("app_pricing")
      .select("prices")
      .eq("id", 1)
      .maybeSingle();
    return json({ prices: data?.prices ?? {} });
  }

  if (what !== "publish") return json({ error: "bad_request" }, 400);

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);
  if ((await roleOf(phone)) !== "owner") {
    return json({ error: "owner_only" }, 403);
  }

  const prices = cleanPrices(body.prices);
  const { error } = await admin.from("app_pricing").upsert({
    id: 1,
    prices,
    edited_at: new Date().toISOString(),
  });
  if (error) return json({ error: error.message }, 400);
  return json({ ok: true, prices });
});
