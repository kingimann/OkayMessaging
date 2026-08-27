// supabase: verify_jwt = false
//
// The handful of web pages the app needs to exist, served from the project
// the app already depends on.
//
// A BROWSER OPENS THESE, so there is no Supabase session to send and the JWT
// gate must be OFF (same as payments-webhook and iap-notify). They read
// nothing, write nothing, and take no input — the worst an anonymous caller
// can do is read three paragraphs of static HTML.
//
// They used to be files on GitHub Pages, which is the problem they now solve.
// That site republishes the repository's README over the app for minutes
// after every push, so a confirmation link clicked in the wrong minute landed
// on "File not found" — and there is nothing the app can do about a page
// somebody opens in Safari on another device. Here there is no second system
// and no deploy race: if the app can reach its own backend, the page is up.
//
//   /functions/v1/pages                  what this app is (share/invite target)
//   /functions/v1/pages/done             Stripe's hosted flows return here
//   /functions/v1/pages/email-confirmed  where a confirmation link lands

import { PRIVACY_HTML, TERMS_HTML } from "../_shared/legal_pages.ts";
const page = (title: string, heading: string, body: string) =>
  `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${title}</title>
<style>
  :root { color-scheme: light dark; --ink: #10131a; --dim: #6b7280; --bg: #ffffff; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #f2f4f8; --dim: #9aa1ad; --bg: #0d1015; }
  }
  html, body { margin: 0; height: 100%; background: var(--bg); }
  body {
    display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--ink); padding: 32px; box-sizing: border-box;
  }
  main { max-width: 30rem; text-align: center; }
  h1 { font-size: 1.5rem; font-weight: 700; margin: 0 0 0.75rem; }
  p { font-size: 1rem; line-height: 1.55; color: var(--dim); margin: 0 0 0.75rem; }
</style>
</head>
<body><main><h1>${heading}</h1>${body}</main></body>
</html>`;

const html = (body: string, status = 200) =>
  new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // Cheap to render and it never changes between deploys, but keep it
      // short: this is also how a wrong page stops being served.
      "Cache-Control": "public, max-age=300",
      "Access-Control-Allow-Origin": "*",
    },
  });

const LANDING = page(
  "OkayMessenger",
  "OkayMessenger",
  `<p>A messenger with a public side: post to a feed anyone can read, follow
   people, and keep your conversations in the same app.</p>
   <p>If somebody sent you this, ask them for an invite — that is currently the
   only way in.</p>`,
);

// Stripe's hosted flows finish by navigating to a return URL. In the app that
// navigation is caught and cancelled before anything renders, so this is only
// ever seen by somebody who got there in a real browser.
const DONE = page(
  "All done",
  "All done",
  `<p>You can close this window and go back to OkayMessenger.</p>`,
);

// Supabase reports a failure — an expired or already-used link — in the URL
// FRAGMENT, which never reaches a server. So the correction has to happen in
// the page: saying "confirmed" over the top of that would be a lie the reader
// only discovers later, in the app, with no idea why.
const EMAIL_CONFIRMED = page(
  "Email confirmed",
  "Email confirmed",
  `<p id="detail">Your address is verified. You can close this window — the app
   picks it up on its own the next time you open it.</p>
<script>
  (function () {
    var hash = window.location.hash || '';
    var params = new URLSearchParams(hash.replace(/^#/, ''));
    var error = params.get('error_description') || params.get('error');
    if (!error) return;
    document.querySelector('h1').textContent = 'Link didn’t work';
    document.getElementById('detail').textContent =
      error.replace(/\\+/g, ' ') +
      '. Open OkayMessenger and send yourself a new confirmation email.';
  })();
</script>`,
);

/// User content going into HTML on a page anyone can open. Escaped, always
/// and everywhere — this is the only place in this project where somebody
/// else's text is rendered as markup, and an unescaped body is an XSS hole
/// on the app's own domain.
const esc = (raw: string) =>
  raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");

/// One line for a link preview. Collapsed and cut, because an unfurl shows
/// two lines and a five-hundred-word post would be sent whole to every
/// service that renders one.
const summarise = (raw: string, max = 200) => {
  const flat = raw.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
};

