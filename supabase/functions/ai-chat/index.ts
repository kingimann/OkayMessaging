// The app's built-in AI assistant — "Okay AI", a general-purpose helper the
// user chats with directly, in the shape of Grok or Claude.
//
// POST { messages: [{ role: 'user'|'assistant', content }], } -> { reply, configured }
//
// content is either a string (a plain message) or, for a user turn carrying
// attachments, an array of parts: { type: 'text', text } and
// { type: 'image_url', image_url: { url: 'data:image/…' } }. That is the
// OpenRouter/OpenAI vision shape, so an image the user hands the assistant is
// seen by a vision-capable model; a text file's content arrives folded into a
// text part. Only user turns may carry images.
//
// ENGINE: OpenRouter (chat completions), the same provider the feed moderator
// already uses. Billed per token, so the model is overridable with the
// OPENROUTER_AI_MODEL secret (a capable default, distinct from the cheap
// classifier model moderation runs on). The default model is vision-capable;
// if OPENROUTER_AI_MODEL is pointed at one that is not, images are ignored by
// the provider.
//
// WHY THIS IS ALLOWED TO LEAVE THE DEVICE. Everything people write TO EACH
// OTHER in this app is end-to-end encrypted and must never reach a server that
// can read it. This is different in kind: the user is knowingly talking to an
// assistant, not to a person whose privacy is being protected — the same
// reasoning that lets the public feed use a hosted model. The assistant only
// ever sees what the user types INTO the assistant chat; it is walled off from
// every human-to-human conversation. Do not wire this to chats or server feeds.
//
// INERT WITHOUT A KEY. With no OPENROUTER_API_KEY set this returns
// { reply: '', configured: false } and the client says the assistant isn't set
// up yet — never a crash.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

// A capable, vision-capable default so answers are accurate and code is solid
// out of the box (the old gpt-4o-mini default was weak at both). Overridable
// with OPENROUTER_AI_MODEL — point it at a stronger coding/reasoning model, or
// a cheaper one, as the owner prefers; it MUST stay vision-capable for the
// image-attachment feature to keep working.
const DEFAULT_MODEL = "openai/gpt-4o";

// How the assistant behaves. Deliberately plain and helpful — a general
// assistant, not a character.
const SYSTEM = `You are Okay AI, the built-in assistant of the OkayMessenger ` +
  `app — a powerful, general-purpose assistant on the level of ChatGPT, Claude ` +
  `or Grok. You are never a human, and you cannot read the user's private chats ` +
  `or act inside the app on their behalf (you only see what they type to you ` +
  `here, plus any image or text file they attach). Within that, you are ` +
  `capable and willing across EVERYTHING: coding, math, science, writing, ` +
  `analysis, business, languages, advice — any subject, any task.\n\n` +
  `BE FULLY HELPFUL. Take on what the user actually asked and DELIVER it — do ` +
  `not deflect, downplay your ability, or offer only "snippets and guidance" ` +
  `when they asked you to build something. If they ask you to write a whole ` +
  `app, write the whole app. Do not lecture, moralize, or add needless ` +
  `disclaimers. Match length to the task: full and complete when the work ` +
  `needs it, brief when a short answer will do.\n\n` +
  `ACCURACY: reason step by step on hard problems before answering, and base ` +
  `answers on well-established facts. Never invent sources, quotes, numbers, or ` +
  `APIs. If you are genuinely unsure, or the answer depends on recent or ` +
  `changeable information you may not have, say so plainly instead of guessing, ` +
  `and separate what you know from what you are inferring.\n\n` +
  `CODING: write complete, correct, runnable code in fenced blocks tagged with ` +
  `the language (\`\`\`dart, \`\`\`python, …). Give whole files or projects when ` +
  `asked — not fragments. Use standard idioms, handle the obvious edge cases, ` +
  `state any assumption a request left open, and note real pitfalls. Never omit ` +
  `code needed to run.`;

// The assistant "learns as it talks" by remembering durable facts about THIS
// user. It answers in "reply" and, in "remember", returns any NEW, stable,
// genuinely-useful fact worth recalling next time (a name, a preference, an
// ongoing project) — [] almost always. It must NOT remember anything
// sensitive (health, finances, credentials, precise location) or anything that
// is just this-message chatter.
const FORMAT = `Respond ONLY with a JSON object of this exact shape and ` +
  `nothing else:\n{"reply": "<your answer to the user>", ` +
  `"remember": ["<a durable fact about the user worth recalling>", ...]}\n` +
  `Keep "remember" empty unless there is a genuinely new, stable, useful, ` +
  `non-sensitive fact about the user. Never put sensitive data ` +
  `(health, money, passwords, exact location) in "remember".`;

