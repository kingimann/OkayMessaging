// An Account Session for Stripe's Connect embedded components.
//
// This is what lets onboarding happen INSIDE the app rather than throwing the
// user out to a hosted Stripe page. The client secret returned here is handed
// to <stripe-connect-account-onboarding>, which renders Stripe's own forms —
// so Stripe still collects the identity and banking details directly and they
// never pass through this app.
//
// POST {} -> { clientSecret, accountId, publishableKey }
//
// Creates the connected account on first call, exactly like payments-onboard,
// so a member can go straight into the embedded flow with no round trip.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { stripe } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  try {
    const { data: existing } = await admin
      .from("payment_accounts")
      .select("stripe_account_id")
      .eq("phone", phone)
      .maybeSingle();

    let accountId = existing?.stripe_account_id as string | undefined;
    if (!accountId) {
      const account = await stripe.accounts.create({
        type: "express",
        country: Deno.env.get("CONNECT_COUNTRY") ?? "CA",
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
        business_type: "individual",
        metadata: { phone },
      });
      accountId = account.id;
      await admin.from("payment_accounts").upsert({
        phone,
        stripe_account_id: accountId,
        updated_at: new Date().toISOString(),
      });
    }

    const session = await stripe.accountSessions.create({
      account: accountId,
      components: {
        account_onboarding: { enabled: true },
      },
    });

    return json({
      clientSecret: session.client_secret,
      accountId,
      // Client-safe by design, and the embedded component needs it to
      // initialise. Sent from here so the page has one source of truth.
      publishableKey: Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "",
      // Which mode STRIPE_SECRET_KEY is in. A session minted by a test key
      // cannot be authenticated with a live publishable key (or the other way
      // round) and Stripe's only symptom is "an error occurred while
      // authenticating your account" — so the client compares the two and
      // says which half is wrong.
      livemode: session.livemode,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
