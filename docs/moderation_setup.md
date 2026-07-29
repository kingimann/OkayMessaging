# App-wide moderation — setup and what it actually does

Roles above servers: **owner**, **admin**, **moderator**, and everyone else.
Admins ban and suspend; moderators time out; the owner grants roles.

## What a sanction does, and what it can't

A sanction removes an account from the **shared infrastructure**:

| | Timed out | Suspended | Banned |
|---|---|---|---|
| Can send / post / list | no | no | no |
| Found in username search & contact sync | yes | no | no |
| Can claim or change a username | no | no | no |
| Receives push | yes | no | no |
| Ends by itself | yes | yes | never |
| Chats already on the device | readable | readable | readable |

**It cannot touch anybody's messages.** Message bodies are end-to-end
encrypted before they leave the device, and the server only ever holds sealed
envelopes it has no key for. There is no server-side copy of a conversation
for a moderator to read, edit, or delete — adding one would break the promise
the whole app rests on. Moderation here is about access to the platform, not
about content inside private chats. The console says so on its own first
screen, so nobody promises a user something that can't be delivered.

The directory half is enforced by **row level security**, so it holds against
any client, modified or not: Postgres itself refuses to return a locked-out
row and refuses that account's username writes. The rest (the composer, the
sanction banner) is the app cooperating — real because the account has
already lost the infrastructure it needs.

## Setup

1. **Run the migration.** `docs/platform_moderation.sql` in the Supabase SQL
   editor. It creates `platform_roles`, `account_sanctions`, `moderation_log`,
   and `moderation_reports`, and replaces the `usernames` / `push_tokens`
   policies with locked-out-aware versions.

2. **Grant yourself the owner role.** The last lines of that file, with your
   own number in E.164 digits:

   ```sql
   insert into public.platform_roles (phone, role, granted_by)
   values ('15551234567', 'owner', 'bootstrap')
   on conflict (phone) do update set role = 'owner';
   ```

   Roles are granted here and nowhere else. `platform_roles` has RLS on with
   no client policy, so no app build — including a modified one — can read or
   write who holds power. That is the point: a role the client could grant
   itself would be worth nothing.

3. **Deploy three Edge Functions** (Dashboard → Edge Functions → Deploy via
   editor). Paste-ready copies live in `docs/edge_functions_paste/`:

   - `moderation-status` — your own role and sanction
   - `moderation-act` — apply and lift sanctions
   - `moderation-queue` — reports, live sanctions, the audit log

   They need no new secrets; `SUPABASE_URL` and
   `SUPABASE_SERVICE_ROLE_KEY` are already set for the other functions.

4. **Sign out and back in** on your own device so a fresh JWT is issued, then
   open Settings — a **Moderation** section appears.

## How authority is checked

Every decision happens in `moderation-act`, against `platform_roles`, keyed on
a phone number proven by the caller's Supabase JWT (`callerPhone`). The app's
own role checks only decide which buttons to draw. The rules the server
enforces:

- moderators may time out; bans and suspensions return `needs_admin`
- you must **strictly** outrank your target — an admin cannot ban another
  admin, and nobody can act on the owner (`outranked`)
- nobody can sanction themselves (`cannot_sanction_self`)
- a ban is permanent; time-outs and suspensions require a duration

Every action, including lifts, is appended to `moderation_log` with who did
it and why. Moderation without a record of who did what is just power.

## Reports

The app's Report buttons now file into `moderation_reports` instead of only
hiding something locally — which was honest before there was a moderator to
send it to, and would be wrong now. A report carries the reason, an optional
note, and what was being looked at. It never carries message content: the
reporter's device holds that, and the server couldn't read it anyway.

Reports are insert-only for clients and readable solely through the
role-gated function — one person's report is nobody else's business.

## Housekeeping

Sanctions stop applying the moment their clock runs out; every check is
time-aware, so nothing enforces a lapsed punishment. Sweeping is tidiness
only:

```sql
select public.sweep_expired_sanctions();
```

Point a scheduled job at it if you want the table to stay small.
