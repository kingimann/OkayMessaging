// The app's built-in AI assistant — "Okay AI", a general-purpose helper the
// user chats with directly, in the shape of Grok or Claude.
//
// POST { messages: [{ role: 'user'|'assistant', content }], } -> { reply, configured }
//
// ENGINE: OpenRouter (chat completions), the same provider the feed moderator
// already uses. Billed per token, so the model is overridable with the
// OPENROUTER_AI_MODEL secret (a capable default, distinct from the cheap
// classifier model moderation runs on).
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

import { corsHeaders, json } from "../_shared/http.ts";

const DEFAULT_MODEL = "openai/gpt-4o-mini";

// How the assistant behaves. Deliberately plain and helpful — a general
// assistant, not a character. Kept in step with AiAssistant.systemPrompt on the
// client so the two describe the same thing.
const SYSTEM = `You are Okay AI, the friendly built-in assistant of the ` +
  `OkayMessenger app. You are helpful, honest, and concise. Answer clearly, ` +
  `admit when you are unsure, and never claim to be a human. You cannot read ` +
  `the user's private chats or personal data — you only see what they type to ` +
  `you here. If asked to do something you cannot, say so plainly.`;

// A sane ceiling so one runaway conversation can't send a novel to the model.
const MAX_MESSAGES = 24;
const MAX_CHARS_PER_MESSAGE = 4000;

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
  const history: { role: string; content: string }[] = [];
  for (const m of raw) {
    if (typeof m !== "object" || m === null) continue;
    const role = String((m as Record<string, unknown>).role ?? "");
    let content = String((m as Record<string, unknown>).content ?? "").trim();
    if (content.length === 0) continue;
    if (role !== "user" && role !== "assistant") continue;
    if (content.length > MAX_CHARS_PER_MESSAGE) {
      content = content.slice(0, MAX_CHARS_PER_MESSAGE);
    }
    history.push({ role, content });
  }
  const trimmed = history.slice(-MAX_MESSAGES);
  if (trimmed.length === 0 || trimmed[trimmed.length - 1].role !== "user") {
    return json({ error: "no user message" }, 400);
  }

  const key = Deno.env.get("OPENROUTER_API_KEY") ?? "";
  if (!key) return json({ reply: "", configured: false });

  try {
    const model = Deno.env.get("OPENROUTER_AI_MODEL") ||
      Deno.env.get("OPENROUTER_MODEL") || DEFAULT_MODEL;
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${key}`,
      },
      body: JSON.stringify({
        model,
        temperature: 0.7,
        messages: [
          { role: "system", content: SYSTEM },
          ...trimmed,
        ],
      }),
    });
    if (!res.ok) {
      console.error("ai-chat: openrouter", res.status);
      return json({ reply: "", configured: true, degraded: true });
    }
    const data = await res.json();
    const reply = String(data.choices?.[0]?.message?.content ?? "").trim();
    if (!reply) {
      return json({ reply: "", configured: true, degraded: true });
    }
    return json({ reply, configured: true });
  } catch (e) {
    console.error("ai-chat: failed", String(e));
    return json({ reply: "", configured: true, degraded: true });
  }
});
