# iOS signing — the one thing you need to add

The build keeps failing with:

> No matching profiles found for bundle identifier "com.okaymessaging"
> and distribution type "app_store"

That is **not** a certificate problem and **not** an environment-variable
naming problem. It is this: a brand-new app has **no App Store provisioning
profile yet**, and Codemagic's automatic `ios_signing` block only ever
*fetches* signing files — it never creates them. So there is nothing to
fetch, and the build dies.

The fix (already in `codemagic.yaml`) runs the profile creation explicitly:

```yaml
- name: Create or fetch the signing files
  script: |
    app-store-connect fetch-signing-files "$BUNDLE_ID" \
      --type IOS_APP_STORE \
      --certificate-key="@env:CERTIFICATE_PRIVATE_KEY" \
      --create
```

`--create` tells Apple to **issue** the missing distribution certificate and
App Store profile the first time, then reuse them on later builds.

## The single manual step: add `CERTIFICATE_PRIVATE_KEY`

`--create` signs the new certificate with a private key, so Codemagic needs
one. Add it once:

1. Generate a key (any machine with `ssh-keygen`):

   ```sh
   ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N ""
   ```

   This writes a file called `cert_key`. **Do not commit it** — it is a
   private key. (`.gitignore` already excludes it.)

2. In Codemagic → your app → **Environment variables**, add:
   - **Variable name:** `CERTIFICATE_PRIVATE_KEY`
   - **Value:** paste the **entire** contents of `cert_key`, including the
     `-----BEGIN RSA PRIVATE KEY-----` / `-----END RSA PRIVATE KEY-----`
     lines.
   - **Group:** leave the default (or any group) — it does not need to match
     anything.
   - Tick **Secure**.

3. Re-run the `iOS release (TestFlight)` workflow.

That is the only thing missing. Once the first build succeeds, Apple has the
certificate and profile on file and every later build just reuses them.

## Requirements checklist (all already done except step 2 above)

| Piece | Where | Status |
|---|---|---|
| Bundle ID `com.okaymessaging` | Apple Developer portal | registered |
| App record | App Store Connect | created |
| API key `OkayMessenger` | Codemagic → integrations | connected |
| `CERTIFICATE_PRIVATE_KEY` | Codemagic → environment variables | **add this** |

## If it *still* fails after adding the key

- **API key role.** The App Store Connect API key must have the **Admin** or
  **App Manager** role — a Developer-role key can authenticate but cannot
  create certificates or profiles. Check under App Store Connect → Users and
  Access → Integrations → Keys → the *Access* column. If it is only
  "Developer", generate a new key with App Manager and reconnect it in
  Codemagic.
- **Manual fallback.** Create the profile by hand at developer.apple.com →
  Certificates, Identifiers & Profiles → Profiles → **+** → *App Store
  Connect* → App ID `com.okaymessaging` → pick a distribution certificate →
  Generate → download, then upload it in Codemagic under code signing
  identities. With the profile pre-created, even the automatic block works.
