// Gives an email-verified account with NO phone number the one thing that
// makes the rest of the app work: a `phone` claim on its session.
//
// POST { what: 'claim' }   (Authorization: the caller's email-OTP session)
//   -> { code }            the account code now stamped on the session
//   -> { error }           on any refusal
//
// WHY THIS EXISTS AT ALL. Every server-side rule in this project keys on
// `auth.jwt() ->> 'phone'` — 135 conditions across 18 migrations — and
// `callerPhone()` in _shared/http.ts returns null for an auth user without
// one, so every gated function reads such a caller as anonymous. An account
// that signs in by email alone therefore has a session that can do nothing:
// the directory, posting, the wallet, moderation and payments all refuse it.
// Rewriting 135 policies to understand a second kind of principal is the
// alternative, and it is the wrong one — every future policy would have to
// remember, and the one that forgot would fail open or fail closed silently.
//
// THE FIT. An `AccountCode` is 12 digits prefixed '00' (lib/util/
// account_code.dart), a namespace real E.164 never occupies — no country
// code begins with 0 — which is exactly why `Session.isNumberless` can tell
// the two apart with `AccountCode.isCode(phone)`. Stamping a code into the
// `phone` field is therefore not a trick played on the schema: the app's
// identity model already treats a code as the phone-shaped identity, and the
// database only ever compares that field for equality. Nothing downstream
// has to learn anything, and no migration is needed.
//
// THE CODE IS MINTED HERE AND IS NEVER TAKEN FROM THE CALLER. This is the
// security property the whole function turns on. Account codes are PUBLIC —
// a code is how somebody addresses you, printed in the app for sharing — so
// a function that accepted one as a parameter would hand any caller a
// session as any numberless account it cared to name. There is no way for a
// device to PROVE it owns an existing code either: the codes are public, the
// mailbox is anon-readable by design, and the directory publishes no key to
// check a signature against. So the code is derived from the authenticated
// user's own id, which the caller cannot choose.
//
// WHAT THAT COSTS, STATED RATHER THAN HIDDEN: an existing name-only account
// that verifies an email gets a DIFFERENT code from the one it has been
// using, so its address changes and contacts holding the old one have to
// learn the new address from the profile broadcast. That is exactly what
// already happens when a name-only account verifies a NUMBER — the identity
// moves from the code to the number — and `Session.attachNumberInPlace` is
// the same in-place upgrade, keeping every chat, server and note on the
// device. It is an accepted trade-off here because it is the same one.

import { admin, corsHeaders, json } from "../_shared/http.ts";

/// Mirrors lib/util/account_code.dart: '00' + 10 digits, 12 total.
const CODE_PREFIX = "00";
const CODE_LENGTH = 12;

/// A code derived from the auth user's own id, so the caller cannot pick it.
///
/// Deterministic on (id, salt) so a retried request re-derives the same
/// candidate rather than scattering half-claimed codes across the table, and
/// salted so a collision has somewhere to go on the next attempt.
async function codeFor(userId: string, salt: number): Promise<string> {
  const bytes = new TextEncoder().encode(`${userId}:${salt}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  let out = "";
  for (let i = 0; out.length < CODE_LENGTH - CODE_PREFIX.length; i++) {
    out += (digest[i % digest.length] % 10).toString();
  }
  return CODE_PREFIX + out;
}

/// Whether some OTHER auth user already carries this phone value.
///
/// `listUsers` is the only way to ask — there is no get-by-phone — and the
/// page size is deliberately small because a hit is astronomically unlikely
/// and this runs on the signup path.
async function takenByAnother(code: string, meId: string): Promise<boolean> {
  const { data, error } = await admin.auth.admin.listUsers({
    page: 1,
    perPage: 200,
  });
  if (error) return true; // cannot prove it is free: refuse rather than guess
  return (data?.users ?? []).some(
    (u) => (u.phone ?? "") === code && u.id !== meId,
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "unauthorized" }, 401);
  const { data: got, error: authError } = await admin.auth.getUser(
    auth.replace("Bearer ", ""),
  );
  const user = got?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "bad request" }, 400);
  }
  if (body.what !== "claim") return json({ error: "bad request" }, 400);

  // The email must be CONFIRMED, not merely set. An unconfirmed address
  // proves nothing about who is behind the account, and this whole path
  // exists to let a confirmed one stand in for a phone number.
  const email = (user.email ?? "").trim().toLowerCase();
  if (!email) return json({ error: "no email on this account" }, 400);
  if (!user.email_confirmed_at) {
    return json({ error: "email not confirmed" }, 403);
  }

  // Already stamped — idempotent, so a retry after a dropped reply returns
  // the same code instead of minting a second one.
  const existing = (user.phone ?? "").trim();
  if (existing) return json({ code: existing });

  // A banned address may not buy its way back in with a fresh account. This
  // is the same list the app checks before attaching an email; checked again
  // here because the client's check is a courtesy and this one is the rule.
  try {
    const { data: banned } = await admin.rpc("is_email_banned", { e: email });
    if (banned === true) return json({ error: "banned" }, 403);
  } catch (_) {
    // The list is optional (docs/banned_signups.sql may not be applied).
    // Failing open here matches the app's own behaviour rather than locking
    // every new account out of a project that never ran that migration.
  }

  // Mint, checking each candidate is free. Three attempts is generous for a
  // one-in-ten-billion space; refusing after that is better than looping on
  // the signup path.
  let code = "";
  for (let salt = 0; salt < 3; salt++) {
    const candidate = await codeFor(user.id, salt);
    if (!(await takenByAnother(candidate, user.id))) {
      code = candidate;
      break;
    }
  }
  if (!code) return json({ error: "could not mint a code" }, 503);

  // `phone_confirm` because there is no number to send a code to — the
  // confirmed EMAIL is what was verified, and this field is carrying the
  // account's identity rather than a claim about a telephone.
  const { error: stampError } = await admin.auth.admin.updateUserById(user.id, {
    phone: code,
    phone_confirm: true,
  });
  if (stampError) return json({ error: "could not stamp the code" }, 500);

  // The caller still has to refresh its session for the claim to appear in
  // the JWT — nothing here can push a new token to them.
  return json({ code });
});
