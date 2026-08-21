// Applies and lifts app-wide sanctions. This is where a sanction becomes real.
//
// POST { targetPhone, reason?, minutes?, area?,
//        action: 'ban' | 'suspend' | 'timeout' | 'shadow' | 'lift'
//              | 'area_ban' | 'area_lift' | 'takedown'
//              | 'verify' | 'unverify' }
//   -> { ok: true, sanction: {...} | null }
//      (or { ok: true, area }, or { ok: true, verified, name? })
//
// A SHADOW ban leaves the account working and hides its public content from
// everyone else (docs/moderation_scopes.sql). It never expires, because a
// shadow ban that lapses announces itself. An AREA ban takes away one part of
// the app — marketplace, servers, forum, feed — and leaves the rest, so a
// marketplace scammer keeps their conversations.
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

  const actorRole = await roleOf(phone);
  if (RANK[actorRole] < RANK.moderator) {
    return json({ error: "forbidden" }, 403);
  }

  // Takedown: removes ONE public post (the database cascades take its
  // replies, reposts and counters with it). Moderator and up, and the
  // author must be outranked — a moderator cannot silently erase what an
  // admin wrote. Logged like every other action.
  if (action === "takedown") {
    const postId = String(body.postId ?? "");
    if (!postId) return json({ error: "no_post" }, 400);
    const { data: post } = await admin
      .from("public_posts")
      .select("author_phone")
      .eq("id", postId)
      .maybeSingle();
    if (!post) return json({ ok: true, gone: true });
    const authorPhone = String(post.author_phone ?? "");
    if (authorPhone !== phone) {
      // Taking down your OWN post needs no rank games.
      const authorRole = await roleOf(authorPhone);
      if (RANK[actorRole] <= RANK[authorRole]) {
        return json({ error: "outranked" }, 403);
      }
    }
    const { error } = await admin
      .from("public_posts")
      .delete()
      .eq("id", postId);
    if (error) return json({ error: error.message }, 400);
    await admin.from("moderation_log").insert({
      actor_phone: phone,
      actor_role: actorRole,
      target_phone: authorPhone,
      action: "takedown",
      reason: reason || postId,
    });
    return json({ ok: true });
  }

  if (!target) return json({ error: "no_target" }, 400);

  // Staff-granted ID verification. ADMIN+ ONLY, and placed BEFORE the
  // outrank check on purpose: this is a grant, not a punishment, so there is
  // nothing to protect a peer from — an admin verifying another admin, or
  // the owner, costs nobody anything.
  //
  // WHY IT EXISTS. The blue check comes from a Stripe document check, and
  // some accounts cannot take one: an App Review tester will not photograph
  // a passport, and the wallet is closed to an unverified account. Before
  // this, the only way through was a hardcoded reviewer account in the
  // client — which is exactly the thing that shipped a build where every
  // purchase was silently faked, and was deleted for it.
  //
  // A NAME IS REQUIRED, and it is not bureaucracy: payments-create-intent
  // refuses an intent with no verified_name, so a pass recorded without one
  // leaves somebody verified and still unable to send money — which from
  // the outside is indistinguishable from not being verified at all.
  //
  // SELF IS ALLOWED, unlike every sanction below. The likeliest real use is
  // an owner setting up an account they are signed into, refusing it would
  // block that, and the honest guard is not a rule but the record: this is
  // admin+ only and every grant lands in the append-only, hash-chained
  // moderation_log with the actor named.
  if (action === "verify" || action === "unverify") {
    if (RANK[actorRole] < RANK.admin) {
      return json({ error: "needs_admin" }, 403);
    }
    if (action === "unverify") {
      await admin.from("identity_verifications").delete().eq("phone", target);
      await admin.from("moderation_log").insert({
        actor_phone: phone,
        actor_role: actorRole,
        target_phone: target,
        action: "unverify",
        reason,
      });
      return json({ ok: true, verified: false });
    }
    const name = String(body.name ?? "").trim().slice(0, 200);
    if (!name) return json({ error: "no_name" }, 400);
    // Marked as a STAFF grant rather than left looking like a Stripe pass.
    // identity-status only reaches for Stripe when a stored pass has no
    // name — which this always has — so the marker is never handed to
    // Stripe as a session id.
    const { error } = await admin.from("identity_verifications").upsert({
      phone: target,
      session_id: `staff:${phone}`,
      status: "verified",
      verified_name: name,
      updated_at: new Date().toISOString(),
    });
    if (error) return json({ error: error.message }, 400);
    await admin.from("moderation_log").insert({
      actor_phone: phone,
      actor_role: actorRole,
      target_phone: target,
      action: "verify",
      reason: reason || name,
    });
    return json({ ok: true, verified: true, name });
  }

  if (target === phone) return json({ error: "cannot_sanction_self" }, 400);

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

  // Area bans: barred from ONE part of the app, still a full user of the
  // rest. Admin+, like the other bans — losing the marketplace is a real
  // penalty even though conversations carry on.
  const AREAS = ["marketplace", "servers", "forum", "feed"];
  if (action === "area_ban" || action === "area_lift") {
    if (RANK[actorRole] < RANK.admin) {
      return json({ error: "needs_admin" }, 403);
    }
    const area = String(body.area ?? "");
    if (!AREAS.includes(area)) return json({ error: "bad_area" }, 400);

    if (action === "area_lift") {
      await admin.from("account_area_bans").delete().eq("phone", target)
        .eq("area", area);
    } else {
      // Indefinite unless a duration is given — the same rule as a ban.
      const until = Number.isFinite(minutes) && minutes > 0
        ? new Date(Date.now() + minutes * 60_000).toISOString()
        : null;
      const { error } = await admin.from("account_area_bans").upsert({
        phone: target,
        area,
        reason,
        until,
        actor_phone: phone,
      }, { onConflict: "phone,area" });
      if (error) return json({ error: error.message }, 400);
    }
    await admin.from("moderation_log").insert({
      actor_phone: phone,
      actor_role: actorRole,
      target_phone: target,
      action: `${action}:${area}`,
      reason,
    });
    return json({ ok: true, area });
  }

  if (
    action !== "ban" && action !== "suspend" && action !== "timeout" &&
    action !== "shadow"
  ) {
    return json({ error: "bad_action" }, 400);
  }

  // Only admins reach for the heavy tools. A shadow ban is among them: it is
  // quieter than a ban, not milder, and it is the one sanction the target is
  // never told about — so it should not be a moderator's to hand out.
  if (
    (action === "ban" || action === "suspend" || action === "shadow") &&
    RANK[actorRole] < RANK.admin
  ) {
    return json({ error: "needs_admin" }, 403);
  }

  // A ban is the only permanent sanction; the others are a stretch of time and
  // are meaningless without one. A shadow ban joins it: its whole value is
  // that it does not expire and announce itself by lapsing.
  let until: string | null = null;
  if (action !== "ban" && action !== "shadow") {
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
