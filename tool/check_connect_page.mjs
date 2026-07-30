// Runs web/connect.html's real script and drives its secret negotiation.
//
//     deno run --allow-read tool/check_connect_page.mjs
//
// WHY THIS EXISTS. That script is the trickiest thing in the payments flow and
// nothing executed it: the Dart tests can only read it as text, and a WebView
// cannot be built in a VM test. Every bug in the Connect flow so far lived in
// exactly this handshake — a memoized secret, a reused initial secret, a
// rejection reason that got overwritten — and each was found by a person
// tapping the screen. This runs the state machine against a stub DOM instead.
//
// It does not touch Stripe. It checks the contract between the page and its
// host: who supplies which secret, in what order, and what is said when one
// doesn't arrive.

import { readFileSync } from "node:fs";

const html = readFileSync("web/connect.html", "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
if (scripts.length !== 1) {
  console.error(`expected one inline script in connect.html, found ${scripts.length}`);
  Deno.exit(1);
}
const src = scripts[0][1];

function makeEnv() {
  const status = { textContent: "", style: { display: "none" } };
  const events = [];
  const ctx = {
    document: {
      getElementById: (id) =>
        id === "status" ? status : { style: {}, appendChild() {} },
      addEventListener() {},
      createElement: () => ({ style: {}, appendChild() {} }),
    },
    OkayConnect: { postMessage: (m) => events.push(m) },
    setTimeout,
    clearTimeout,
    Promise,
    Error,
    console,
    StripeConnect: {},
    Stripe: undefined,
  };
  ctx.window = ctx;
  return { ctx, status, events };
}

// Evaluate the page script with window/document bound to the stub, and reach
// back in for the pieces under test.
function load(env) {
  const fn = new Function(
    "window",
    "document",
    "setTimeout",
    "clearTimeout",
    "console",
    src +
      "\n;return {requestSecret: requestSecret, fail: fail," +
      " setInitial: function (s) { initialSecret = s; }};",
  );
  return fn(env.ctx, env.ctx.document, setTimeout, clearTimeout, console);
}

let failures = 0;
function check(name, ok, extra = "") {
  console.log(`${ok ? "  ok  " : "  FAIL"} ${name}${ok ? "" : `  <- ${extra}`}`);
  if (!ok) failures++;
}
const secretId = (events) =>
  events.filter((e) => e.startsWith("secret:")).pop().slice("secret:".length);

// An Account Session authenticates once, so the initial secret is spent on the
// first fetch and every later fetch must come from the host.
{
  const env = makeEnv();
  const api = load(env);
  api.setInitial("accs_initial");
  check("first fetch spends the initial secret",
    (await api.requestSecret()) === "accs_initial");

  const p = api.requestSecret();
  check("second fetch asks the host",
    env.events.filter((e) => e.startsWith("secret:")).length === 1,
    JSON.stringify(env.events));
  env.ctx.okaySecret(secretId(env.events), "accs_second", "");
  check("the host's answer resolves it", (await p) === "accs_second");

  const q = api.requestSecret();
  env.ctx.okaySecret(secretId(env.events), "accs_third", "");
  const third = await q;
  check("the initial secret is never served twice", third === "accs_third",
    third);
}

// Nothing may fail silently: connect.js discards the rejection reason and
// paints its own account error, so the page has to say the cause itself.
{
  const env = makeEnv();
  const api = load(env);
  api.setInitial("accs_initial");
  await api.requestSecret();
  const p = api.requestSecret();
  env.ctx.okaySecret(secretId(env.events), "", "");
  let threw = false;
  try { await p; } catch { threw = true; }
  check("an empty answer rejects", threw);
  check("and is shown on the page",
    env.status.textContent.includes("could not start a Stripe session"),
    JSON.stringify(env.status.textContent));
  check("and is reported to the host",
    env.events.some((e) => e.startsWith("error:")));
}

// When the host knows why, its reason must win — reporting it separately
// produced two events for one failure and the generic one overwrote the useful
// one.
{
  const env = makeEnv();
  const api = load(env);
  api.setInitial("accs_initial");
  await api.requestSecret();
  const p = api.requestSecret();
  env.ctx.okaySecret(secretId(env.events), "", "key_mode_live_app_test_server");
  let msg = "";
  try { await p; } catch (e) { msg = e.message; }
  check("the host's reason is what gets reported",
    msg.includes("key_mode_live_app_test_server"), msg);
  check("it beats the page's fallback wording",
    !env.status.textContent.includes("could not start a Stripe session"),
    JSON.stringify(env.status.textContent));
  const errs = env.events.filter((e) => e.startsWith("error:"));
  check("one failure produces one error event", errs.length === 1,
    JSON.stringify(errs));
}

// A host too old to answer at all: say so, rather than time out mutely.
{
  const env = makeEnv();
  const api = load(env);
  api.setInitial("accs_initial");
  await api.requestSecret();
  let msg = "";
  try { await api.requestSecret(); } catch (e) { msg = e.message; }
  check("a silent host is named as an old app",
    msg.includes("cannot refresh the Stripe session"), msg);
}

console.log(failures === 0
  ? "connect.html: all checks passed"
  : `connect.html: ${failures} check(s) failed`);
if (failures) Deno.exit(1);
