// Screens a public newsfeed post before it goes up.
//
// POST { text, handle?, phone?, hasImage? }
//   -> { verdict: 'ok' | 'flag' | 'block', reason?, category?, configured }
//
// WHY THIS ONE IS ALLOWED TO BE A CLOUD CALL. Everything else people write in
// this app is end-to-end encrypted and must never reach a server that can read
// it. The public feed is the exception: those posts are world-readable by
// design — that is the entire point of the feed — so sending one to a model
// discloses nothing that publishing it will not disclose a second later. Do
// not copy this pattern to chats or server feeds.
//
// WHAT IT IS AND IS NOT. It is a speed bump and a queue-filler, not a security
// boundary: the client calls it, so a modified client can skip it entirely.
// Real enforcement stays where it was — humans report, moderators sanction. A
// 'flag' verdict writes into the moderation_reports table the console already
// reads, so flagged posts land in the queue moderators already work, with no
// new table and no new screen.
//
// INERT WITHOUT A KEY. With no ANTHROPIC_API_KEY set this returns
// { verdict: 'ok', configured: false } and posting works exactly as before. A
// missing key, a rate limit, or a bad gateway must never be the reason
// somebody cannot post.
//
// COST. claude-haiku-4-5 at $1/$5 per million tokens; a post plus this policy
// is roughly 300 in and 20 out, so about $0.0003 a post — around 3,000 posts
// per dollar. There is deliberately no prompt-caching breakpoint: Haiku's
// minimum cacheable prefix is 4,096 tokens and this policy is far shorter, so
// a cache_control marker here would cost the write premium and never be read.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const MODEL = "claude-haiku-4-5";

/// The shape the model must answer in. Structured outputs constrain decoding,
/// so this cannot come back as prose that needs parsing or repairing.
const SCHEMA = {
  type: "object",
  properties: {
    verdict: {
      type: "string",
      enum: ["ok", "flag", "block"],
      description:
        "block only for content that is clearly and seriously against the " +
        "rules; flag when a human should look; ok for everything else.",
    },
    category: {
      type: "string",
      enum: [
        "none",
        "harassment",
        "violence",
        "sexual",
        "self_harm",
        "illegal",
        "spam",
      ],
    },
    reason: {
      type: "string",
      description:
        "One short sentence a person would understand, addressed to the " +
        "poster. Empty when the verdict is ok.",
    },
  },
  required: ["verdict", "category", "reason"],
  additionalProperties: false,
};

const POLICY = `You screen posts for a public timeline in a messaging app. \
Anyone using the app can see this timeline.

Answer with a verdict:
- "block" ONLY for content that is clearly and seriously against the rules: \
threats of violence, sexual content involving minors, targeted harassment of a \
named person, doxxing, or the sale of something plainly illegal.
- "flag" when a person should take a look but you would not stop it going up: \
plausible spam, unclear context, an insult that might be banter between \
friends.
- "ok" for everything else, which is almost everything.

Rudeness is not blockable. Strong opinions, swearing, arguing, and criticism \
of public figures, companies, and this app are all "ok". A joke that reads \
badly out of context is at most "flag".

You are seeing one post with no conversation around it and no knowledge of who \
wrote it. When you are unsure, that uncertainty is itself the reason to prefer \
"flag" over "block" — a wrong block silences somebody, and a wrong flag only \
costs a moderator a glance.`;

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
  const hasImage = body.hasImage === true;
  // Self-asserted when there is no session, which is the norm here — this app
  // runs with server-side OTP off. It is only used to attribute a flag, and a
  // flag is a request for a human to look, not a punishment.
  const phone = (await callerPhone(req)) ?? String(body.phone ?? "");

  const key = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  if (!key) return json({ verdict: "ok", configured: false });

  // A post with no words is nothing to screen. An image-only post goes
  // through: this model reads text, and claiming to have checked a picture
  // would be a lie told to a moderator.
  if (!text) return json({ verdict: "ok", configured: true, skipped: true });

  let parsed: { verdict: string; category: string; reason: string };
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 200,
        system: POLICY,
        output_config: { format: { type: "json_schema", schema: SCHEMA } },
        messages: [{
          role: "user",
          content: `Post to screen${hasImage ? " (it also carries an image)" : ""}:\n\n${text}`,
        }],
      }),
    });
    if (!res.ok) {
      // Rate limited, overloaded, a bad key. Fail open, loudly in the logs and
      // silently to the person posting.
      console.error("moderation-screen: anthropic", res.status);
      return json({ verdict: "ok", configured: true, degraded: true });
    }
    const data = await res.json();
    // A refusal comes back as a 200 with no usable content; treat it as "a
    // human should look" rather than as a block or a pass.
    if (data.stop_reason === "refusal") {
      parsed = { verdict: "flag", category: "none", reason: "" };
    } else {
      const block = (data.content ?? []).find((b: { type: string }) =>
        b.type === "text"
      );
      parsed = JSON.parse(block?.text ?? "{}");
    }
  } catch (e) {
    console.error("moderation-screen: failed", String(e));
    return json({ verdict: "ok", configured: true, degraded: true });
  }

  const verdict = ["ok", "flag", "block"].includes(parsed.verdict)
    ? parsed.verdict
    : "ok";
  const category = String(parsed.category ?? "none");
  const reason = String(parsed.reason ?? "").slice(0, 300);

  // Both a block and a flag go to a human. A block stopped somebody posting on
  // a machine's say-so, which is exactly the decision that deserves review.
  if (verdict !== "ok") {
    await admin.from("moderation_reports").insert({
      target_phone: phone,
      target_handle: handle,
      reporter_phone: "", // nobody reported this; the screen raised it
      reason: `auto:${verdict}:${category}`,
      detail: text.slice(0, 1000),
      context: "post",
    });
  }

  return json({ verdict, category, reason, configured: true });
});
