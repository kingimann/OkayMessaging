# Push notifications — setup status

## Done (server half, in this repo)
- `push_tokens` table in supabase/schema.sql (re-run the file in SQL Editor)
- `push-send` Edge Function (supabase/functions/push-send) that sends a real
  APNs push to a phone's registered device

## Your one-time steps
1. developer.apple.com → Certificates, IDs & Profiles → Keys → + →
   enable **Apple Push Notifications service (APNs)** → download the .p8
   (note the Key ID; Team ID is top-right of the page).
2. developer.apple.com → Identifiers → com.okaymessaging → enable the
   **Push Notifications** capability (then let Codemagic regenerate the
   provisioning profile on the next build).
3. Deploy the function (dashboard paste or CLI) and set Edge Function
   secrets: APNS_P8 (file contents), APNS_KEY_ID, APNS_TEAM_ID,
   APNS_BUNDLE_ID=com.okaymessaging, APNS_SANDBOX=true while testing.
4. Re-run the SQL file so push_tokens exists.

## Remaining (next session, in-app native half)
- iOS push registration (aps-environment entitlement + token upload to
  push_tokens on sign-in) — added carefully so launch stays stable.
- Sender-side hook: after relaying a message/call, POST push-send
  { toPhone, title: sender name, body: preview } respecting mute/privacy.
