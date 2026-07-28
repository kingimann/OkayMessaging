// Validates a StoreKit 2 purchase and records the entitlement it grants.
//
// The app forwards the signed transaction (JWS) Apple handed it after a
// purchase or a restore. We verify Apple's signature ourselves — the
// certificate chain rides along inside the token — so no App Store Connect API
// key is needed and nothing here calls out to Apple.
//
// POST { jws } -> { active, gb, expiresAt, productId }
//
// The client is never trusted for entitlement. It may only hand over a token
// Apple signed, and what that token says is what gets stored.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { JwsError, verifyAppleJws } from "../_shared/apple_jws.ts";
import {
  entitlementFor,
  gbForProduct,
  upsertSubscription,
} from "../_shared/iap.ts";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let jws = "";
  try {
    jws = (await req.json()).jws ?? "";
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!jws) return json({ error: "missing jws" }, 400);

  let payload: Record<string, unknown>;
  try {
    payload = await verifyAppleJws(jws);
  } catch (e) {
    // A token that doesn't verify is the entire threat model. Say no, and
    // don't leak which check failed.
    if (e instanceof JwsError) return json({ error: "invalid receipt" }, 400);
    throw e;
  }

  if (payload.bundleId !== BUNDLE_ID) return json({ error: "wrong app" }, 400);

  const productId = String(payload.productId ?? "");
  const originalTransactionId = String(payload.originalTransactionId ?? "");
  if (!productId || !originalTransactionId) {
    return json({ error: "incomplete receipt" }, 400);
  }

  // Consumables (the tips) carry no entitlement. They still get verified so a
  // forged "thanks for tipping" can't be faked, but nothing is stored.
  const gb = gbForProduct(productId);
  if (gb === 0) {
    return json({ active: false, gb: 0, expiresAt: null, productId });
  }

  const expiresMs = Number(payload.expiresDate ?? 0);
  await upsertSubscription(admin, {
    originalTransactionId,
    phone,
    productId,
    gb,
    expiresAt: expiresMs ? new Date(expiresMs).toISOString() : null,
    status: payload.revocationDate != null ? "refunded" : "active",
    environment: String(payload.environment ?? "Production"),
  });

  return json(await entitlementFor(admin, phone));
});
