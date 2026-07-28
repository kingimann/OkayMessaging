// Shared Stripe + Supabase clients and helpers for the payment Edge Functions.
//
// Required Edge Function secrets (set with `supabase secrets set`):
//   STRIPE_SECRET_KEY        sk_live_... / sk_test_...
//   STRIPE_WEBHOOK_SECRET    whsec_...            (payments-webhook only)
//   PLATFORM_FEE_PERCENT     optional, defaults to 3.4 (your application_fee %)
//   PLATFORM_FEE_FIXED_CENTS optional, defaults to 35  (flat add-on)
//   APP_RETURN_URL           deep link back into the app after onboarding
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import Stripe from "https://esm.sh/stripe@16.12.0?target=deno";

// The generic request plumbing lives in http.ts; re-exported so existing
// imports from this file keep working unchanged.
export { admin, callerPhone, corsHeaders, json } from "./http.ts";

export const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

/// The platform's application fee for an [amountCents] charge, in cents.
///
/// Transfers are DIRECT charges — the PaymentIntent is created on the
/// recipient's connected account — so the platform is never in the flow of
/// funds and never pays Stripe's processing fee. That makes this fee pure
/// revenue, and means no floor is needed: unlike a destination charge, there
/// is no platform-side cost for it to fail to clear.
///
/// Stripe's cut (2.9% + 30c domestic, more on a foreign card) comes out of the
/// recipient's account instead, which is why the send sheet quotes an
/// approximate landing amount rather than the amount typed.
export function applicationFee(amountCents: number): number {
  const pct = parseFloat(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "3.4");
  const fixed = parseInt(Deno.env.get("PLATFORM_FEE_FIXED_CENTS") ?? "35", 10);
  return Math.max(0, Math.round((amountCents * pct) / 100) + fixed);
}
