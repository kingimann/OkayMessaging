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
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

export const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/// Resolves the caller's verified phone (E.164 digits) from their Supabase
/// session JWT. Payments require an authenticated, phone-verified user.
export async function callerPhone(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const token = auth.replace("Bearer ", "");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  const phone = data.user.phone ?? "";
  return phone ? phone.replace(/\D/g, "") : null;
}

/// The platform's application fee for an [amountCents] charge, in cents.
///
/// This MUST exceed what Stripe charges the platform, or every transfer loses
/// money. On a destination charge the platform is the merchant of record, so
/// Stripe's processing fee (2.9% + 30¢ on standard CAD/USD cards) comes out of
/// the platform's balance while only `application_fee_amount` comes back in.
///
/// The defaults below (3.4% + 35¢) clear that with a thin margin:
///   $10 transfer → fee 69¢ in, Stripe takes 59¢ → +10¢
///   $50 transfer → fee $2.05 in, Stripe takes $1.75 → +30¢
/// Override via PLATFORM_FEE_PERCENT / PLATFORM_FEE_FIXED_CENTS, but keep them
/// above Stripe's own rate for your region or the platform pays the difference.
export const STRIPE_PERCENT = 2.9;
export const STRIPE_FIXED_CENTS = 30;

export function applicationFee(amountCents: number): number {
  const pct = parseFloat(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "3.4");
  const fixed = parseInt(Deno.env.get("PLATFORM_FEE_FIXED_CENTS") ?? "35", 10);
  const fee = Math.round((amountCents * pct) / 100) + fixed;
  // Never let a misconfigured env var make the platform eat Stripe's cut.
  const stripeCost =
    Math.round((amountCents * STRIPE_PERCENT) / 100) + STRIPE_FIXED_CENTS;
  return Math.max(fee, stripeCost + 1);
}
