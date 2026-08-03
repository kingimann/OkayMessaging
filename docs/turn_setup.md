# TURN relay setup — the fix for "calls only work sometimes"

**What the self-test found.** Settings → Check call setup shows STUN green
and **Relay path (TURN) red**. That means: calls connect whenever a direct
path exists (both phones on the same Wi-Fi, or on networks that allow it)
and **fail between two phones on cellular**, because carrier NAT makes a
direct path impossible and the free public relay the app fell back to is
dead.

**What fixes it.** A TURN server the project controls, reached through the
`turn-credentials` Edge Function so no key ever sits in the app or the
repo. Two options; the first is free and takes about five minutes.

## Option A — Metered (free tier, no card)

1. Sign up at <https://www.metered.ca/stun-turn> (the free plan's monthly
   relay quota is plenty for person-to-person calls).
2. In their dashboard, create a TURN app. Note the **app domain** (the
   `xxxx` in `xxxx.metered.live`) and the **API key**.
3. Supabase → Edge Functions → add secrets:
   - `METERED_DOMAIN` = the app domain (just the `xxxx` part)
   - `METERED_API_KEY` = the API key
4. Paste `docs/edge_functions_paste/turn-credentials.ts` as a new Edge
   Function named exactly `turn-credentials`, with **JWT verification
   OFF** (numberless accounts have no session and their calls need the
   relay too).
5. On the phone: Settings → **Check call setup** → run it again. The
   relay row goes green; calls between two phones on cellular now
   connect.

## Option B — your own coturn server

If you ever run a VPS: install coturn with `use-auth-secret`, then set
the secrets `TURN_URLS` (comma-separated, e.g.
`turn:turn.example.com:3478,turn:turn.example.com:443?transport=tcp`)
and `TURN_SHARED_SECRET` (coturn's `static-auth-secret`). The function
mints standard ephemeral credentials (6-hour HMAC), so the secret never
leaves the server side.

## How the app uses it

At call/room start the app asks `turn-credentials` for ice servers
(4-second timeout, cached ~30 minutes, fail-open — a missing function
changes nothing). Fetched servers are tried **before** the dead public
relay. The self-test probes the same resolved config, so the relay row
on that screen is always the truth about what a real call would use.
