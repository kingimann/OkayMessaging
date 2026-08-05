// Role management, from the app — the owner's console for building (and
// unbuilding) a moderation team without a SQL editor.
//
// POST { what: 'list' }
//   -> { roles: [{ phone, role, username?, name? }] }
// POST { what: 'set', targetPhone, role: 'admin' | 'moderator' | 'member' }
// POST { what: 'set', targetUsername, role }   — the same, addressed by
//   handle: resolved against the directory (case-insensitive, exact), and
//   an unknown handle answers 404 rather than silently granting nobody.
//   -> { ok: true }
//
// OWNER ONLY, both verbs, checked HERE against platform_roles with a phone
// proven by JWT — the app's buttons decide nothing. The rules:
//
//   * only the owner grants or revokes; 'member' means the row is deleted
//   * 'owner' can never be assigned: ownership moves by SQL, deliberately —
//     a tapped-by-mistake owner transfer is not a thing that can exist
//   * the owner cannot change their own row (locking yourself out is a
//     footgun, not a feature), and another owner's row is untouchable
//
// Every change lands in moderation_log, same as sanctions.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

async function roleOf(phone: string): Promise<string> {
  const { data } = await admin
    .from("platform_roles")
    .select("role")
    .eq("phone", phone)
    .maybeSingle();
  return (data?.role as string) ?? "member";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);
  if ((await roleOf(phone)) !== "owner") {
    return json({ error: "owner_only" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const what = String(body.what ?? "");

  if (what === "list") {
    const { data, error } = await admin
      .from("platform_roles")
      .select("phone, role");
    if (error) return json({ error: error.message }, 400);
    const rows = data ?? [];
    // Names ride along where the directory knows them, so the list reads
    // as people rather than digits.
    const phones = rows.map((r) => String(r.phone));
    const names: Record<string, { username?: string; name?: string }> = {};
    if (phones.length > 0) {
      const { data: dir } = await admin
        .from("usernames")
        .select("phone, username, name")
        .in("phone", phones);
      for (const d of dir ?? []) {
        names[String(d.phone)] = {
          username: (d.username as string) ?? "",
          name: (d.name as string) ?? "",
        };
      }
    }
    return json({
      roles: rows.map((r) => ({
        phone: r.phone,
        role: r.role,
        ...names[String(r.phone)],
      })),
    });
  }

  if (what !== "set") return json({ error: "bad_request" }, 400);

  let target = String(body.targetPhone ?? "").replace(/\D/g, "");
  const handle = String(body.targetUsername ?? "").trim().replace(/^@/, "");
  if (!target && handle) {
    // Case-insensitive EXACT match: ilike with its wildcards escaped,
    // because '_' is a legal username character and an ilike wildcard.
    const escaped = handle.replace(/[\\%_]/g, (c) => "\\" + c);
    const { data: hit } = await admin
      .from("usernames")
      .select("phone")
      .ilike("username", escaped)
      .maybeSingle();
    target = String(hit?.phone ?? "").replace(/\D/g, "");
    if (!target) return json({ error: "unknown_username" }, 404);
  }
  const role = String(body.role ?? "");
  if (!target) return json({ error: "no_target" }, 400);
  if (target === phone) return json({ error: "cannot_change_self" }, 400);
  if (role !== "admin" && role !== "moderator" && role !== "member") {
    return json({ error: "bad_role" }, 400);
  }
  if ((await roleOf(target)) === "owner") {
    return json({ error: "cannot_touch_owner" }, 403);
  }

  if (role === "member") {
    const { error } = await admin
      .from("platform_roles")
      .delete()
      .eq("phone", target);
    if (error) return json({ error: error.message }, 400);
  } else {
    const { error } = await admin
      .from("platform_roles")
      .upsert({ phone: target, role }, { onConflict: "phone" });
    if (error) return json({ error: error.message }, 400);
  }

  await admin.from("moderation_log").insert({
    actor_phone: phone,
    actor_role: "owner",
    target_phone: target,
    action: `role_${role}`,
  });

  return json({ ok: true });
});
