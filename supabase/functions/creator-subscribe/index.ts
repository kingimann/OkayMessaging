// Records a creator-subscription month after VERIFYING the store receipt.
//
// A creator subscription is a consumable In-App Purchase — one month of one
// creator's paid feed. The consumable itself carries no entitlement (Apple
// doesn't know which creator it was for), so the app tells us the creator and
// hands over the signed transaction (JWS) Apple gave it. We verify Apple's
// signature ourselves (the certificate chain rides inside the token, like
// iap-validate), refuse a product that isn't a creator-sub tier, refuse a
// receipt we've already consumed, and only THEN extend the pass. The client is
// never trusted to grant itself a paid body — this function, running as the
// service role, is the one writer of creator_subscriptions.
//
// POST { creator, jws } -> { active, expiresAt }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { JwsError, verifyAppleJws } from "../_shared/apple_jws.ts";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";
const MONTH_MS = 30 * 24 * 3600 * 1000;
// com.okaymessaging.creatorsub.tier0.monthly … tier3.monthly
const CREATOR_SUB = /\.creatorsub\.tier[0-3]\.monthly$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const me = await callerPhone(req);
  if (!me) return json({ error: "unauthorized" }, 401);

  let creator = "";
  let jws = "";
  try {
    const body = await req.json();
    creator = String(body.creator ?? "").trim();
    jws = String(body.jws ?? "");
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!creator || !jws) return json({ error: "missing creator or receipt" }, 400);

  let payload: Record<string, unknown>;
  try {
    payload = await verifyAppleJws(jws);
  } catch (e) {
    // A token that doesn't verify is the whole threat model. Say no, and
    // don't leak which check failed.
    if (e instanceof JwsError) return json({ error: "invalid receipt" }, 400);
    throw e;
  }

  if (payload.bundleId !== BUNDLE_ID) return json({ error: "wrong app" }, 400);

  const productId = String(payload.productId ?? "");
  if (!CREATOR_SUB.test(productId)) {
    return json({ error: "not a creator subscription" }, 400);
  }

  // Each consumable purchase has a unique transactionId. Dedup on it so one
  // receipt can't be replayed to buy a month of many creators.
  const txnId = String(payload.transactionId ?? "");
  if (!txnId) return json({ error: "incomplete receipt" }, 400);

  // Resolve the creator's handle to a phone (the row is keyed by phone, so a
  // later handle change never orphans the pass). The service role reads the
  // directory; the phone never leaves this function.
  const { data: dir } = await admin
    .from("usernames")
    .select("phone")
    .ilike("username", creator)
    .maybeSingle();
  const creatorPhone = dir?.phone as string | undefined;
  if (!creatorPhone) return json({ error: "unknown creator" }, 404);
  if (creatorPhone === me) return json({ error: "cannot subscribe to self" }, 400);

  // Refuse a receipt we've already banked.
  const { data: seen } = await admin
    .from("creator_sub_receipts")
    .select("txn_id")
    .eq("txn_id", txnId)
    .maybeSingle();
  if (seen) return json({ error: "receipt already used" }, 409);

  // Extend from whatever is left, so a renewal stacks rather than resets.
  const { data: existing } = await admin
    .from("creator_subscriptions")
    .select("expires_at")
    .eq("subscriber_phone", me)
    .eq("creator_phone", creatorPhone)
    .maybeSingle();
  const now = Date.now();
  const curMs = existing?.expires_at
    ? Date.parse(existing.expires_at as string)
    : 0;
  const base = curMs > now ? curMs : now;
  const expiresAt = new Date(base + MONTH_MS).toISOString();

  await admin.from("creator_subscriptions").upsert({
    subscriber_phone: me,
    creator_phone: creatorPhone,
    expires_at: expiresAt,
    product_id: productId,
    last_txn_id: txnId,
    updated_at: new Date(now).toISOString(),
  });
  await admin.from("creator_sub_receipts").insert({ txn_id: txnId });

  return json({ active: true, expiresAt });
});
