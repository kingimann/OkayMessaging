// What happened to one transfer.
//
// Capture no longer happens while the app is waiting: the card is authorised
// first, then judged (not prepaid, cardholder name matches the sender's ID),
// then captured or cancelled. The app polls this for a few seconds afterwards
// so the receipt in the chat settles instead of sitting on "Pending" forever.
//
// POST { paymentIntentId } -> { status }
//
// Only the sender may ask, and only about their own transfer.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let id = "";
  try {
    id = (await req.json()).paymentIntentId ?? "";
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!id) return json({ error: "missing id" }, 400);

  const { data } = await admin
    .from("payment_transactions")
    .select("status, from_phone")
    .eq("id", id)
    .maybeSingle();

  // Someone else's transfer is none of this caller's business.
  if (!data || data.from_phone !== phone) return json({ status: "unknown" });
  return json({ status: data.status ?? "unknown" });
});
