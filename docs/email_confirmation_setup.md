# Email confirmation links

Attaching an email to an account calls Supabase's `updateUser`, which sends a
confirmation email. Clicking that link used to land on
`http://localhost:3000` and fail.

## Why

`updateUser` with no `emailRedirectTo` sends people to the project's **Site
URL**, and a new Supabase project ships with that set to
`http://localhost:3000` — the address of a dev server on the developer's own
machine, which does not exist on the reader's phone.

The app now passes the redirect explicitly (`AccountEmail.emailRedirectUrl`,
overridable with `--dart-define=EMAIL_REDIRECT_URL=…`). That is not enough on
its own: **Supabase ignores any redirect that isn't on the allow-list and
falls back to the Site URL.** Both settings have to change.

## What to set

[Auth → URL Configuration](https://supabase.com/dashboard/project/trbdqucphtsstnrwwfnw/auth/url-configuration)

| Field | Value |
|---|---|
| Site URL | `https://kingimann.github.io/OkayMessaging/` |
| Redirect URLs | `https://kingimann.github.io/OkayMessaging/**` |

The `**` wildcard covers `email-confirmed.html` and anything added later. A
single exact URL works too, and has to be updated every time a page is added.

## Where the link lands

`web/email-confirmed.html` — a static page that says the address is confirmed
and to go back to the app. Deliberately not the Flutter app: the confirmation
already happened on Supabase's side before the browser arrives, so loading a
five-megabyte bundle to print one sentence would only be slower and would show
a sign-in screen to somebody already signed in on their phone.

If the link has expired or was already used, Supabase says so in the URL
fragment and the page shows that instead of claiming success.

## How the app finds out

The link opens in a browser, usually not even on the same device, so nothing
pushes the result back. `AccountEmail.refreshVerification()` asks the server
(`auth.getUser()`, not the cached session) and runs on launch and whenever the
Email screen is opened. Reading the cached session was the old behaviour and
meant a confirmed address kept reading "Not confirmed yet" indefinitely.

## Checking it

Add an address in the app, open the email, click the link. You should get the
confirmation page rather than a browser error. Back in the app, the Email
screen should show **Confirmed** — reopen the screen if it was already up.

## Signing in with email or username

The login screen's "Sign in with username or email" needs two Supabase
settings to work for the email half:

1. **Auth → Providers → Email: enabled.** Sign-ups stay off through the app
   (`shouldCreateUser: false` — email is a door back to a phone account, not
   a substitute identity).
2. **Auth → Email Templates → Magic Link: include the code.** The default
   template only carries a link. The app asks for a 6-digit code, which is
   `{{ .Token }}` — add a line like:

   ```html
   <p>Your OkayMessenger sign-in code is: {{ .Token }}</p>
   ```

Email login only works for accounts that added and confirmed an email in
Settings first; the session it opens still carries the account's phone,
which remains the identity everywhere else.

Username login needs no setup at all: the username locates the account in
the directory, and the SMS code to its (masked) phone stays the proof of
ownership.
