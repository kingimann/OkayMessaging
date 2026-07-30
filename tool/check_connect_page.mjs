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

// `answer` decides what Stripe says to the key probe; `requests` records what
// the page sent, because a page that posts anything but a publishable key to
// Stripe would be a privacy bug rather than a diagnostic.
function makeEnv({ answer = null } = {}) {
  const status = { textContent: "", style: { display: "none" } };
  const events = [];
  const requests = [];
  const mounted = [];
  const fetchStub = (url, opts) => {
    requests.push({ url, opts });
    if (!answer) return Promise.reject(new Error("offline"));
    return Promise.resolve({ json: () => Promise.resolve(answer) });
  };
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
    // Stands in for the loader. Recording the key it is initialised with is
    // the only way to tell "refused before mounting" from "mounted anyway".
    StripeConnect: {
      init: (opts) => {
        mounted.push(opts.publishableKey);
        return {
          create: () => ({
            setOnExit() {},
            setOnLoadError() {},
            setOnLoaderStart() {},
          }),
        };
      },
    },
    Stripe: undefined,
  };
  ctx.window = ctx;
  return { ctx, status, events, requests, mounted, fetchStub };
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
    "fetch",
    src +
      "\n;return {requestSecret: requestSecret, fail: fail," +
      " describeKey: describeKey, keyNote: keyNote," +
      " setInitial: function (s) { initialSecret = s; }};",
  );
  return fn(env.ctx, env.ctx.document, setTimeout, clearTimeout, console,
    env.fetchStub);
}

// The probe is a promise the page deliberately doesn't await, so give it a turn.
const settle = () => new Promise((r) => setTimeout(r, 0));

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

// A missing publishable key must be named, not handed to Stripe. Passing ''
// to StripeConnect.init produces the same "authenticating your account"
// message as a mismatched key and sends people to check their bank details.
{
  const env = makeEnv();
  const api = load(env);
  env.ctx.okayStart("accs_initial", "", false, "#12b76a");
  check("no publishable key is named as such",
    env.status.textContent.includes("no Stripe publishable key"),
    JSON.stringify(env.status.textContent));
  check("and Stripe is never initialised without one", env.mounted.length === 0,
    JSON.stringify(env.mounted));
}

{
  const env = makeEnv();
  const api = load(env);
  env.ctx.okayStart("accs_initial", "sk_live_nope", false, "#12b76a");
  check("something that isn't a publishable key is refused",
    env.status.textContent.includes("not a Stripe"),
    JSON.stringify(env.status.textContent));
  check("and is not sent to Stripe either", env.mounted.length === 0);
}

// A real key: mount, and ask Stripe which account it belongs to so a later
// failure can say what the secret key has to match.
{
  const env = makeEnv({
    answer: {
      error: {
        code: "parameter_missing",
        request_log_url:
          "https://dashboard.stripe.com/acct_1EXa8MFoLcXnRrCb/workbench/logs?object=req_x",
      },
    },
  });
  const api = load(env);
  env.ctx.okayStart("accs_initial", "pk_live_abcdMM3P", true, "#12b76a");
  check("a real key mounts the component",
    env.mounted[0] === "pk_live_abcdMM3P", JSON.stringify(env.mounted));
  check("exactly one request goes to Stripe", env.requests.length === 1,
    JSON.stringify(env.requests));
  check("and it carries nothing but the key",
    env.requests[0].url === "https://api.stripe.com/v1/tokens" &&
      env.requests[0].opts.body === "key=pk_live_abcdMM3P",
    JSON.stringify(env.requests[0]));

  await settle();
  api.fail("An error occurred while authenticating your account.");
  const text = env.status.textContent;
  check("a failure names the key's mode", text.includes("live-mode"), text);
  check("names the account to match",
    text.includes("acct_1EXa8MFoLcXnRrCb"), text);
  check("and says which secret to compare it with",
    text.includes("STRIPE_SECRET_KEY") && text.includes("sk_live_"), text);
  check("without leaking the whole key",
    !text.includes("pk_live_abcdMM3P") && text.includes("MM3P"), text);
  check("the host still hears Stripe's own words",
    env.events.some((e) => e === "error:An error occurred while " +
      "authenticating your account."), JSON.stringify(env.events));
}

// Two accounts, both known: name the cause instead of asking somebody to
// compare two things themselves.
{
  const env = makeEnv({
    answer: {
      error: {
        request_log_url:
          "https://dashboard.stripe.com/acct_APPKEY/workbench/logs?object=req_x",
      },
    },
  });
  const api = load(env);
  env.ctx.okayStart("accs_initial", "pk_live_abcdMM3P", false, "#12b76a",
    "acct_SERVERKEY");
  await settle();
  api.fail("An error occurred while authenticating your account.");
  const text = env.status.textContent;
  check("different accounts are named as the cause",
    text.includes("different accounts") && text.includes("acct_APPKEY") &&
      text.includes("acct_SERVERKEY"), text);
  check("and the fix names the key to change",
    text.includes("STRIPE_SECRET_KEY") && text.includes("sk_live_"), text);
}

// The same account on both sides is not a fault: say nothing about accounts.
{
  const env = makeEnv({
    answer: {
      error: {
        request_log_url:
          "https://dashboard.stripe.com/acct_SAME/workbench/logs?object=req_x",
      },
    },
  });
  const api = load(env);
  env.ctx.okayStart("accs_initial", "pk_live_abcdMM3P", false, "#12b76a",
    "acct_SAME");
  await settle();
  api.fail("Stripe could not load the setup form.");
  check("matching accounts are not blamed",
    !env.status.textContent.includes("different accounts"),
    JSON.stringify(env.status.textContent));
}

// A key Stripe no longer recognises is a cause, not a hint.
{
  const env = makeEnv({
    answer: { error: { message: "Invalid API Key provided: pk_live_***" } },
  });
  const api = load(env);
  env.ctx.okayStart("accs_initial", "pk_live_rolled", false, "#12b76a");
  await settle();
  api.fail("An error occurred while authenticating your account.");
  check("a rolled key is named outright",
    env.status.textContent.includes("does not recognise"),
    JSON.stringify(env.status.textContent));
  check("and no account-matching advice is given for it",
    !env.status.textContent.includes("STRIPE_SECRET_KEY"),
    JSON.stringify(env.status.textContent));
}

// Stripe unreachable. The mode is read off the key itself, so that half of the
// advice still stands — but no account may be named, because none is known.
{
  const env = makeEnv();
  const api = load(env);
  env.ctx.okayStart("accs_initial", "pk_live_abcdMM3P", false, "#12b76a");
  await settle();
  api.fail("Stripe could not load the setup form.");
  const text = env.status.textContent;
  check("the mode is known without asking Stripe",
    text.includes("live-mode") && text.includes("sk_live_"), text);
  check("and no account is invented", !text.includes("acct_"), text);
}

console.log(failures === 0
  ? "connect.html: all checks passed"
  : `connect.html: ${failures} check(s) failed`);
if (failures) Deno.exit(1);