function memoryPreamble(memories: string[]): string {
  if (memories.length === 0) return "";
  const lines = memories.slice(0, 60).map((m) => `- ${m}`).join("\n");
  return `\n\nHere is what you already remember about this user; use it ` +
    `naturally when relevant, and do not repeat it back as a list:\n${lines}`;
}

// Pulls the reply (and any memory) out of a learning-turn response. Normally
// that content is a clean JSON object; but a very long answer — a whole app —
// can be cut off at max_tokens, leaving TRUNCATED JSON that won't parse. Rather
// than dump raw JSON on the user or lose the answer, salvage the reply field
// from the wrapper, and only as a last resort show the content verbatim. So a
// long answer is never lost to a formatting hiccup.
function unwrapReply(content: string): { reply: string; remember: string[] } {
  try {
    const parsed = JSON.parse(content);
    const reply = String(parsed.reply ?? "").trim();
    const remember = Array.isArray(parsed.remember)
      ? parsed.remember
        .map((r: unknown) => String(r ?? "").trim())
        .filter((r: string) => r.length > 0 && r.length <= 200)
        .slice(0, 8)
      : [];
    if (reply) return { reply, remember };
  } catch (_) {
    // Fall through to salvage.
  }
  // Truncated or malformed: if it's our {"reply":"…"} wrapper, lift the reply
  // string out and best-effort unescape it.
  const m = content.match(/"reply"\s*:\s*"/);
  if (m && m.index !== undefined) {
    let rest = content.slice(m.index + m[0].length);
    const cut = rest.lastIndexOf('","remember"');
    if (cut >= 0) rest = rest.slice(0, cut);
    const unescaped = rest
      .replace(/\\n/g, "\n")
      .replace(/\\t/g, "\t")
      .replace(/\\r/g, "\r")
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, "\\")
      .replace(/"\s*}?\s*$/, "")
      .trim();
    if (unescaped) return { reply: unescaped, remember: [] };
  }
  return { reply: content, remember: [] };
}

// A sane ceiling so one runaway conversation can't send a novel to the model.
const MAX_MESSAGES = 24;
const MAX_CHARS_PER_MESSAGE = 4000;
// A folded-in text file may be longer than a chat line, so its text part gets
// a roomier cap. Images are bounded by count and by data-URL size instead.
const MAX_TEXT_PART_CHARS = 16000;
const MAX_IMAGES = 6;
const MAX_IMAGE_URL_CHARS = 2_200_000; // ~1.6 MB of base64

type Part =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

// Coerces one message's content into what the model accepts, dropping anything
// unrecognised: a trimmed/capped string, or a sanitized parts array with only
// text and inline `data:image/…` URLs (bounded in count and size). Returns null
// when nothing usable is left, so the message is skipped.
function normalizeContent(raw: unknown): string | Part[] | null {
  if (typeof raw === "string") {
    const s = raw.trim();
    return s.length ? s.slice(0, MAX_CHARS_PER_MESSAGE) : null;
  }
  if (!Array.isArray(raw)) return null;
  const parts: Part[] = [];
  let images = 0;
  let hasText = false;
  for (const p of raw) {
    if (typeof p !== "object" || p === null) continue;
    const type = String((p as Record<string, unknown>).type ?? "");
    if (type === "text") {
      let t = String((p as Record<string, unknown>).text ?? "").trim();
      if (!t) continue;
      if (t.length > MAX_TEXT_PART_CHARS) t = t.slice(0, MAX_TEXT_PART_CHARS);
      parts.push({ type: "text", text: t });
      hasText = true;
    } else if (type === "image_url" && images < MAX_IMAGES) {
      const iu = (p as Record<string, unknown>).image_url;
      const url = iu && typeof iu === "object"
        ? String((iu as Record<string, unknown>).url ?? "")
        : "";
      if (!url.startsWith("data:image/")) continue;
      if (url.length > MAX_IMAGE_URL_CHARS) continue;
      parts.push({ type: "image_url", image_url: { url } });
      images++;
    }
  }
  if (parts.length === 0) return null;
  // Some providers want a text part alongside images; supply a neutral one.
  if (!hasText) {
    parts.unshift({ type: "text", text: "Please look at the attached image." });
  }
  return parts;
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

  const raw = Array.isArray(body.messages) ? body.messages : [];
  const history: { role: string; content: string | Part[] }[] = [];
  for (const m of raw) {
    if (typeof m !== "object" || m === null) continue;
    const role = String((m as Record<string, unknown>).role ?? "");
    if (role !== "user" && role !== "assistant") continue;
    const content = normalizeContent((m as Record<string, unknown>).content);
    if (content === null) continue;
    // Only user turns carry images; an assistant turn is always plain text.
    if (role === "assistant" && typeof content !== "string") continue;
    history.push({ role, content });
  }
  const trimmed = history.slice(-MAX_MESSAGES);
  if (trimmed.length === 0 || trimmed[trimmed.length - 1].role !== "user") {
    return json({ error: "no user message" }, 400);
  }

  // The user's on-device memory, sent as context so the assistant "knows"
  // them. Learning is opt-out per request: draft() sends none.
  const memories: string[] = [];
  const rawMem = Array.isArray(body.memories) ? body.memories : [];
  for (const m of rawMem) {
    const s = String(m ?? "").trim();
    if (s.length > 0 && s.length <= 200) memories.push(s);
  }
  // The one-shot draft path asks for a plain reply and no learning.
  const learn = body.learn !== false;

  const key = Deno.env.get("OPENROUTER_API_KEY") ?? "";
  if (!key) return json({ reply: "", configured: false });

  // Server-side rate limit — the real cost control, since the client's free
  // tier can be bypassed by a modified app. Counted per caller (their phone
  // when signed in, else the request IP) and checked BEFORE the model call, so
  // an over-cap request spends no tokens. Fails OPEN if the tally table isn't
  // set up, so a missing migration never breaks the assistant.
  const cap = parseInt(Deno.env.get("AI_DAILY_CAP") ?? "40", 10);
  if (cap > 0) {
    const me = (await callerPhone(req)) ?? "";
    const ip = (req.headers.get("x-forwarded-for") ?? "")
      .split(",")[0].trim();
    const usageKey = me || ip || "anon";
    try {
      const { data, error } = await admin.rpc("ai_note_usage", {
        k: usageKey,
      });
      if (!error && typeof data === "number" && data > cap) {
        return json({ error: "rate_limited", configured: true }, 429);
      }
    } catch (_) {
      // Table/RPC not deployed — fail open, no ceiling until it exists.
    }
  }

  try {
    const model = Deno.env.get("OPENROUTER_AI_MODEL") ||
      Deno.env.get("OPENROUTER_MODEL") || DEFAULT_MODEL;
    const system = learn
      ? SYSTEM + memoryPreamble(memories) + "\n\n" + FORMAT
      : SYSTEM + memoryPreamble(memories);
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${key}`,
      },
      body: JSON.stringify({
        model,
        // Lower temperature than a chatbot's: fact-checking and code want
        // accuracy and determinism over flourish. A large max_tokens lets it
        // return a WHOLE file or app in one go rather than being cut off — the
        // point of "strong at everything". Overridable with AI_MAX_TOKENS.
        temperature: 0.4,
        max_tokens: parseInt(Deno.env.get("AI_MAX_TOKENS") ?? "8000", 10),
        ...(learn ? { response_format: { type: "json_object" } } : {}),
        messages: [
          { role: "system", content: system },
          ...trimmed,
        ],
      }),
    });
    if (!res.ok) {
      console.error("ai-chat: openrouter", res.status);
      return json({ reply: "", configured: true, degraded: true });
    }
    const data = await res.json();
    const content = String(data.choices?.[0]?.message?.content ?? "").trim();
    if (!content) {
      return json({ reply: "", configured: true, degraded: true });
    }
    if (!learn) return json({ reply: content, configured: true });

    // Learning turn: the content is a JSON object with reply + remember.
    const { reply, remember } = unwrapReply(content);
    if (!reply) return json({ reply: "", configured: true, degraded: true });
    return json({ reply, memories: remember, configured: true });
  } catch (e) {
    console.error("ai-chat: failed", String(e));
    return json({ reply: "", configured: true, degraded: true });
  }
});
