// Screens a public newsfeed post before it goes up.
//
// POST { text, handle?, phone?, hasImage? }
//   -> { verdict: 'ok' | 'flag' | 'block', reason?, category?, configured }
//
// ENGINE: OpenRouter (chat completions), replacing the earlier OpenAI
// moderation endpoint at the owner's request. The model is asked to act as a
// strict classifier and answer with the SAME category/score shape the OpenAI
// moderation API used, so the shared verdict logic (_shared/moderation.ts,
// with its own executable test) is unchanged — the thresholds, the block
// wording, and the flag queue all work exactly as before. Unlike the
// moderation endpoint this is billed per token; MODEL is a cheap one on
// purpose, overridable with the OPENROUTER_MODEL secret.
//
// WHY THIS ONE IS ALLOWED TO LEAVE THE DEVICE AT ALL. Everything else people
// write in this app is end-to-end encrypted and must never reach a server that
// can read it. The public feed is the exception: those posts are
// world-readable by design — that is the entire point of the feed — so
// screening one discloses nothing that publishing it a second later will not.
// Do not copy this pattern to chats or server feeds.
//
// WHAT IT IS AND IS NOT. A speed bump and a queue-filler, not a security
// boundary: the client makes the call, so a modified client skips it entirely.
// Real enforcement stays where it was — people report, moderators sanction. A
// 'flag' verdict writes into the moderation_reports table the console already
// reads, so flagged posts land in the queue moderators already work, with no
// new table and no new screen.
//
// INERT WITHOUT A KEY. With no OPENROUTER_API_KEY set this returns
// { verdict: 'ok', configured: false } and posting works exactly as before. A
// missing key, a rate limit, or a bad gateway must never be the reason
// somebody cannot post.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import {
  classifierCategories,
  parseClassifier,
  verdictFor,
} from "../_shared/moderation.ts";

const DEFAULT_MODEL = "openai/gpt-4o-mini";

/// The classifier instruction. The category names come from the shared
/// module rather than being typed again, so the verdict logic and the
/// prompt can never disagree about what a category is called.
const INSTRUCTIONS = `You are a strict content-safety classifier for a ` +
  `public social feed. Classify the user's post against exactly these ` +
  `categories: ${classifierCategories.join(", ")}.\n` +
  `Answer ONLY with a JSON object of this shape and nothing else:\n` +
  `{"categories": {"<name>": true|false, ...}, ` +
  `"scores": {"<name>": 0.0-1.0, ...}}\n` +
  `Set a category true only when the post genuinely exhibits it; scores ` +
  `are your confidence. Ordinary rudeness, profanity, and strong opinions ` +
  `are all false across the board.`;

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

  const text = String(body.text ?? "").trim();
  const handle = String(body.handle ?? "");
  // Self-asserted when there is no session, which is the norm here — this app
  // runs with server-side OTP off. It is only used to attribute a flag, and a
  // flag is a request for a human to look, not a punishment.
  const phone = (await callerPhone(req)) ?? String(body.phone ?? "");

  const key = Deno.env.get("OPENROUTER_API_KEY") ?? "";
  if (!key) return json({ verdict: "ok", configured: false });

  // A post with no words is nothing to screen. An image-only post goes
  // through: this call reads text, and claiming to have checked a picture
  // would be a lie told to a moderator.
  if (!text) return json({ verdict: "ok", configured: true, skipped: true });

  let categories: Record<string, boolean> = {};
  let scores: Record<string, number> = {};
  try {
    const model = Deno.env.get("OPENROUTER_MODEL") || DEFAULT_MODEL;
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${key}`,
      },
      body: JSON.stringify({
        model,
        temperature: 0,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: INSTRUCTIONS },
          { role: "user", content: text },
        ],
      }),
    });
    if (!res.ok) {
      // Rate limited, a bad key, a bad day. Fail open — loudly in the logs and
      // silently to the person posting.
      console.error("moderation-screen: openrouter", res.status);
      return json({ verdict: "ok", configured: true, degraded: true });
    }
    const data = await res.json();
    const content = data.choices?.[0]?.message?.content ?? "";
    const parsed = parseClassifier(String(content));
    if (!parsed) {
      // A model that answered prose instead of JSON classified nothing.
      console.error("moderation-screen: unparseable classifier reply");
      return json({ verdict: "ok", configured: true, degraded: true });
    }
    categories = parsed.categories;
    scores = parsed.scores;
  } catch (e) {
    console.error("moderation-screen: failed", String(e));
    return json({ verdict: "ok", configured: true, degraded: true });
  }

  const { verdict, category, reason } = verdictFor(categories, scores);
  // Both a block and a flag go to a human. A block stopped somebody posting on
  // a machine's say-so, which is exactly the decision that deserves review.
  // The poster is told nothing about a flag — their post went up, and telling
  // somebody they are being watched is both unkind and a hint about how to
  // word it next time.
  if (verdict !== "ok") await record(phone, handle, text, verdict, category);
  return json({ verdict, category, reason, configured: true });
});

/// Puts a raised post in the queue moderators already work.
async function record(
  phone: string,
  handle: string,
  text: string,
  verdict: string,
  category: string,
): Promise<void> {
  await admin.from("moderation_reports").insert({
    target_phone: phone,
    target_handle: handle,
    reporter_phone: "", // nobody reported this; the screen raised it
    reason: `auto:${verdict}:${category}`,
    detail: text.slice(0, 1000),
    context: "post",
  });
}
