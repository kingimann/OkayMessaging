# Shared Edge Function helpers

| File | What |
|---|---|
| `http.ts` | Service-role Supabase client, CORS, JSON replies, `callerPhone` |
| `stripe.ts` | Stripe client and the platform fee (re-exports `http.ts`) |
| `apple_jws.ts` | Verifies Apple-signed JWS (StoreKit transactions, server notifications) |
| `iap.ts` | Subscription rows and what a notification does to them |

The dashboard editor can't resolve these, so the copies under
`docs/edge_functions_paste/` inline them. Regenerate after any change here:

```bash
dart tool/paste_functions.dart
```

`flutter test` fails if you forget.

## Running the TypeScript tests

There's no Deno in this container, but the helpers use only standard
WebCrypto, so Node 22 runs them unchanged:

```bash
node --experimental-strip-types supabase/functions/_shared/apple_jws_test.mjs
node --experimental-strip-types supabase/functions/_shared/iap_test.mjs
```

`apple_jws_test.mjs` needs a throwaway certificate chain — it builds one with
openssl into a `chain/` directory beside itself (see the top of the file).
The case that matters most is "rejects a forged leaf with the real root
appended": pinning Apple's root proves nothing on its own, because that root
is public and anyone can staple it onto a chain they made up. The chain walk
is what actually stops a forged receipt.
