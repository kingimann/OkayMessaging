// Records a paid-server membership month after VERIFYING the store receipt.
//
// A server membership is a consumable In-App Purchase — one month of one paid
// server. The consumable carries no entitlement of its own (Apple doesn't know
// which server it was for), so the app tells us the server id and hands over
// the signed transaction (JWS) Apple gave it. We verify Apple's signature
// ourselves (the certificate chain rides inside the token, like iap-validate),
// refuse a product that isn't a community-sub tier, refuse a receipt we've
// already consumed, and only THEN extend the pass. The client never grants
// itself membership — this function, running as the service role, is the one
// writer of community_passes.
//
// The membership gates JOINING, not reading: a paid server's traffic is
// already E2E sealed under its own secret, so this records who has paid; it
// never sees or stores server content.
//
// POST { server, jws } -> { active, expiresAt }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { JwsError, verifyAppleJws } from "../_shared/apple_jws.ts";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";
const MONTH_MS = 30 * 24 * 3600 * 1000;
// com.okaymessaging.communitysub.tier0.monthly … tier3.monthly
const COMMUNITY_SUB = /\.communitysub\.tier[0-3]\.monthly$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const me = await callerPhone(req);
  if (!me) return json({ error: "unauthorized" }, 401);

  let server = "";
  let jws = "";
  try {
    const body = await req.json();
    server = String(body.server ?? "").trim();
    jws = String(body.jws ?? "");
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!server || !jws) return json({ error: "missing server or receipt" }, 400);

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
  if (!COMMUNITY_SUB.test(productId)) {
    return json({ error: "not a server membership" }, 400);
  }

  // Each consumable purchase has a unique transactionId. Dedup on it so one
  // receipt can't be replayed to buy membership of many servers.
  const txnId = String(payload.transactionId ?? "");
  if (!txnId) return json({ error: "incomplete receipt" }, 400);

  // Refuse a receipt we've already banked.
  const { data: seen } = await admin
    .from("community_sub_receipts")
    .select("txn_id")
    .eq("txn_id", txnId)
    .maybeSingle();
  if (seen) return json({ error: "receipt already used" }, 409);

  // Extend from whatever is left, so a renewal stacks rather than resets.
  const { data: existing } = await admin
    .from("community_passes")
    .select("expires_at")
    .eq("subscriber_phone", me)
    .eq("server_id", server)
    .maybeSingle();
  const now = Date.now();
  const curMs = existing?.expires_at
    ? Date.parse(existing.expires_at as string)
    : 0;
  const base = curMs > now ? curMs : now;
  const expiresAt = new Date(base + MONTH_MS).toISOString();

  await admin.from("community_passes").upsert({
    subscriber_phone: me,
    server_id: server,
    expires_at: expiresAt,
    product_id: productId,
    last_txn_id: txnId,
    updated_at: new Date(now).toISOString(),
  });
  await admin.from("community_sub_receipts").insert({ txn_id: txnId });

  return json({ active: true, expiresAt });
});
