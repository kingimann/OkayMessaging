// Hands the app ICE servers for calls — specifically a TURN relay it can
// actually reach, which the free public relay baked into old builds is not
// (the call self-test proved it: STUN green, relay red, "calls only work
// when a direct path exists").
//
// Two sources, tried in order; secrets stay HERE so nothing lands in git:
//
//   METERED_DOMAIN + METERED_API_KEY   a metered.ca TURN app (free tier is
//                                      enough for person-to-person calls).
//                                      The API mints short-lived
//                                      credentials per request.
//   TURN_URLS + TURN_SHARED_SECRET     any coturn server with
//                                      use-auth-secret: credentials are
//                                      minted here with the standard
//                                      REST-API HMAC scheme, valid 6 hours.
//
// With neither set it answers an empty list, and the app simply keeps the
// config it has — this function can never make calls worse.
//
// Deployed with JWT verification OFF on purpose: numberless accounts have
// no session and their calls need the relay exactly as much. The worst a
// stranger can do is relay THEIR call through your TURN quota — bounded by
// the credentials' short life, and the same trade push-send already makes.
//
// POST {} -> { iceServers: [{urls, username, credential}...], ttlSeconds }

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
};

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

async function coturnCredential(
  secret: string,
  ttlSeconds: number,
): Promise<{ username: string; credential: string }> {
  const username = `${Math.floor(Date.now() / 1000) + ttlSeconds}:okay`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username)),
  );
  return { username, credential: b64(mac) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const domain = Deno.env.get("METERED_DOMAIN") ?? "";
  const apiKey = Deno.env.get("METERED_API_KEY") ?? "";
  if (domain && apiKey) {
    try {
      const res = await fetch(
        `https://${domain}.metered.live/api/v1/turn/credentials?apiKey=${apiKey}`,
      );
      if (res.ok) {
        const list = await res.json();
        if (Array.isArray(list) && list.length > 0) {
          return Response.json(
            { iceServers: list, ttlSeconds: 1800 },
            { headers: cors },
          );
        }
      }
    } catch (_) {
      // Fall through — a flaky provider must not kill the coturn path.
    }
  }

  const urls = (Deno.env.get("TURN_URLS") ?? "")
    .split(",")
    .map((u) => u.trim())
    .filter((u) => u.length > 0);
  const secret = Deno.env.get("TURN_SHARED_SECRET") ?? "";
  if (urls.length > 0 && secret) {
    const ttl = 6 * 3600;
    const cred = await coturnCredential(secret, ttl);
    return Response.json(
      {
        iceServers: [
          { urls, username: cred.username, credential: cred.credential },
        ],
        ttlSeconds: ttl,
      },
      { headers: cors },
    );
  }

  return Response.json({ iceServers: [], ttlSeconds: 300 }, { headers: cors });
});
