// Collects a rated Okay AI exchange as training data — the corpus a future
// fine-tune of "your own AI" is built from.
//
// POST { prompt, reply, rating } -> { ok }
//
// CONSENT IS THE CLIENT'S GATE. The app sends here ONLY when the user has
// opted in to "Help improve Okay AI" (AiConsent). By definition this is an
// assistant conversation — what the user typed to Okay AI and what it replied
// — never a human-to-human chat (those are end-to-end encrypted and never
// reach a server that can read them). The rating is the curation signal: a
// later fine-tune trains on the thumbs-up examples, filtered, so the model
// learns from good exchanges, not nonsense.
//
// Written ONLY here (service role) into ai_training_samples, which has no
// client grants. A coarse, salted submitter hash lets an abuser be rate-limited
// and a user's own samples be removed on request, without storing the phone.
//
// INERT WITHOUT THE TABLE. If ai_training.sql hasn't been run the insert fails
// and this returns { ok: false } — feedback is best-effort and never blocks.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const MAX_LEN = 8000;

async function submitterHash(phone: string): Promise<string> {
  if (!phone) return "";
  const salt = Deno.env.get("AI_FEEDBACK_SALT") ?? "okayai";
  const data = new TextEncoder().encode(`${salt}:${phone}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const prompt = String(body.prompt ?? "").trim().slice(0, MAX_LEN);
  const reply = String(body.reply ?? "").trim().slice(0, MAX_LEN);
  const rating = Number(body.rating ?? 0);
  if (!prompt || !reply || (rating !== 1 && rating !== -1)) {
    return json({ error: "invalid feedback" }, 400);
  }

  const me = (await callerPhone(req)) ?? "";
  const submitter = await submitterHash(me);

  try {
    await admin.from("ai_training_samples").insert({
      prompt,
      reply,
      rating,
      submitter,
    });
    return json({ ok: true });
  } catch (e) {
    console.error("ai-feedback: insert failed", String(e));
    return json({ ok: false });
  }
});
