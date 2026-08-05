# Lawful requests: what this service can and cannot produce

*For the operator and their counsel. Not legal advice — jurisdiction and
process type (subpoena, warrant, preservation order, wiretap-style order)
change what applies. This document describes the **technical facts**: what
data exists, where, and for how long. A test suite pins parts of it against
the schema, so a feature that adds server-side data is supposed to fail a
check until this document is updated.*

Last reviewed: 2026-08-05 (the day the follows graph was added).

## The one-sentence summary

The service can produce **identity, metadata, and everything public**, and
cannot produce **message content, call content, or private media** — those
are end-to-end encrypted on the phones, and no readable copy ever exists
server-side.

## 1. What exists on the server and CAN be produced

### Identity
- **Directory (`usernames`)** — phone number ⇄ username ⇄ display name,
  plus a phone hash and update timestamps. Answers "who is @handle" and
  "what handles does this number hold."
- **Verified identity (Stripe Identity)** — for blue-check accounts: the
  verification verdict and the verified **legal name**; the ID documents
  themselves are held at Stripe, tied to this platform, and reachable by
  legal process to Stripe.
- **Email addresses** — where a user added one for recovery, with its
  verified state.
- **Push tokens (`push_tokens`)** — device tokens per phone number; ties an
  account to a physical device via Apple.
- **Auth records and API logs** — Supabase holds sign-in events, request
  logs, and **IP addresses** under its own retention.

### Message metadata (not content)
- **Store-and-forward mailbox (`mailbox`)** — for each queued envelope: the
  recipient's inbox, a timestamp, and the ciphertext size. **Sealed sender
  (added 2026-08-05): between up-to-date builds the sender's number is no
  longer on the envelope at all** — such rows say only that *someone* wrote
  to a number. Envelopes from older builds, and the first messages of any
  new pairing, still carry the sender's number outside the ciphertext for
  routing. Rows are deleted on delivery and swept after **14 days**, so
  this is a sliding window, not a history.
- **Live relay (Realtime broadcast)** — not stored at all. There is no
  historical who-talked-to-whom log. A court could, however, compel
  **prospective** logging of channel metadata going forward; the channel
  names are `inbox_<digits>`, so such logging would reveal who contacts
  whom and when — never what was said.

### The social graph (added 2026-08-05)
- **Follows (`public_follows`)** — who follows whom, stored as phone
  numbers on both ends. Clients only ever see usernames, but the operator
  (and therefore legal process) can read the table itself.

### Everything public, in full
- **Public newsfeed (`public_posts` + `public-media` bucket)** — post text,
  images, and videos in plaintext, with the **author's phone number** in
  the table (clients see only usernames), likes with liker phones, poll
  votes with voter phones, view tallies, and reports.
- **Marketplace/report/moderation records** — reports (reporter and target
  phones, reason, free-text context — deliberately never message content),
  sanctions, role grants, and the moderation log.

### Payments — the richest identity data
- **Stripe Connect** — verified legal names, bank/card details (at
  Stripe), and the full **peer-to-peer transfer history**: who paid whom,
  amounts, timestamps, fees, payouts. Both this platform's tables and
  Stripe's records answer here.
- **Apple IAP** — subscription and tip purchases, under Apple's records.

### Encrypted blobs the operator holds
- Chat backups, cloud sync, sealed community posts and listing media,
  voice notes: **ciphertext only** — with one critical exception.
  **Cloud-sync/backup data protected by the default phone-derived key is
  effectively readable by anyone who knows the phone number, including the
  operator under compulsion.** Only passphrase-protected backups are
  genuinely beyond reach. Counsel should treat phone-derived-key backups
  as producible.

## 2. What CANNOT be produced, under any process

- **Message content** — 1:1, group, and server-community messages are
  encrypted on the sending phone (Signal Double Ratchet pairwise, Sender
  Keys for the community bus); the relay forwards ciphertext it cannot
  read, and the mailbox holds the same sealed envelopes.
- **Call audio and video** — DTLS-SRTP between the phones; the TURN relay
  moves encrypted packets.
- **Form answers, private photos, voice notes, files** — sealed inside the
  same envelopes as messages.
- **Chat lists, contact books, notes, quick replies, hidden chats** —
  never leave the device.
- **Who viewed a post** — deliberately a bare counter; no per-viewer rows
  exist to produce.
- **Keys** — identity keys, ratchet sessions, and sender chains live in
  the phones' keychains and nowhere else.

## 3. Third parties who hold their own records about users

| Party | What they hold |
|---|---|
| Stripe | Legal identity, ID documents, cards/banks, transfer history |
| Apple | Push metadata (notification titles carry sender names), IAP, TestFlight |
| Supabase | Hosting: API logs, IPs, auth events, all tables above |
| Metered.ca (TURN) | Call participants' IP addresses and session timing |
| Google AdMob | Ad requests from public surfaces (configured non-personalized) |

## 4. Retention that matters

- Mailbox envelopes: deleted on delivery; swept at 14 days.
- Realtime traffic: never stored.
- Public posts, follows, directory, payments: kept until user deletion.
- Delete account: removes the directory row, tokens, and server rows the
  function reaches; Stripe and Apple retain under their own policies.

## 5. Practical notes for a request

1. Identify the account: a handle resolves via `usernames`; a phone number
   is the primary key almost everywhere.
2. Content requests can only be answered with the facts in §2 — there is
   nothing to decrypt server-side; the service does not hold the keys.
3. Preservation orders can freeze what exists (§1) but cannot resurrect
   the mailbox's swept window or unlogged Realtime traffic.
4. Prospective surveillance (compelled logging) is technically possible
   for **metadata only** — flag this scenario to counsel before it
   arrives.
5. The in-app transparency page (Settings → Privacy & security →
   "What the server can see") is the user-facing version of this
   document; keep the two consistent.
