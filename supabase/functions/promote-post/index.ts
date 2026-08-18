// Starts (or extends) a paid placement on one of the caller's OWN public
// posts, after VERIFYING the store receipt.
//
// The owner's ask was "a custom ad system... so I can allow users to pay to
// advertise their post" — the app's own inventory, sold to its own users,
// separate from the AdMob banners on the two public surfaces.
//
// Promoting a post is a digital good bought inside the app, so it bills
// through the App Store as a CONSUMABLE, exactly like a creator subscription
// or an Okay AI pass: Apple does not know WHICH post it was for, so the app
// tells us the post and hands over the signed transaction (JWS) Apple gave
// it. We verify Apple's signature ourselves, refuse a product that is not a
// promotion tier, refuse a receipt already consumed, refuse a post that is
// not the caller's, and only THEN write the row. `post_promotions` has no
// client write policy of any kind — this function, running as the service
// role, is its only writer, so a modified client can change what it draws but
// cannot buy itself reach.
//
// POST { postId, jws } -> { until, days }

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { JwsError, verifyAppleJws } from "../_shared/apple_jws.ts";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.okaymessaging";
const DAY_MS = 24 * 3600 * 1000;
// com.okaymessaging.promote.tier0.week … tier3.week
const PROMOTE = /\.promote\.tier([0-3])\.week$/;

// How many days each tier buys. Paying more buys more DAYS, never a better
// slot — there is no auction here, so there is nothing to outbid and no
// reason for the serving side to read what was spent.
const DAYS_FOR_TIER = [3, 7, 14, 30];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const me = await callerPhone(req);
  if (!me) return json({ error: "unauthorized" }, 401);

  let postId = "";
  let jws = "";
  try {
    const body = await req.json();
    postId = String(body.postId ?? "").trim();
    jws = String(body.jws ?? "");
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!postId || !jws) return json({ error: "missing post or receipt" }, 400);

  let payload: Record<string, unknown>;
  try {
    payload = await verifyAppleJws(jws);
  } catch (e) {
    // A token that doesn't verify is the whole threat model. Say no, and
    // don't leak which check failed.
    if (e instanceof JwsError) return json({ error: "invalid receipt" }, 400);
    throw e;
  }

  if (payload.bundleId !== BUNDLE_ID) return json({ error: "wrong app" }, 400);

  const productId = String(payload.productId ?? "");
  const tierMatch = PROMOTE.exec(productId);
  if (!tierMatch) return json({ error: "not a promotion" }, 400);
  const days = DAYS_FOR_TIER[Number(tierMatch[1])] ?? DAYS_FOR_TIER[0];

  const txnId = String(payload.transactionId ?? "");
  if (!txnId) return json({ error: "incomplete receipt" }, 400);

  // You may only promote your OWN post. Checked against the row rather than
  // trusted from the request: otherwise anybody could buy a placement for
  // somebody else's post, which is a way to put words in their mouth at the
  // top of a timeline.
  const { data: post } = await admin
    .from("public_posts")
    .select("author_phone")
    .eq("id", postId)
    .maybeSingle();
  if (!post) return json({ error: "unknown post" }, 404);
  if (post.author_phone !== me) return json({ error: "not your post" }, 403);

  // A sanctioned account cannot buy its way back onto the timeline. The read
  // policy hides the placement anyway, but refusing the CHARGE is the honest
  // order — taking the money and hiding the ad would be worse.
  const { data: silenced } = await admin.rpc("is_silenced", { p: me });
  if (silenced === true) return json({ error: "account restricted" }, 403);

  // Refuse a receipt already banked, so one purchase cannot promote many.
  const { data: seen } = await admin
    .from("promote_receipts")
    .select("txn_id")
    .eq("txn_id", txnId)
    .maybeSingle();
  if (seen) return json({ error: "receipt already used" }, 409);

  // Extend from whatever is left, so buying again stacks rather than resets.
  const { data: existing } = await admin
    .from("post_promotions")
    .select("until, spent_cents")
    .eq("post_id", postId)
    .maybeSingle();
  const now = Date.now();
  const curMs = existing?.until ? Date.parse(existing.until as string) : 0;
  const base = curMs > now ? curMs : now;
  const until = new Date(base + days * DAY_MS).toISOString();

  // What Apple actually charged, when the receipt says. Never used to rank —
  // it is for the promoter's own screen.
  const price = Number(payload.price ?? 0);
  const paidCents = Number.isFinite(price) && price > 0
    ? Math.round(price / 1000)
    : 0;

  await admin.from("post_promotions").upsert({
    post_id: postId,
    promoter_phone: me,
    until,
    spent_cents: Number(existing?.spent_cents ?? 0) + paidCents,
    updated_at: new Date(now).toISOString(),
  });
  await admin.from("promote_receipts").insert({ txn_id: txnId });

  return json({ until, days });
});
