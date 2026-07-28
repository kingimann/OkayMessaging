// PASTE-READY copy of push-send for the Supabase Dashboard editor
// (Edge Functions -> Deploy a new function -> Via Editor).
// Name the function EXACTLY: push-send
// It has no shared imports, so this is byte-identical to
// supabase/functions/push-send/index.ts — no inlining was needed.
// Leave "Enforce JWT verification" ON: only the app calls this, and it
// authenticates as the signed-in sender.
// Sends an APNs push to a user's registered device. Called by a SENDER's app
// right after it relays a message, so the recipient's phone wakes up even
// with the app closed. Message CONTENT is never included beyond what the
// sender chooses to show (title/body) — payloads stay minimal by design.
//
// POST { toPhone, title, body, badge? } -> { sent: boolean }
//
// Secrets required:
//   APNS_P8        contents of the .p8 auth key from developer.apple.com
//   APNS_KEY_ID    the key's 10-char id
//   APNS_TEAM_ID   your Apple team id
//   APNS_BUNDLE_ID com.okaymessaging
//   APNS_SANDBOX   "true" while testing via Xcode/TestFlight-dev builds
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, content-type, apikey" } });
  }
  // Any signed-in user may notify any phone (like sending a message); the
  // payload carries no secrets and unknown phones are a silent no-op.
  const auth = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const { data: caller } = await admin.auth.getUser(auth);
  if (!caller?.user) return Response.json({ error: "unauthorized" }, { status: 401 });

  const { toPhone, title, body, badge } = await req.json().catch(() => ({}));
  const digits = String(toPhone ?? "").replace(/\D/g, "");
  if (!digits || !title) return Response.json({ error: "bad request" }, { status: 400 });

  const { data: row } = await admin.from("push_tokens")
    .select("token").eq("phone", digits).maybeSingle();
  if (!row?.token) return Response.json({ sent: false });

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
    body: JSON.stringify({ aps: { alert: { title, body: body ?? "" },
      sound: "default", ...(badge != null ? { badge } : {}) } }),
  });
  return Response.json({ sent: res.ok });
});
