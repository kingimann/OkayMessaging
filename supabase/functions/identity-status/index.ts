// Whether the caller has passed the ID check that earns the blue check.
//
// IT ASKS STRIPE, not only our own table. The table is maintained by
// payments-webhook, and a webhook is best-effort by nature: it can be
// rejected at the door, mis-configured, or retried into an endpoint that
// never answers. When that happens the old version of this function reported
// "not verified" forever about somebody Stripe had already verified — and the
// app read that as the badge being taken away. A webhook is an optimisation;
// the authoritative answer lives at Stripe, so on anything short of a
// recorded pass, go and get it.
//
// A stored pass still wins: that is the cheap path and the common one, and it
// keeps this off Stripe's rate limit on every launch.
//
// POST {} -> { verified, status, name? }

import { admin, callerPhone, corsHeaders, json, stripe } from "../_shared/stripe.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  const { data } = await admin
    .from("identity_verifications")
    .select("status, session_id, verified_name")
    .eq("phone", phone)
    .maybeSingle();

  const stored = (data?.status as string | undefined) ?? "none";
  const sessionId = data?.session_id as string | undefined;
  const storedName = data?.verified_name as string | undefined;

  // Already recorded as a pass, WITH the name payments need. Nothing to ask.
  if (stored === "verified" && storedName) {
    return json({ verified: true, status: stored, name: storedName });
  }

  // Never started one — there is nothing at Stripe to ask about.
  if (!sessionId) {
    return json({ verified: stored === "verified", status: stored });
  }

  try {
    // verified_outputs must be asked for explicitly, and it carries the legal
    // name off the document — the only thing a cardholder name can honestly
    // be checked against. Without it payments-create-intent refuses, so a
    // pass recorded without a name leaves somebody verified and still unable
    // to send money, which from the outside looks exactly like not being
    // verified at all.
    const session = await stripe.identity.verificationSessions.retrieve(
      sessionId,
      { expand: ["verified_outputs"] },
    );
    const live = (session as { status?: string }).status ?? stored;
    const name =
      (session as { verified_outputs?: { name?: string } }).verified_outputs
        ?.name ?? storedName ?? null;

    if (live !== stored || (name && name !== storedName)) {
      await admin.from("identity_verifications").upsert({
        phone,
        session_id: sessionId,
        status: live,
        ...(name ? { verified_name: name } : {}),
        updated_at: new Date().toISOString(),
      });
      // The public half of the badge, exactly as the webhook grants it. Doing
      // it here too means a dropped webhook costs nobody their blue check.
      // Best-effort: the column exists only after
      // docs/identity_directory_badge.sql has run, and a cosmetic write must
      // not fail the answer.
      if (live === "verified" || live === "canceled") {
        try {
          await admin
            .from("usernames")
            .update({ verified: live === "verified" })
            .eq("phone", phone);
        } catch (_) {
          // Directory not migrated yet: the badge stays client-side.
        }
      }
    }

    return json({
      verified: live === "verified",
      status: live,
      ...(name ? { name } : {}),
    });
  } catch (_) {
    // Stripe unreachable, or a session that no longer exists. Fall back to
    // what is stored rather than reporting a downgrade nobody asked for: an
    // outage must never read as the badge being withdrawn.
    return json({ verified: stored === "verified", status: stored });
  }
});
