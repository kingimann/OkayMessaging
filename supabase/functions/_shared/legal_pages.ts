// GENERATED — do not edit by hand.
// Source: lib/legal/legal_content.dart · regenerate: dart tool/build_legal_pages.dart
//
// The legal documents as standalone pages, served by the `pages` function so
// the App Store's required Privacy Policy URL points at the app's own host
// rather than at wherever the source happens to live.

export const PRIVACY_HTML = `<!DOCTYPE html>
<!--
  GENERATED — do not edit by hand.
  Source: lib/legal/legal_content.dart · regenerate: dart tool/build_legal_pages.dart
-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Privacy Policy · OkayMessenger</title>
<style>
  :root { color-scheme: light dark; --fg: #1a1c1e; --dim: #5f6368; --bg: #ffffff; --rule: #e3e5e8; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e8eaed; --dim: #9aa0a6; --bg: #121417; --rule: #2a2d31; }
  }
  html, body { margin: 0; background: var(--bg); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--fg); padding: 28px 20px 64px; box-sizing: border-box;
    -webkit-text-size-adjust: 100%;
  }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 24px; margin: 0 0 4px; font-weight: 700; letter-spacing: -0.2px; }
  .meta { font-size: 13px; color: var(--dim); margin: 0 0 28px; }
  h2 {
    font-size: 17px; font-weight: 600; margin: 32px 0 8px;
    padding-top: 20px; border-top: 1px solid var(--rule);
  }
  h2:first-of-type { border-top: 0; padding-top: 0; margin-top: 0; }
  p { font-size: 15px; line-height: 1.6; margin: 0 0 12px; }
  ul { margin: 0 0 12px; padding-left: 20px; }
  li { font-size: 15px; line-height: 1.6; margin-bottom: 6px; }
  footer { margin-top: 40px; font-size: 13px; color: var(--dim); }
  a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>Privacy Policy</h1>
  <p class="meta">OkayMessenger · Last updated: July 2026 · version 5</p>
    <h2>The short version</h2>
    <p>OkayMessenger is built to know as little about you as possible. Your messages, calls, and media are never stored on our servers. They are end-to-end encrypted, relayed live between devices, and kept only in each device’s local storage — so they disappear when you delete the app.</p>
    <h2>What we do NOT store</h2>
    <ul>
      <li>Message content — text, photos, voice notes, files, polls, payment notes.</li>
      <li>Calls — audio and video are peer-to-peer (WebRTC) and never recorded.</li>
      <li>Media — files are sent device-to-device; the bytes never touch a server.</li>
      <li>Card numbers — payments are handled by Stripe; we never see or store them.</li>
    </ul>
    <p>Messages are delivered over Supabase Realtime Broadcast, which passes them through memory only — there is no messages database, and we do not use Realtime Postgres for message content.</p>
    <h2>What we DO store</h2>
    <ul>
      <li>A username directory: your verified phone number mapped to the username you choose, so usernames are unique and reachable.</li>
      <li>Payment metadata: for money you send/receive we keep the transaction id, amount, fee, and status (never card data) to show receipts and payout status. The money itself is held by Stripe, not us.</li>
      <li>Communal data: your servers, feed posts and follows sync for everyone in a server, encrypted as ciphertext we cannot read. This is shared infrastructure — it is not part of anyone’s personal storage and costs nothing.</li>
      <li>Encrypted chat backup (only if you choose it): a single ciphertext blob of your message history, encrypted on your device with a key we never receive. This is the one thing that counts as your personal storage. You can also back up chats locally to iCloud / app storage instead.</li>
      <li>Offline message queue: when a recipient is offline, the already-end-to-end-encrypted message is briefly held as ciphertext so it can be delivered when they reconnect. It is deleted on delivery and swept within 14 days. We cannot read it.</li>
      <li>Minimal operational logs needed to run and secure the service, kept only as long as necessary and never containing message content.</li>
    </ul>
    <h2>Cloud storage (optional)</h2>
    <p>Cloud storage backs up your chat history — and only your chats — as encrypted ciphertext we cannot read. It is offered in tiers: a free allowance and paid monthly plans for more space. Your servers, posts and follows are communal and never count against this storage. You can see how much space you use, change or cancel your plan, and restore your chats on a new device with your key, all in Settings → Cloud storage. If a paid plan lapses you drop to the free tier; your last backup stays available to restore.</p>
    <h2>End-to-end encryption</h2>
    <p>Messages and call setup are encrypted on your device with keys only your devices hold (AES-256-GCM with an ECDH key exchange). The relay forwards ciphertext it cannot read.</p>
    <h2>Service providers</h2>
    <ul>
      <li>Supabase — realtime message relay and the username directory (project hosted in Canada, ca-central-1).</li>
      <li>Stripe — processes payments and holds/pays out funds under its own agreements; handles identity verification (KYC) for people who receive money.</li>
      <li>Twilio — sends the one-time SMS code that verifies your number.</li>
    </ul>
    <h2>Data retention</h2>
    <p>Message content: not stored, nothing to retain. Username directory and payment metadata: kept until you delete your account, then removed. Operational logs: kept for a short period, then rotated out.</p>
    <h2>Your rights</h2>
    <p>Under PIPEDA (Canada) and, where applicable, the GDPR (EU) you can request access to, correction of, or deletion of the limited data we hold about you, and withdraw consent. Because we don’t store your messages, there is no message history for us to hand over or delete.</p>
    <h2>Safety</h2>
    <p>You can block and report other users from their profile. Reports are confidential and help us keep the community safe. Files you attach are checked on your device before they are sent: only real image files may be sent as photos, videos cannot be uploaded, executables and scripts are refused, and known prohibited content is blocked. This check runs locally — we do not see the file — and applies before anything leaves your device.</p>
    <h2>Children</h2>
    <p>OkayMessenger is not directed to children under 13 (or the minimum age in your region), and we do not knowingly collect their information.</p>
    <h2>Contact</h2>
    <p>Questions about privacy? Reach us at privacy@okay.chat.</p>
  <footer>The same text is shown inside the app, under Settings &rarr; About.</footer>
</main>
</body>
</html>
`;

