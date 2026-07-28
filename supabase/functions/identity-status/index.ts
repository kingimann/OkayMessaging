// Whether the caller has passed the ID check that earns the blue check.
//
// The app asks on launch and after returning from Stripe's hosted flow. The
// answer comes from the row the webhook maintains, never from the client — a
// badge the device could set for itself would be worth nothing.
//
// POST {} -> { verified, status }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  const { data } = await admin
    .from("identity_verifications")
    .select("status")
    .eq("phone", phone)
    .maybeSingle();

  const status = data?.status ?? "none";
  return json({ verified: status === "verified", status });
});
