// Request plumbing every Edge Function needs: the service-role Supabase
// client, CORS, JSON replies, and resolving the caller's verified phone.
//
// Split out of stripe.ts so the in-app-purchase functions can use it without
// dragging in Stripe. stripe.ts re-exports all of it, so nothing that imported
// from there had to change.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

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
/// session JWT. Everything that spends or grants money requires one.
export async function callerPhone(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const token = auth.replace("Bearer ", "");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  const phone = data.user.phone ?? "";
  return phone ? phone.replace(/\D/g, "") : null;
}