export const TERMS_HTML = `<!DOCTYPE html>
<!--
  GENERATED — do not edit by hand.
  Source: lib/legal/legal_content.dart · regenerate: dart tool/build_legal_pages.dart
-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Terms of Service · OkayMessenger</title>
<style>
  :root { color-scheme: light dark; --fg: #1a1c1e; --dim: #5f6368; --bg: #ffffff; --rule: #e3e5e8; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e8eaed; --dim: #9aa0a6; --bg: #121417; --rule: #2a2d31; }
  }
  html, body { margin: 0; background: var(--bg); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--fg); padding: 28px 20px 64px; box-sizing: border-box;
    -webkit-text-size-adjust: 100%;
  }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 24px; margin: 0 0 4px; font-weight: 700; letter-spacing: -0.2px; }
  .meta { font-size: 13px; color: var(--dim); margin: 0 0 28px; }
  h2 {
    font-size: 17px; font-weight: 600; margin: 32px 0 8px;
    padding-top: 20px; border-top: 1px solid var(--rule);
  }
  h2:first-of-type { border-top: 0; padding-top: 0; margin-top: 0; }
  p { font-size: 15px; line-height: 1.6; margin: 0 0 12px; }
  ul { margin: 0 0 12px; padding-left: 20px; }
  li { font-size: 15px; line-height: 1.6; margin-bottom: 6px; }
  footer { margin-top: 40px; font-size: 13px; color: var(--dim); }
  a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>Terms of Service</h1>
  <p class="meta">OkayMessenger · Last updated: July 2026 · version 5</p>
    <h2>Acceptance</h2>
    <p>By using OkayMessenger you agree to these Terms. If you don’t agree, please don’t use the app.</p>
    <h2>The service</h2>
    <p>OkayMessenger is a private, local-first messenger. You are responsible for the content you send and for keeping your device secure. Because messages are stored only on devices, keep your own backups if you want to preserve them.</p>
    <h2>Payments</h2>
    <p>Peer-to-peer payments — money you send to or receive from another person in a chat — are processed by Stripe, and only these use Stripe. When you send or receive money you agree to the Stripe Connected Account Agreement and Stripe’s terms. OkayMessenger is not a bank or money-services business, does not hold your funds, and never takes custody of the money — funds move from the sender’s card through Stripe to the recipient’s Stripe account and are paid out to their bank by Stripe. We charge a small application fee per transaction, shown before you pay. You are responsible for any taxes on money you receive. Digital purchases — the cloud-storage subscription and tips to the developer — are billed by the App Store instead, not Stripe.</p>
    <h2>Cloud storage subscription</h2>
    <p>Cloud storage backs up your chats. You get a free allowance, and can buy more space monthly — choose the amount you want, up to a maximum of 100 GB. There is no unlimited option. Paid storage is billed through your App Store account (Apple) at the price shown before you buy — not through Stripe. Subscriptions renew and can be managed, changed, or cancelled in your App Store settings. Each paid purchase adds 30 days and stacks on any time remaining; it does not auto-renew silently — you confirm each renewal. Your servers and posts are communal and never count against your storage. Fair use: downloads (egress) are limited to roughly three times your stored amount per month; sustained excess may be throttled. You can view usage and change or cancel your plan anytime in Settings → Cloud storage; cancelling drops you to the free tier and is not refundable for the current period. Fees and limits may change on notice.</p>
    <h2>Acceptable use</h2>
    <p>Don’t use OkayMessenger to break the law, harass others, send spam, infringe rights, or transmit malware. Files you attach are moderated on your device before sending: only genuine image files may be sent as photos, videos cannot be uploaded, executables and scripts are refused, oversized files are blocked, and known prohibited content is refused outright. Attempting to bypass these checks, or uploading unlawful content, is a violation of these Terms. We may limit or end access that violates these Terms. Use the in-app block and report tools if someone is abusing the service.</p>
    <h2>No warranty</h2>
    <p>The app is provided “as is” without warranties of any kind. Message delivery depends on both devices being online at the same time; we don’t guarantee delivery, since nothing is stored to retry later.</p>
    <h2>Limitation of liability</h2>
    <p>To the extent permitted by law, OkayMessenger is not liable for indirect or consequential damages arising from your use of the app.</p>
    <h2>Changes</h2>
    <p>We may update these Terms; continued use after an update means you accept the new Terms.</p>
    <h2>Governing law</h2>
    <p>These Terms are governed by the laws of Canada and your province of residence.</p>
    <h2>Contact</h2>
    <p>Questions about these Terms? Reach us at legal@okay.chat.</p>
  <footer>The same text is shown inside the app, under Settings &rarr; About.</footer>
</main>
</body>
</html>
`;
