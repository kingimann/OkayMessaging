#!/bin/sh
# Type-check every Edge Function and paste copy.
# =============================================================================
# The dashboard is otherwise the first thing that ever compiles these: the
# Flutter gates never look at TypeScript, and three separate breakages shipped
# because of it — undeclared Stripe rate constants, a helper used without its
# import, and byte arrays that stopped satisfying BufferSource. All three would
# have been caught here in seconds.
#
#     sh tool/check_functions.sh
#
# Deno is not part of the pinned toolchain, so this installs it to /tmp on
# first run (~40 MB) and does nothing if it is already on PATH. Requires
# network access for the remote type definitions.

set -e

if ! command -v deno >/dev/null 2>&1; then
  if [ -x /tmp/deno/bin/deno ]; then
    PATH="/tmp/deno/bin:$PATH"
    export PATH
  else
    echo "deno not found — installing to /tmp/deno"
    curl -fsSL https://deno.land/install.sh -o /tmp/deno_install.sh
    DENO_INSTALL=/tmp/deno sh /tmp/deno_install.sh >/dev/null
    PATH="/tmp/deno/bin:$PATH"
    export PATH
  fi
fi

echo "deno $(deno --version | head -1 | cut -d' ' -f2)"

# A type-check cannot see this one. esm.sh's `?target=deno` build polyfills
# Node's `process` with deno.land/std@0.177.1, whose shim calls
# `Deno.core.runMicrotasks()` — unsupported in the Supabase edge runtime, so
# every request dies before reaching the handler. `?target=denonext` pulls in
# no std/node shims. Compiles identically either way, which is why only a
# deployed request ever told us.
if grep -rn 'target=deno"' supabase/functions docs/edge_functions_paste 2>/dev/null; then
  echo "--- FAIL: use ?target=denonext (the deno build breaks at runtime on Supabase)"
  exit 1
fi

failed=0
checked=0
for f in supabase/functions/*/index.ts docs/edge_functions_paste/*.ts; do
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  if out=$(deno check "$f" 2>&1); then
    :
  else
    echo "--- FAIL $f"
    # Drop the download chatter; keep the diagnostics.
    echo "$out" | grep -v "Download" | grep -v "^Check " | head -20
    failed=$((failed + 1))
  fi
done

echo "checked $checked file(s), $failed failing"

# The decisions the shared helpers make, actually executed — who gets to post,
# whose card is refused, whose money moves. A threshold nobody runs is a
# threshold that drifts, and a type-check has no opinion about any of them.
#
# apple_jws and iap are node tests: one needs an openssl-generated certificate
# chain, the other replaces globalThis.Deno, which newer Deno will not allow.
# Both are run by hand per docs/in_app_purchases_setup.md.
DENO_TESTS="cardholder moderation payment_limits"
NODE_TESTS="apple_jws iap"

for name in $DENO_TESTS; do
  t="supabase/functions/_shared/${name}_test.mjs"
  [ -f "$t" ] || { echo "--- FAIL $name has no test file"; failed=$((failed + 1)); continue; }
  if out=$(deno run --allow-read "$t" 2>&1); then
    echo "$name: $(echo "$out" | tail -1)"
  else
    echo "--- FAIL $name"
    echo "$out" | grep FAIL | head -10
    failed=$((failed + 1))
  fi
done

# A new shared test that nobody wired up is a test that never runs — which is
# how cardholder_test.mjs sat here unexecuted. Naming both lists makes the
# omission loud instead of invisible.
for t in supabase/functions/_shared/*_test.mjs; do
  [ -f "$t" ] || continue
  name=$(basename "$t" _test.mjs)
  case " $DENO_TESTS $NODE_TESTS " in
    *" $name "*) ;;
    *) echo "--- FAIL $name is not run by anything (add it to tool/check_functions.sh)"
       failed=$((failed + 1)) ;;
  esac
done

# The Connect page's secret handshake, actually executed. Every bug in that
# flow so far lived here and was found by tapping the screen; the Dart tests can
# only read it as text.
if [ -f tool/check_connect_page.mjs ]; then
  deno run --allow-read tool/check_connect_page.mjs || failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || exit 1
