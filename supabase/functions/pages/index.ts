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
  `<p>A messenger that keeps your conversations on your own phone. Messages are
   encrypted before they leave the device, and there is no copy of them on any
   server to read, hand over, or lose.</p>
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

Deno.serve((req) => {
  // Last non-empty segment, so it works whether or not a slash is trailing.
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const leaf = parts[parts.length - 1] ?? "";
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
