// Starts a government-ID check for the blue check.
//
// The badge used to be a free toggle: tap "Verify me" and you were verified,
// which made it a decoration rather than a claim about who someone is. It now
// requires Stripe Identity — a real document check with a selfie match.
//
// POST {} -> { url, sessionId }  (open `url`, Stripe hosts the flow)
//
// Nothing about the document reaches this app. Stripe holds the images and
// the extracted fields; all we ever store is that a session for this phone
// reached "verified".

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { stripe } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  // Already verified? Don't start (or charge for) a second check.
  const { data: existing } = await admin
    .from("identity_verifications")
    .select("status")
    .eq("phone", phone)
    .maybeSingle();
  if (existing?.status === "verified") {
    return json({ alreadyVerified: true });
  }

  // Same rule as onboarding: Stripe's hosted flow needs an http(s) URL, and
  // a custom scheme is rejected as "Not a valid URL".
  const returnUrl = Deno.env.get("APP_RETURN_URL") ??
    "https://kingimann.github.io/OkayMessaging/";

  try {
    const session = await stripe.identity.verificationSessions.create({
      type: "document",
      options: {
        document: {
          // A selfie match is the difference between "this is a real ID" and
          // "this is the ID of the person holding the phone".
          require_matching_selfie: true,
          require_live_capture: true,
        },
      },
      return_url: returnUrl,
      metadata: { phone },
    });

    await admin.from("identity_verifications").upsert({
      phone,
      session_id: session.id,
      status: session.status,
      updated_at: new Date().toISOString(),
    });

    return json({ url: session.url, sessionId: session.id });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
