# App Review: demo account + screenshots

## The demo account Apple asks for

App Review requires working login credentials when an app has a login.
This app signs in with a phone number + SMS code, so the answer is a
**test phone number with a fixed code** — no SMS is ever sent, and the
pair can be typed by a reviewer anywhere in the world:

1. Supabase dashboard → **Authentication → Sign In / Providers → Phone**.
2. Find **Test phone numbers and OTPs** and add one, e.g.:
   - Phone: `+15005550006`
   - OTP: `123456`
3. Save. That number now signs in with that code, every time, without
   sending anything.
4. In App Store Connect → App Review Information, enter:
   - Username: `+15005550006`
   - Password: `123456` (explain in the notes: "Sign in with this phone
     number; the SMS code is 123456.")

Worth adding to the review notes as well: *"Alternatively, tap 'Sign up
with a username instead' on the login screen to create an account with no
phone number at all."* Reviewers like a path with zero credentials.

The test number is a Supabase-side fixture: it exists in auth like a real
account, but it can only be signed into with the fixed code. Pick a
number in the `+1 500 555 01xx` reserved range (never real). Remove it
from the dashboard whenever you want it dead.

### What the reviewer account can do

The app recognizes `+1 500 555 0006` as the reviewer account
(`ReviewerMode`, `lib/state/reviewer_mode.dart`) and unlocks the two
doors a reviewer could never pass honestly:

- **The ID-check gate opens** — Wallet, marketplace selling, and Okay
  Drop all work without a Stripe Identity check (a reviewer will not
  photograph a passport for a demo).
- **Payments are pinned to the sandbox** — the account is permanently in
  payments test mode; every money flow simulates end-to-end and no real
  Stripe call is ever made, and the test-mode toggle cannot turn it off
  for this account. A reviewer can explore everything and can never reach
  a real charge.

If you change the test number in Supabase, change `reviewerDigits` to
match — the two must agree or the unlock silently stops applying.

## Screenshot builds (DEMO_SEED)

Release builds never show invented content — so a fresh account makes for
empty screenshots. The screenshot tool exists only in a build made for it:

1. In Codemagic, add `DEMO_SEED` = `true` to the **test** variable group.
2. Start an iOS build, install from TestFlight.
3. Settings → **Screenshot fixtures (demo build)** → *Populate demo
   content*. This fills, on this device only: several chats (pinned,
   unread, group), a call history, and a "Design Club" server with feed
   posts and two marketplace listings. Nothing is broadcast or uploaded —
   a test pins that the seeder cannot reach the network.
4. Take the screenshots.
5. *Remove demo content* undoes it (the demo chats also clear themselves
   on the next launch), and **delete the `DEMO_SEED` variable** so the
   next build — the one that goes to review — has no trace of the
   section. A test asserts the flag defaults to off.

The public newsfeed is deliberately not seeded: its posts live in a real
shared table, so fake content there would be fake for everyone. Post
something real for that screenshot.
