// What the caller is allowed to do app-wide, and what has been done to them.
//
// POST {} -> { role, sanction: { kind, reason, until, actorPhone, createdAt } | null }
//
// The role comes from platform_roles, a table no client can read — so the only
// way to learn your own role is to ask here, with a JWT that proves the phone
// is yours. A build that lies to itself about being an admin gets nothing: the
// action function checks the same table again before doing anything.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";

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

  const { data: sanctionRow } = await admin
    .from("account_sanctions")
    .select("kind, reason, until, actor_phone, created_at")
    .eq("phone", phone)
    .maybeSingle();

  // An expired sanction is history. Report it as gone rather than making every
  // client re-derive that from a timestamp.
  const expired = sanctionRow?.until != null &&
    new Date(sanctionRow.until as string).getTime() <= Date.now();

  return json({
    role: roleRow?.role ?? "member",
    sanction: !sanctionRow || expired ? null : {
      kind: sanctionRow.kind,
      reason: sanctionRow.reason ?? "",
      until: sanctionRow.until,
      actorPhone: sanctionRow.actor_phone ?? "",
      createdAt: sanctionRow.created_at,
    },
  });
});
