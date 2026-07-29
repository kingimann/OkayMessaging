// Applies and lifts app-wide sanctions. This is where a sanction becomes real.
//
// POST { targetPhone, action: 'ban' | 'suspend' | 'timeout' | 'lift',
//        reason?, minutes? }
//   -> { ok: true, sanction: {...} | null }
//
// Every authority check happens HERE, against platform_roles, using a phone
// proven by JWT. The app's own role checks only decide which buttons to draw;
// this decides what happens. The rules:
//
//   * moderators may time out; bans and suspensions need an admin
//   * you must strictly outrank your target — an admin cannot ban an admin,
//     and nobody can touch the owner
//   * nobody can sanction themselves (a footgun, not a feature)
//
// Bans are permanent (no `until`). Time-outs and suspensions require minutes.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const RANK: Record<string, number> = {
  owner: 3,
  admin: 2,
  moderator: 1,
  member: 0,
};

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

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const target = String(body.targetPhone ?? "").replace(/\D/g, "");
  const action = String(body.action ?? "");
  const reason = String(body.reason ?? "").slice(0, 500);
  const minutes = Number(body.minutes ?? 0);

  if (!target) return json({ error: "no_target" }, 400);
  if (target === phone) return json({ error: "cannot_sanction_self" }, 400);

  const actorRole = await roleOf(phone);
  if (RANK[actorRole] < RANK.moderator) {
    return json({ error: "forbidden" }, 403);
  }

  // Outranking is what stops a moderation team turning on itself.
  const targetRole = await roleOf(target);
  if (RANK[actorRole] <= RANK[targetRole]) {
    return json({ error: "outranked" }, 403);
  }

  if (action === "lift") {
    await admin.from("account_sanctions").delete().eq("phone", target);
    await admin.from("moderation_log").insert({
      actor_phone: phone,
      actor_role: actorRole,
      target_phone: target,
      action: "lift",
      reason,
    });
    return json({ ok: true, sanction: null });
  }

  if (action !== "ban" && action !== "suspend" && action !== "timeout") {
    return json({ error: "bad_action" }, 400);
  }

  // Only admins reach for the heavy tools.
  if (
    (action === "ban" || action === "suspend") &&
    RANK[actorRole] < RANK.admin
  ) {
    return json({ error: "needs_admin" }, 403);
  }

  // A ban is the only permanent sanction; the others are a stretch of time and
  // are meaningless without one.
  let until: string | null = null;
  if (action !== "ban") {
    if (!Number.isFinite(minutes) || minutes <= 0) {
      return json({ error: "no_duration" }, 400);
    }
    until = new Date(Date.now() + minutes * 60_000).toISOString();
  }

  const row = {
    phone: target,
    kind: action,
    reason,
    until,
    actor_phone: phone,
    updated_at: new Date().toISOString(),
  };
  const { error } = await admin
    .from("account_sanctions")
    .upsert(row, { onConflict: "phone" });
  if (error) return json({ error: error.message }, 400);

  await admin.from("moderation_log").insert({
    actor_phone: phone,
    actor_role: actorRole,
    target_phone: target,
    action,
    reason,
    until,
  });

  return json({
    ok: true,
    sanction: {
      kind: action,
      reason,
      until,
      actorPhone: phone,
      createdAt: new Date().toISOString(),
    },
  });
});
