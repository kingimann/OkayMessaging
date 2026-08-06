// Owner-editable legal documents — the owner's console for updating the Terms
// of Service and Privacy Policy from inside the app, without shipping a build.
//
// POST { what: 'get' }
//   -> { terms, privacy, version, lastUpdated }  (also served straight from the
//      table via anon SELECT; this verb exists for symmetry/debugging)
// POST { what: 'publish', terms, privacy, lastUpdated }
//   -> { ok: true, version }   OWNER ONLY.
//
// OWNER ONLY for publish, checked HERE against platform_roles with a phone
// proven by JWT — the app's button decides nothing. Publishing bumps `version`
// past both the previous value AND the build's built-in legalVersion, so every
// user is asked to agree again (the acceptance gate compares against it).
//
// Documents are stored as JSON arrays of { title, body } sections — the same
// shape the app renders. Bounded in size so a runaway paste can't be stored.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const MAX_SECTIONS = 60;
const MAX_TITLE = 200;
const MAX_BODY = 20000;
// Must stay >= the app's built-in legalVersion so a publish always re-prompts.
const MIN_VERSION = 6;

async function roleOf(phone: string): Promise<string> {
  const { data } = await admin
    .from("platform_roles")
    .select("role")
    .eq("phone", phone)
    .maybeSingle();
  return (data?.role as string) ?? "member";
}

// Sanitizes an incoming document into a bounded [{title, body}] array.
function cleanSections(raw: unknown): { title: string; body: string }[] {
  if (!Array.isArray(raw)) return [];
  const out: { title: string; body: string }[] = [];
  for (const s of raw.slice(0, MAX_SECTIONS)) {
    if (typeof s !== "object" || s === null) continue;
    const rec = s as Record<string, unknown>;
    const title = String(rec.title ?? "").slice(0, MAX_TITLE);
    const body = String(rec.body ?? "").slice(0, MAX_BODY);
    if (!title && !body) continue;
    out.push({ title, body });
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const what = String(body.what ?? "");

  if (what === "get") {
    const { data } = await admin
      .from("legal_documents")
      .select("terms, privacy, version, last_updated")
      .eq("id", 1)
      .maybeSingle();
    return json({
      terms: data?.terms ?? [],
      privacy: data?.privacy ?? [],
      version: data?.version ?? 0,
      lastUpdated: data?.last_updated ?? "",
    });
  }

  if (what !== "publish") return json({ error: "bad_request" }, 400);

  // Publishing is owner-only, proven by JWT.
  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);
  if ((await roleOf(phone)) !== "owner") {
    return json({ error: "owner_only" }, 403);
  }

  const terms = cleanSections(body.terms);
  const privacy = cleanSections(body.privacy);
  if (terms.length === 0 || privacy.length === 0) {
    return json({ error: "empty_documents" }, 400);
  }
  const lastUpdated = String(body.lastUpdated ?? "").slice(0, 120);

  // Next version: past the current stored value and past the floor, so it
  // always exceeds the build's built-in legalVersion and re-prompts everyone.
  const { data: cur } = await admin
    .from("legal_documents")
    .select("version")
    .eq("id", 1)
    .maybeSingle();
  const version = Math.max((cur?.version as number) ?? 0, MIN_VERSION - 1) + 1;

  const { error } = await admin.from("legal_documents").upsert({
    id: 1,
    terms,
    privacy,
    version,
    last_updated: lastUpdated,
    edited_at: new Date().toISOString(),
  });
  if (error) return json({ error: error.message }, 400);
  return json({ ok: true, version });
});
