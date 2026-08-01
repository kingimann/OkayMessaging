// supabase: verify_jwt = false
//
// APPLE SENDS NO AUTHORIZATION HEADER either — same failure as
// payments-webhook, and quieter: a dropped renewal notice is a subscription
// that bills and stops working, with nothing on fire to notice.
//
// App Store Server Notifications V2 — Apple POSTs here whenever a
// subscription renews, lapses, is cancelled, or gets refunded.
//
// This is the half that makes an auto-renewable subscription honest: without
// it a renewal charge would never reach the entitlement, and month two would
// bill the customer while their storage quietly stopped working.
//
// Apple authenticates with its own signature, not a Supabase login, so
// "Enforce JWT verification" must be OFF on this function (same as
// payments-webhook).
//
// Set the URL in App Store Connect -> App -> App Information ->
// App Store Server Notifications (both Production and Sandbox).

import { admin, corsHeaders } from "../_shared/http.ts";
import { JwsError, verifyAppleJws } from "../_shared/apple_jws.ts";
import { gbForProduct, statusForNotification } from "../_shared/iap.ts";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  let signedPayload = "";
  try {
    signedPayload = (await req.json()).signedPayload ?? "";
  } catch {
    return new Response("invalid body", { status: 400 });
  }
  if (!signedPayload) return new Response("missing signedPayload", { status: 400 });

  let note: Record<string, unknown>;
  try {
    note = await verifyAppleJws(signedPayload);
  } catch (e) {
    if (e instanceof JwsError) {
      return new Response(`bad signature: ${e.message}`, { status: 400 });
    }
    throw e;
  }

  const data = (note.data ?? {}) as Record<string, unknown>;
  if (data.bundleId && data.bundleId !== BUNDLE_ID) {
    return new Response("wrong app", { status: 400 });
  }

  // The interesting fields are themselves signed blobs.
  let tx: Record<string, unknown> = {};
  let renewal: Record<string, unknown> = {};
  try {
    if (data.signedTransactionInfo) {
      tx = await verifyAppleJws(String(data.signedTransactionInfo));
    }
    if (data.signedRenewalInfo) {
      renewal = await verifyAppleJws(String(data.signedRenewalInfo));
    }
  } catch (e) {
    if (e instanceof JwsError) {
      return new Response(`bad inner signature: ${e.message}`, { status: 400 });
    }
    throw e;
  }

  const originalTransactionId = String(tx.originalTransactionId ?? "");
  if (!originalTransactionId) {
    // Nothing to attach this to. 200 so Apple stops retrying — replaying it
    // wouldn't help.
    return new Response(JSON.stringify({ received: true, applied: false }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const status = statusForNotification(
    String(note.notificationType ?? ""),
    String(note.subtype ?? ""),
  );

  // The row is created when the app validates the first purchase — that is
  // the only moment we learn which account owns it. A notification for an
  // unknown transaction is one we can't attribute, so it's left alone.
  const { data: existing } = await admin
    .from("subscriptions")
    .select("phone")
    .eq("original_transaction_id", originalTransactionId)
    .maybeSingle();
  if (!existing) {
    return new Response(JSON.stringify({ received: true, applied: false }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Billing-retry grace extends real access, so it extends the expiry that
  // governs it — one rule decides entitlement everywhere.
  const graceMs = Number(renewal.gracePeriodExpiresDate ?? 0);
  const expiresMs = Number(tx.expiresDate ?? 0);
  const effective = Math.max(graceMs, expiresMs);

  const update: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if (status) update.status = status;
  if (effective) update.expires_at = new Date(effective).toISOString();
  if (tx.productId) {
    update.product_id = String(tx.productId);
    update.gb = gbForProduct(String(tx.productId));
  }
  // A refund or revoke ends access immediately, whatever the dates say.
  if (status === "refunded") update.expires_at = new Date().toISOString();

  await admin
    .from("subscriptions")
    .update(update)
    .eq("original_transaction_id", originalTransactionId);

  return new Response(JSON.stringify({ received: true, applied: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
