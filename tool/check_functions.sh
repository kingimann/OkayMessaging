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
[ "$failed" -eq 0 ] || exit 1
