// The moderator's working set: open reports, live sanctions, recent actions.
//
// POST { what?: 'reports' | 'sanctions' | 'log', limit? }
//   -> { reports: [...] } | { sanctions: [...] } | { log: [...] }
//
// Reports are not client-readable — one person's report is nobody else's
// business — so they come through here, gated on the caller's role. Sanctions
// are public (the directory rules already reveal who is hidden), but they are
// served here too so the console needs one call and one contract.
//
// POST { what: 'handle', id } marks a report dealt with.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

const RANK: Record<string, number> = {
  owner: 3,
  admin: 2,
  moderator: 1,
  member: 0,
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  const { data: roleRow } = await admin
    .from("platform_roles")
    .select("role")
    .eq("phone", phone)
    .maybeSingle();
  const role = (roleRow?.role as string) ?? "member";
  if (RANK[role] < RANK.moderator) return json({ error: "forbidden" }, 403);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // An empty body is fine — it means "the default view".
  }
  const what = String(body.what ?? "reports");
  const limit = Math.min(Number(body.limit ?? 50) || 50, 200);

  if (what === "handle") {
    const id = Number(body.id ?? 0);
    if (!id) return json({ error: "no_id" }, 400);
    await admin
      .from("moderation_reports")
      .update({ handled: true })
      .eq("id", id);
    return json({ ok: true });
  }

  if (what === "sanctions") {
    const { data } = await admin
      .from("account_sanctions")
      .select("phone, kind, reason, until, actor_phone, created_at")
      .order("created_at", { ascending: false })
      .limit(limit);
    return json({
      sanctions: (data ?? []).map((r) => ({
        phone: r.phone,
        kind: r.kind,
        reason: r.reason ?? "",
        until: r.until,
        actorPhone: r.actor_phone ?? "",
        createdAt: r.created_at,
      })),
    });
  }

  if (what === "log") {
    const { data } = await admin
      .from("moderation_log")
      .select(
        "id, created_at, actor_phone, actor_role, target_phone, action, reason, until",
      )
      .order("created_at", { ascending: false })
      .limit(limit);
    return json({ log: data ?? [] });
  }

  const { data } = await admin
    .from("moderation_reports")
    .select(
      "id, created_at, target_phone, target_handle, reporter_phone, reason, detail, context, handled",
    )
    .eq("handled", false)
    .order("created_at", { ascending: false })
    .limit(limit);
  return json({
    reports: (data ?? []).map((r) => ({
      id: r.id,
      createdAt: r.created_at,
      targetPhone: r.target_phone ?? "",
      targetHandle: r.target_handle ?? "",
      reporterPhone: r.reporter_phone ?? "",
      reason: r.reason ?? "",
      detail: r.detail ?? "",
      context: r.context ?? "",
    })),
  });
});
