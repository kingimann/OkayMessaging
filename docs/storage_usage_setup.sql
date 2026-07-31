-- Server-side storage accounting for Okay Messaging's paid chat backup.
-- ============================================================================
-- OPTIONAL. Run this AFTER docs/supabase_setup.sql, in the Supabase dashboard
-- (SQL Editor -> New query -> paste -> Run). It adds:
--
--   1. per-account storage accounting (bytes used), maintained automatically
--      by a trigger as chat/communal blobs are written and deleted;
--   2. monthly egress accounting with a fair-use ceiling (1x stored bytes);
--   3. a totals view so you can watch the whole project against your plan's
--      included storage (e.g. a $25 Supabase Pro project = 100 GB / 250 GB
--      egress) and know when to raise prices or archive cold data.
--
-- PRIVACY / TRUST NOTE. To attribute usage to a person we group a person's
-- blobs by an `account` tag the client sends. This tag is an HMAC of the phone
-- number under a FIXED app label (NOT the encryption key), so:
--   * it is stable across passphrase changes (usage survives a re-key), and
--   * it still reveals nothing about the number to anyone reading the table.
-- It DOES let the server see how many blobs and how many bytes one account
-- holds — a deliberate, minimal trade for being able to meter a paid plan.
-- Blob CONTENTS remain end-to-end-encrypted ciphertext the server can't read.
--
-- ENFORCEMENT NOTE. This project has no server-side auth (REQUIRE_OTP is off),
-- so RLS cannot bind a row to a verified caller: anyone with the publishable
-- key could in principle write any account's usage row. The accounting here is
-- therefore ACCURATE (the trigger derives bytes from the real blobs) but the
-- egress ceiling is ADVISORY until you add auth. Treat egress_over_limit() as
-- a signal to throttle in your Edge Function / gateway, not a hard gate.

-- ----------------------------------------------------------------------------
-- 1. Tag each blob with the account that owns it.
-- ----------------------------------------------------------------------------
-- Nullable, so existing rows and any client that hasn't been updated keep
-- working. Usage is only metered for rows that carry a tag.
alter table public.sync_blobs
  add column if not exists account text;

create index if not exists sync_blobs_account_idx
  on public.sync_blobs (account);

-- ----------------------------------------------------------------------------
-- 2. Per-account usage, kept current by a trigger.
-- ----------------------------------------------------------------------------
create table if not exists public.user_storage_usage (
  account      text primary key,
  used_bytes   bigint      not null default 0,
  tier         text        not null default 'free',
  egress_bytes bigint      not null default 0,
  period_start timestamptz not null default date_trunc('month', now()),
  updated_at   timestamptz not null default now()
);

alter table public.user_storage_usage enable row level security;

-- Readable/writable with the app key (see ENFORCEMENT NOTE above).
drop policy if exists usage_select on public.user_storage_usage;
create policy usage_select on public.user_storage_usage
  for select to anon, authenticated using (true);
drop policy if exists usage_upsert on public.user_storage_usage;
create policy usage_upsert on public.user_storage_usage
  for insert to anon, authenticated with check (true);
drop policy if exists usage_update on public.user_storage_usage;
create policy usage_update on public.user_storage_usage
  for update to anon, authenticated using (true);

-- Recompute an account's stored bytes from the real blobs — the source of
-- truth is always the sum of what's actually there, so the number can't drift.
create or replace function public.recompute_account_usage(acct text)
returns void language plpgsql as $$
begin
  if acct is null then
    return;
  end if;
  insert into public.user_storage_usage (account, used_bytes, updated_at)
  values (
    acct,
    coalesce((select sum(octet_length(data)) from public.sync_blobs
              where account = acct), 0),
    now()
  )
  on conflict (account) do update
    set used_bytes = excluded.used_bytes,
        updated_at = now();
end $$;

-- Fire on every write/delete of a tagged blob, for the affected account(s).
create or replace function public.sync_blobs_usage_trigger()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_account_usage(old.account);
    return old;
  end if;
  perform public.recompute_account_usage(new.account);
  -- An UPDATE that moved a blob between accounts must fix the old one too.
  if tg_op = 'UPDATE' and new.account is distinct from old.account then
    perform public.recompute_account_usage(old.account);
  end if;
  return new;
end $$;

drop trigger if exists sync_blobs_usage on public.sync_blobs;
create trigger sync_blobs_usage
  after insert or update or delete on public.sync_blobs
  for each row execute function public.sync_blobs_usage_trigger();

-- ----------------------------------------------------------------------------
-- 3. Monthly egress accounting with a fair-use ceiling.
-- ----------------------------------------------------------------------------
-- Call this from wherever you serve a restore/download, passing the bytes sent.
-- It rolls the counter over at the start of each month automatically.
create or replace function public.record_egress(acct text, bytes bigint)
returns void language plpgsql as $$
begin
  if acct is null or bytes is null or bytes <= 0 then
    return;
  end if;
  insert into public.user_storage_usage (account, egress_bytes, period_start, updated_at)
  values (acct, bytes, date_trunc('month', now()), now())
  on conflict (account) do update set
    egress_bytes = case
      when public.user_storage_usage.period_start < date_trunc('month', now())
        then bytes                                            -- new month, reset
      else public.user_storage_usage.egress_bytes + bytes end,
    period_start = greatest(public.user_storage_usage.period_start,
                            date_trunc('month', now())),
    updated_at = now();
end $$;

-- Fair use: downloads are limited to ~1x what you store, per month. Returns
-- true once an account is over — your gateway/Edge Function should then
-- throttle further downloads for the rest of the period.
create or replace function public.egress_over_limit(acct text)
returns boolean language sql stable as $$
  select coalesce(
    (select egress_bytes > 1 * greatest(used_bytes, 1)
       from public.user_storage_usage
      where account = acct
        and period_start >= date_trunc('month', now())),
    false);
$$;

-- ----------------------------------------------------------------------------
-- 4. Project totals — watch the whole thing against your plan's ceiling.
-- ----------------------------------------------------------------------------
-- e.g. a $25 Supabase Pro project includes 100 GB storage / 250 GB egress.
-- When total_used_bytes nears ~80 GB, raise prices or archive cold blobs.
--
-- security_invoker, and granted to NOBODY — see the note on
-- chat_backup_totals. Without it the view runs as its owner and hands every
-- account's usage to any client that asks; Supabase's advisor flags it
-- CRITICAL, and it is right to.
create or replace view public.storage_totals
with (security_invoker = on) as
  select
    count(*)                                    as accounts,
    count(*) filter (where tier = 'free')       as free_accounts,
    coalesce(sum(used_bytes), 0)                as total_used_bytes,
    coalesce(sum(egress_bytes), 0)              as total_egress_bytes_this_month
  from public.user_storage_usage;

revoke all on public.storage_totals from anon, authenticated;
