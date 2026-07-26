# iOS signing — how it works now

Signing is handled automatically. There is nothing to generate by hand.

## What's in place

| Piece | Where | Status |
|---|---|---|
| Bundle ID `com.okaymessaging` | Apple Developer portal | registered |
| App record | App Store Connect | created |
| API key `OkayMessenger` | Codemagic → integrations | connected |
| Distribution certificate `OkayDis` (Production) | Codemagic → code signing identities | generated |

With a Production certificate present, the `ios_signing` block in
codemagic.yaml lets Codemagic create the App Store provisioning profile
itself on the first build, then reuse it afterwards.

## Why the earlier builds failed

1. **"No matching profiles found for bundle identifier ... app_store"**
   No distribution certificate existed yet, so Apple had nothing to
   build a profile from. Fixed by generating the Production certificate.

2. **"Cannot save Signing Certificates without certificate private key"**
   Creating a certificate from the CLI needs a private key to sign the
   request with. No longer relevant — the certificate already exists, so
   nothing needs creating.

## If a build still fails on signing

- Check the API key has the **App Manager** role:
  App Store Connect → Users and Access → Integrations → Access column.
  A Developer-role key can authenticate but cannot manage profiles.
- Confirm the certificate type is **Production**, not development —
  `app_store` distribution cannot use a development certificate.
- As a fallback, create the profile by hand:
  developer.apple.com → Certificates, Identifiers & Profiles → Profiles →
  **+** → *App Store Connect* → App ID `com.okaymessaging` → pick the
  distribution certificate → Generate → download, then upload it in
  Codemagic under code signing identities.
