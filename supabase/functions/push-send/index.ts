// Sends an APNs push to a user's registered device. Called by a SENDER's app
// right after it relays a message, so the recipient's phone wakes up even
// with the app closed. Message CONTENT is never included beyond what the
// sender chooses to show (title/body) — payloads stay minimal by design.
//
// POST { toPhone, title, body, badge?, fromPhone? } -> { sent: boolean }
//
// fromPhone rides along as a `from` key beside `aps` so tapping the alert can
// open THAT conversation rather than dumping the person on the chat list. It
// is the sender's number, and it does reach Apple — as the sender's name in
// the title already does. That is the cost of a notification you can act on,
// and it is a choice rather than an accident: a client that would rather not
// simply omits it, and the tap opens the app.
//
// Secrets required:
//   APNS_P8        contents of the .p8 auth key from developer.apple.com
//   APNS_KEY_ID    the key's 10-char id
//   APNS_TEAM_ID   your Apple team id
//   APNS_BUNDLE_ID com.okaymessaging
//   APNS_SANDBOX   "true" while testing via Xcode/TestFlight-dev builds
//
// POST { what: "check" } -> a self-test of exactly those five, because there
// is otherwise no way to find out whether they are right short of waiting for
// a push that never comes. Four of the five can be wrong in ways that produce
// the same silence, and the fifth (APNS_SANDBOX) can be *valid* and still send
// every alert to an environment the build isn't in. See checkSetup().
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

