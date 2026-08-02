// Creates (or reuses) a Stripe Express connected account for the caller and
// returns a Stripe-hosted onboarding link (account_link) for KYC. This is the
// only hosted step — Stripe requires it for Express identity verification. The
// actual sending of money is fully native (see payments-create-intent).
//
// POST  ->  { url, accountId, chargesEnabled, payoutsEnabled, detailsSubmitted }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  try {
    // Reuse an existing account, or create a new Canadian Express account.
    const { data: existing } = await admin
      .from("payment_accounts")
      .select("stripe_account_id")
      .eq("phone", phone)
      .maybeSingle();

    let accountId = existing?.stripe_account_id as string | undefined;
    if (!accountId) {
      const account = await stripe.accounts.create({
        type: "express",
        // The connected account's country decides which bank details Stripe
        // asks for, so it has to match where the receiver actually banks.
        // Everyone onboards in the platform's country today; supporting
        // receivers elsewhere means asking them and passing it in here.
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

    // Stripe's hosted onboarding requires an http(s) URL and rejects custom
    // schemes outright — "okaymsg://payments/return" comes back as
    // "Not a valid URL", which is a 400 the user sees as "could not start
    // setup". So it has to be somewhere a browser can go.
    //
    // The `pages` function on this same project, by default: SUPABASE_URL is
    // injected automatically, so this matches what the client watches for
    // without either side being configured. It used to be a GitHub Pages
    // site — a second system, with its own outages, for a page that is
    // cancelled before it renders anyway.
    const returnUrl = Deno.env.get("APP_RETURN_URL") ??
      `${Deno.env.get("SUPABASE_URL") ?? ""}/functions/v1/pages/done`;
    const link = await stripe.accountLinks.create({
      account: accountId,
      refresh_url: returnUrl,
      return_url: returnUrl,
      type: "account_onboarding",
    });

    const account = await stripe.accounts.retrieve(accountId);
    await admin.from("payment_accounts").update({
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      updated_at: new Date().toISOString(),
    }).eq("phone", phone);

    return json({
      url: link.url,
      accountId,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
    });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
