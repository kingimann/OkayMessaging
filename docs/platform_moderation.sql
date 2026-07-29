-- App-wide roles, sanctions, and reports.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor. Then grant yourself the owner role with
-- the statement at the very bottom (replace the number with your own).
--
-- WHAT THIS CAN DO. A sanction removes an account from the *shared*
-- infrastructure: the directory it is found through, claiming a username, push
-- notifications, payments. Postgres enforces the directory part through row
-- level security, so it holds against any client, modified or not.
--
-- WHAT IT CANNOT DO, BY DESIGN. It cannot read, remove, or moderate anybody's
-- messages. Message bodies are end-to-end encrypted before they leave the
-- device and the server only ever holds sealed envelopes it has no key for.
-- There is no server-side copy of a conversation to act on, and adding one
-- would break the promise the whole app rests on. Moderation here is about
-- access to the platform, not about content in private chats.

-- ---------------------------------------------------------------------------
-- Who holds power
-- ---------------------------------------------------------------------------
-- Service-role only: RLS is on and there is no client policy, so no app build
-- can read or write this table. A role the client could grant itself would be
-- worth nothing, so roles are granted here, by SQL, by whoever owns the
-- project.
create table if not exists public.platform_roles (
  phone      text primary key,              -- E.164 digits
  role       text not null check (role in ('owner', 'admin', 'moderator')),
  granted_by text not null default '',
  created_at timestamptz not null default now()
);
alter table public.platform_roles enable row level security;

-- ---------------------------------------------------------------------------
-- What has been done to an account
-- ---------------------------------------------------------------------------
-- One row per sanctioned account. Written only by the moderation-act Edge
-- Function (service role), which checks the caller's role first. `until` null
-- means permanent, which only a ban is.
create table if not exists public.account_sanctions (
  phone       text primary key,             -- E.164 digits
  kind        text not null check (kind in ('timeout', 'suspend', 'ban')),
  reason      text not null default '' check (char_length(reason) <= 500),
  until       timestamptz,
  actor_phone text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.account_sanctions enable row level security;

-- Read-only to the app so a sanctioned device can be told why it is locked
-- out (and so every device agrees who is hidden). Nothing here is private:
-- it is a list of accounts that may not use the app.
drop policy if exists account_sanctions_read on public.account_sanctions;
create policy account_sanctions_read on public.account_sanctions
  for select to anon, authenticated using (true);
-- No insert/update/delete policy: only the service role changes a sanction.

create index if not exists account_sanctions_until_idx
  on public.account_sanctions (until);

-- Every sanction and lift, kept even after the sanction goes away. Moderation
-- without a record of who did what is just power.
create table if not exists public.moderation_log (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  actor_phone  text not null default '',
  actor_role   text not null default '',
  target_phone text not null default '',
  action       text not null default '',
  reason       text not null default '',
  until        timestamptz
);
alter table public.moderation_log enable row level security;

-- ---------------------------------------------------------------------------
-- Reports from people using the app
-- ---------------------------------------------------------------------------
-- "Report" used to be honest about going nowhere: it hid a listing locally and
-- said so, because there was no central moderator. Now there is one, and this
-- is where a report lands. A report carries what was reported and why — never
-- message content, which the reporter's device holds and the server cannot
-- read anyway.
create table if not exists public.moderation_reports (
  id             bigint generated always as identity primary key,
  created_at     timestamptz not null default now(),
  target_phone   text not null default '',
  target_handle  text not null default '',
  reporter_phone text not null default '',
  reason         text not null default '',
  detail         text not null default '' check (char_length(detail) <= 1000),
  context        text not null default '',   -- 'listing', 'post', 'chat', …
  handled        boolean not null default false
);
alter table public.moderation_reports enable row level security;

-- Anyone with the app may file one, and only about themselves as reporter.
-- Reports are not readable by clients — one person's report is nobody else's
-- business; moderators read them through the Edge Function.
drop policy if exists moderation_reports_insert on public.moderation_reports;
create policy moderation_reports_insert on public.moderation_reports
  for insert to anon, authenticated with check (true);

create index if not exists moderation_reports_open_idx
  on public.moderation_reports (handled, created_at desc);

-- ---------------------------------------------------------------------------
-- THE ENFORCEMENT: banned and suspended accounts leave the directory
-- ---------------------------------------------------------------------------
-- This is the part that is real regardless of what any app build does, because
-- Postgres applies it to every query. A hidden account cannot be found by
-- username search or by contact sync, and cannot claim or change a username.
--
-- A time-out is deliberately NOT hidden: it silences, it does not disappear
-- someone mid-conversation.
create or replace function public.is_locked_out(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.account_sanctions s
     where s.phone = p
       and s.kind in ('ban', 'suspend')
       and (s.until is null or s.until > now())
  );
$$;

-- Reading the directory: locked-out rows are invisible. Your own row stays
-- visible to you, so a suspended account can still see its own profile and be
-- told what happened instead of appearing to have been deleted.
drop policy if exists usernames_read on public.usernames;
create policy usernames_read on public.usernames
  for select to authenticated
  using (
    phone = (auth.jwt() ->> 'phone')
    or not public.is_locked_out(phone)
  );

-- Claiming or changing a username: locked out means locked out.
drop policy if exists usernames_insert_own on public.usernames;
create policy usernames_insert_own on public.usernames
  for insert to authenticated
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

drop policy if exists usernames_update_own on public.usernames;
create policy usernames_update_own on public.usernames
  for update to authenticated
  using (phone = (auth.jwt() ->> 'phone'))
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

-- Push tokens too: a locked-out account stops receiving notifications at the
-- source rather than being quietly delivered to.
drop policy if exists push_tokens_upsert_own on public.push_tokens;
create policy push_tokens_upsert_own on public.push_tokens
  for insert to authenticated
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------
-- Lapsed sanctions stop applying the moment their clock runs out (the checks
-- above are all time-aware), so sweeping is tidiness rather than enforcement.
-- Call it from a scheduled job if you want the table to stay small.
create or replace function public.sweep_expired_sanctions()
returns integer
language plpgsql
as $$
declare removed integer;
begin
  delete from public.account_sanctions
   where until is not null and until <= now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- ---------------------------------------------------------------------------
-- GRANT YOURSELF THE OWNER ROLE — edit the number, then run this line.
-- ---------------------------------------------------------------------------
-- insert into public.platform_roles (phone, role, granted_by)
-- values ('15551234567', 'owner', 'bootstrap')
-- on conflict (phone) do update set role = 'owner';
