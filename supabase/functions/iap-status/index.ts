// The caller's current storage entitlement, straight from what Apple's
// notifications have told us. The app calls this on launch and when the
// storage screen opens, so a renewal (or a cancellation, or a refund) shows
// up without the user having to buy anything again.
//
// POST {} -> { active, gb, expiresAt, productId }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { entitlementFor } from "../_shared/iap.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  return json(await entitlementFor(admin, phone));
});
