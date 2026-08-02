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

    // Does the stored account still exist *under this secret key*?
    //
    // A connected account belongs to one mode. If the row was written while
    // STRIPE_SECRET_KEY was a test key and it is now live (or the reverse),
    // the id is real but invisible: Stripe answers "No such account". The
    // Account Session then either fails to create or creates something the
    // publishable key cannot authenticate, and the only symptom anybody sees
    // is Stripe's "An error occurred while authenticating your account" —
    // which reads as a problem with the person's account.
    //
    // So check, and when the id belongs to the other mode, forget it and make
    // one that belongs to this one. Only on resource_missing: a network blip
    // must never discard somebody's real account.
    if (accountId) {
      try {
        await stripe.accounts.retrieve(accountId);
      } catch (e) {
        const err = e as { code?: string; statusCode?: number };
        if (err?.code === "resource_missing" || err?.statusCode === 404) {
          await admin.from("payment_accounts").delete().eq("phone", phone);
          accountId = undefined;
        } else {
          throw e;
        }
      }
    }

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

    let session;
    try {
      session = await stripe.accountSessions.create({
        account: accountId,
        components: {
          account_onboarding: { enabled: true },
          // Where a debit card gets attached. Card details must never reach
          // this platform's code or the app, so instant cash-out needs
          // Stripe's own component to collect the card — and the same
          // component is where somebody changes or removes it later.
          payouts: {
            enabled: true,
            features: {
              instant_payouts: true,
              standard_payouts: true,
              edit_payout_schedule: true,
              external_account_collection: true,
            },
          },
        },
      });
    } catch (e) {
      // Stripe's own words, plus the one setting that is usually missing.
      // "Could not start setup" with a raw Stripe message sent people looking
      // at their bank details; embedded components being switched off is a
      // platform setting and nothing about the account.
      const msg = String((e as Error).message ?? e);
      return json({
        error: "stripe_account_session_failed: " + msg +
          " — if this mentions components or embedded, switch on Connect " +
          "embedded components in the Stripe Dashboard (Connect → Settings).",
      }, 400);
    }

    // A session minted by a test secret key cannot be authenticated with a
    // live publishable key, or the other way round. Stripe's only symptom is
    // "An error occurred while authenticating your account", which reads like
    // a problem with the account rather than with the keys, so say it here —
    // where every version of the app shows the message, rather than only the
    // ones built after the client-side check was added.
    const pk = Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "";
    const serverMode = session.livemode ? "live" : "test";
    if (pk && pk.startsWith("pk_live_") !== session.livemode) {
      const key = pk.startsWith("pk_live_") ? "live" : "test";
      return json({
        error: `stripe_key_mode_mismatch: STRIPE_SECRET_KEY is a ${serverMode} ` +
          `key but STRIPE_PUBLISHABLE_KEY is a ${key} key. Both must match.`,
      }, 400);
    }
    // With no publishable key here, the app falls back to the one compiled
    // into the build and nothing can compare the two — which is the shape of
    // the failure this check exists to catch, so say what the mode is and let
    // the client finish the comparison. Not an error: a build carrying the
    // matching key works fine this way.
    const modeNote = pk
      ? undefined
      : `STRIPE_PUBLISHABLE_KEY is not set here, so the app is using the key ` +
        `it was built with. This server is in ${serverMode} mode; that key ` +
        `must be a pk_${serverMode}_ one.`;

    // Which Stripe account this secret key belongs to.
    //
    // Matching modes is not enough: two live keys from two different accounts
    // produce the same "an error occurred while authenticating your account",
    // because the session belongs to one platform and the publishable key to
    // another. The client can find out which account its own key belongs to,
    // so reporting this makes that comparison possible. Best-effort — a
    // failure here must not cost somebody their onboarding.
    let platformAccount = "";
    try {
      const self = await stripe.accounts.retrieve();
      platformAccount = self.id ?? "";
    } catch (_) {
      // Left empty; the client then says what to check rather than what is wrong.
    }

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
      // Which account the page is about to authenticate against, and a note
      // when this server cannot cross-check the key modes itself. Both are
      // here to be read in a failure, not used in the happy path.
      mode: serverMode,
      // The Stripe account the session belongs to. The app's publishable key
      // has to belong to this same account or nothing can authenticate.
      platformAccount,
      if_it_fails: modeNote,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