const b64url = (data: Uint8Array | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function apnsJwt(): Promise<string> {
  const p8 = Deno.env.get("APNS_P8") ?? "";
  const pem = p8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify(
    { alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") }));
  const claims = b64url(JSON.stringify(
    { iss: Deno.env.get("APNS_TEAM_ID"), iat: Math.floor(Date.now() / 1000) }));
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(`${header}.${claims}`)));
  return `${header}.${claims}.${b64url(sig)}`;
}

/// Asks Apple whether the auth key works, without needing a real device.
///
/// A push request is validated in order — provider token, then topic, then
/// device token — so posting a deliberately bogus device token gets Apple to
/// check everything above it and name what it disliked:
///
///   BadDeviceToken       the key, the team and the topic were all accepted;
///                        only the token we made up was rejected. A pass.
///   InvalidProviderToken APNS_P8 / APNS_KEY_ID / APNS_TEAM_ID don't agree,
///                        or the key has no access to this topic's app.
///   TopicDisallowed      the key is fine; APNS_BUNDLE_ID isn't its app.
///   ExpiredProviderToken the JWT is stale — a clock problem, not a secret.
///
/// Both hosts are asked, because they are separate Apple environments with
/// separate device tokens and the same key works against both. Which one gets
/// used is APNS_SANDBOX, and that setting is the one thing here a dashboard
/// cannot get wrong-but-look-right: `true` is correct only for a build
/// installed from Xcode. TestFlight and the App Store are production.
async function checkSetup(phone: string) {
  const present = (name: string) => (Deno.env.get(name) ?? "").length > 0;
  const secrets = {
    p8: present("APNS_P8"),
    keyId: present("APNS_KEY_ID"),
    teamId: present("APNS_TEAM_ID"),
    bundleId: Deno.env.get("APNS_BUNDLE_ID") ?? "",
    sandbox: Deno.env.get("APNS_SANDBOX") === "true",
  };

  let jwt = "";
  let keyError = "";
  try {
    jwt = await apnsJwt();
  } catch (e) {
    // Never echo the key itself — only that it could not be read as one.
    keyError = e instanceof Error ? e.message : "the key could not be read";
  }

  // A syntactically valid token that belongs to no device. Apple rejects it
  // by name, which is the whole point: nothing is delivered anywhere.
  const nowhere = "0".repeat(64);
  const ask = async (host: string) => {
    if (!jwt) return { host, status: 0, reason: "" };
    try {
      const res = await fetch(`https://${host}/3/device/${nowhere}`, {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": secrets.bundleId || "com.okaymessaging",
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify({ aps: { "content-available": 1 } }),
      });
      const text = await res.text();
      let reason = "";
      try {
        reason = String(JSON.parse(text).reason ?? "");
      } catch {
        reason = text.slice(0, 80);
      }
      return { host, status: res.status, reason };
    } catch (e) {
      return {
        host,
        status: 0,
        reason: e instanceof Error ? e.message.slice(0, 80) : "unreachable",
      };
    }
  };
  const [production, sandbox] = await Promise.all([
    ask("api.push.apple.com"),
    ask("api.sandbox.push.apple.com"),
  ]);

  const { data: row } = phone
    ? await admin.from("push_tokens").select("token, updated_at")
      .eq("phone", phone).maybeSingle()
    : { data: null };

  return {
    secrets,
    keyError,
    production,
    sandbox,
    // Whether the *caller's own* device ever uploaded a token. Every secret
    // can be right and nothing arrive because iOS never granted permission,
    // and that failure is on the phone rather than the server.
    device: { registered: !!row?.token, updatedAt: row?.updated_at ?? null },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, content-type, apikey" } });
  }
  // A signed-in caller may notify any phone (like sending a message); the
  // payload carries no secrets and unknown phones are a silent no-op. When
  // the function is DEPLOYED with JWT verification off, a sessionless
  // caller (a numberless account — Supabase authenticates a phone, so it
  // has no session to hold) may notify too: the worst a stranger can do
  // with it is buzz a phone with "New message", and the recipient-side
  // private flag governs content either way. The self-test stays gated —
  // it reports configuration, and configuration is for the signed-in.
  const auth = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const { data: caller } = await admin.auth.getUser(auth);

  const { what, toPhone, title, body, badge, fromPhone, kind, callId, video } =
    await req.json().catch(() => ({}));

  if (what === "check") {
    if (!caller?.user) {
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    return Response.json(
      await checkSetup((caller.user.phone ?? "").replace(/\D/g, "")),
    );
  }

  const digits = String(toPhone ?? "").replace(/\D/g, "");
  const from = String(fromPhone ?? "").replace(/\D/g, "");
  if (!digits || !title) return Response.json({ error: "bad request" }, { status: 400 });

  const { data: row } = await admin.from("push_tokens")
    .select("token, private, voip_token").eq("phone", digits).maybeSingle();
  if (!row?.token && !row?.voip_token) return Response.json({ sent: false });

  // A call rings the LOCK SCREEN of a closed app through PushKit + CallKit
  // — Apple's dedicated VoIP pipe, its own token and topic. The payload
  // carries only what CallKit needs to ring: who (a name), which call, and
  // whether video. Falls back to an ordinary alert when the device never
  // registered a VoIP token (an older build).
  if (kind === "call" && callId && row?.voip_token) {
    const host = (Deno.env.get("APNS_SANDBOX") === "true")
      ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const bundle = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";
    const res = await fetch(`https://${host}/3/device/${row.voip_token}`, {
      method: "POST",
      headers: {
        "authorization": `bearer ${await apnsJwt()}`,
        "apns-topic": `${bundle}.voip`,
        "apns-push-type": "voip",
        "apns-priority": "10",
      },
      body: JSON.stringify({
        callId: String(callId).slice(0, 128),
        fromName: row.private === true ? "OkayMessenger" : String(title).slice(0, 64),
        video: video === true,
        ...(from ? { from } : {}),
      }),
    });
    return Response.json({ sent: res.ok, voip: true });
  }
  if (!row?.token) return Response.json({ sent: false });

  // The RECIPIENT's choice, enforced here rather than trusted to the sender's
  // app: the push is composed on the sender's device, and a preference
  // protecting this recipient's lock screen cannot depend on somebody else's
  // settings. `from` still rides along — it is digits inside the payload,
  // never rendered, and it is what lets a tap open the right conversation.
  const wantsPrivate = row.private === true;
  const alertTitle = wantsPrivate ? "New message" : title;
  const alertBody = wantsPrivate ? "" : (body ?? "");

  // The badge: APNs can only SET a number, and the sender cannot know the
  // recipient's, so the server counts alerts since the app was last opened
  // (the app zeroes the row on open). An explicit badge from the caller
  // wins; a project missing the function just sends unbadged.
  let badgeCount: number | null = typeof badge === "number" ? badge : null;
  if (badgeCount == null) {
    const { data: bumped } = await admin.rpc("bump_unseen", { p: digits });
    if (typeof bumped === "number") badgeCount = bumped;
  }

  const host = (Deno.env.get("APNS_SANDBOX") === "true")
    ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${row.token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${await apnsJwt()}`,
      "apns-topic": Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging",
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({
      aps: {
        alert: { title: alertTitle, body: alertBody },
        sound: "default",
        // The app registers this category with a hidden-previews placeholder,
        // so a locked phone (with iOS's default "Show Previews: When
        // Unlocked") shows "New message" instead of the sender's name —
        // whatever the private flag says, because the flag is a choice and a
        // locked screen is not.
        category: "okay_msg",
        ...(badgeCount != null ? { badge: badgeCount } : {}),
      },
      ...(from ? { from } : {}),
    }),
  });
  return Response.json({ sent: res.ok });
});