/// The public page for one post — the thing that makes a post shareable at
/// all. Share used to copy the post's TEXT to the clipboard: there was no
/// URL for a post and no page for one, so nothing could be pasted anywhere
/// and no link ever pointed back into the app.
///
/// **Read with the ANON key, deliberately, not the service role.** The
/// `public_feed` view is world-readable by design and carries every rule
/// with it: a banned or shadow-banned author's posts are already invisible
/// to anon (`content_visible`), and a subscribers-only post's row carries
/// only its TEASER — the real body lives in `public_paid_bodies`, which
/// nothing may select. Reading as the service role would quietly bypass all
/// three and turn this page into a way around every moderation decision the
/// app makes.
const postPage = async (id: string): Promise<Response> => {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !key) return html(LANDING);
  let row: Record<string, unknown> | null = null;
  try {
    const res = await fetch(
      `${url}/rest/v1/public_feed?id=eq.${encodeURIComponent(id)}` +
        `&select=id,body,author_name,author_username,created_at&limit=1`,
      { headers: { apikey: key, Authorization: `Bearer ${key}` } },
    );
    if (res.ok) {
      const rows = await res.json();
      if (Array.isArray(rows) && rows.length > 0) row = rows[0];
    }
  } catch {
    // Unreachable is not "no such post" — say so rather than claiming it
    // was deleted.
    return html(
      page("OkayMessenger", "Can't load this post", `<p>Try again shortly.</p>`),
      503,
    );
  }
  if (!row) {
    return html(
      page(
        "Post not found",
        "Post not found",
        `<p>This post was deleted, or it was never public.</p>`,
      ),
      404,
    );
  }
  const body = String(row.body ?? "");
  const handle = String(row.author_username ?? "");
  const name = String(row.author_name ?? "") || (handle ? `@${handle}` : "Someone");
  const title = `${name} on OkayMessenger`;
  const summary = summarise(body);
  // The Open Graph tags ARE the feature: they are what makes the link unfurl
  // in the messenger somebody pastes it into, which is the whole growth
  // mechanism. A link that renders as a bare URL is a link nobody opens.
  const meta =
    `<meta property="og:type" content="article">` +
    `<meta property="og:site_name" content="OkayMessenger">` +
    `<meta property="og:title" content="${esc(title)}">` +
    `<meta property="og:description" content="${esc(summary)}">` +
    `<meta name="twitter:card" content="summary">` +
    `<meta name="twitter:title" content="${esc(title)}">` +
    `<meta name="twitter:description" content="${esc(summary)}">`;
  const when = String(row.created_at ?? "");
  return html(
    `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
${meta}
<style>
  :root { color-scheme: light dark; --ink: #10131a; --dim: #6b7280; --bg: #ffffff; --line: #e5e7eb; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #f2f4f8; --dim: #9aa1ad; --bg: #0d1015; --line: #232833; }
  }
  html, body { margin: 0; background: var(--bg); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--ink); padding: 32px; box-sizing: border-box;
  }
  main { max-width: 34rem; margin: 0 auto; }
  .who { font-weight: 700; font-size: 1rem; }
  .at, time { color: var(--dim); font-size: 0.85rem; }
  .body { font-size: 1.15rem; line-height: 1.55; margin: 1rem 0 1.5rem; white-space: pre-wrap; word-wrap: break-word; }
  .open { display: inline-block; border: 1px solid var(--line); border-radius: 999px;
          padding: 0.6rem 1.1rem; text-decoration: none; color: var(--ink); font-size: 0.95rem; }
</style>
</head>
<body><main>
  <div class="who">${esc(name)}</div>
  ${handle ? `<div class="at">@${esc(handle)}</div>` : ""}
  <div class="body">${esc(body)}</div>
  ${when ? `<time datetime="${esc(when)}">${esc(when.slice(0, 10))}</time>` : ""}
  <p><a class="open" href="okaymsg://post?id=${encodeURIComponent(id)}">Open in OkayMessenger</a></p>
</main></body>
</html>`,
  );
};

Deno.serve(async (req) => {
  // Last non-empty segment, so it works whether or not a slash is trailing.
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const leaf = parts[parts.length - 1] ?? "";
  // /pages/p/<id> — checked before the switch, because the leaf here is the
  // POST ID rather than a route name.
  if (parts.length >= 2 && parts[parts.length - 2] === "p" && leaf) {
    return await postPage(leaf);
  }
  switch (leaf) {
    case "done":
      return html(DONE);
    case "email-confirmed":
      return html(EMAIL_CONFIRMED);
    // The App Store needs a reachable Privacy Policy URL, and it must not be
    // a link to wherever the source lives. Served from here because this
    // function is already the app's one public host — the same reason every
    // other URL the app names comes off it.
    case "privacy":
      return html(PRIVACY_HTML);
    case "terms":
      return html(TERMS_HTML);
    default:
      // Anything else is the function's own root, or a path nobody meant.
      // Both get the landing page rather than a 404: a confirmation link with
      // a typo in it should still say something true.
      return html(LANDING);
  }
});
