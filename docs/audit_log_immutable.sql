-- ---------------------------------------------------------------------------
-- The moderation audit trail becomes APPEND-ONLY, and tamper-EVIDENT
-- ---------------------------------------------------------------------------
-- Run after docs/platform_moderation.sql, which creates `moderation_log`.
-- Safe to run twice.
--
-- `moderation_log` has recorded every sanction, takedown and role change since
-- the console existed, and RLS with no policies at all already kept every
-- client out of it. What it never had was any defence against the one party
-- that can actually reach it: whoever holds the service-role key. A log the
-- operator can quietly rewrite is a log that says whatever the operator needs
-- it to have said, and that is the only threat model an audit trail exists for
-- — nobody keeps one to defend against a stranger who cannot see the table.
--
-- Two separate things, and the difference matters:
--
--   * APPEND-ONLY is prevention. A BEFORE UPDATE OR DELETE trigger raises, and
--     a trigger binds every role — the table owner and the service role
--     included, unlike a GRANT, which the owner is exempt from, or RLS, which
--     BYPASSRLS skips. This is why it is a trigger and not a revoke.
--
--   * The HASH CHAIN is detection, and it is what makes the word "immutable"
--     checkable instead of merely asserted. Each row carries the hash of the
--     one before it, so removing or editing any row breaks every hash after it
--     and `moderation_log_verify()` names the first entry that stopped adding
--     up. Prevention alone would be a promise; this is the evidence.
--
-- Honest about the ceiling, rather than letting the word "immutable" carry
-- more than it earns:
--   * A superuser can `alter table … disable trigger` or drop it outright.
--     That cannot be prevented from inside the database by anything short of
--     shipping the rows off it. What it is instead is a DELIBERATE, VISIBLE
--     act that leaves the chain broken behind it — which is the whole point
--     of pairing prevention with detection.
--   * It covers MODERATION ACTIONS. It is not an access log and not a data
--     log: it does not record who read a report or who opened the console.
--   * Detection needs somebody to look. The console's History tab runs the
--     check when it loads, so the answer is in front of the person who would
--     care rather than waiting for a query nobody runs.

-- ---------------------------------------------------------------------------
-- No client reaches this table, spelled out rather than left to RLS
-- ---------------------------------------------------------------------------
-- The table has RLS on and no policies, so a client already selects nothing.
-- The revoke is belt as well as braces, and this codebase has been burned
-- twice by the reason: Supabase grants table-wide privileges on every NEW
-- table in `public` to `anon` and `authenticated` by default (see
-- docs/community_structure.sql, where four tables quietly carried full CRUD
-- for anon, and docs/directory_phone_privacy.sql, where `revoke … from public`
-- did not revoke `anon`). A raw grant sitting unused is a hole waiting for the
-- day somebody adds a policy. Name the roles.
revoke all on table public.moderation_log from anon, authenticated;

-- ---------------------------------------------------------------------------
-- The chain columns
-- ---------------------------------------------------------------------------
-- Nullable, and filled by the trigger — never by the writer. `moderation-act`
-- and `roles-set` insert without naming them and must keep working unchanged;
-- more to the point, a hash the INSERTER supplies is a hash the inserter can
-- forge, which would make the chain decorative.
alter table public.moderation_log
  add column if not exists prev_hash text,
  add column if not exists row_hash  text;

-- The payload a row's hash is taken over: every field that carries meaning,
-- plus the link to the row before it. `id` and `created_at` are in it so a row
-- cannot be moved or re-timed without breaking, and `prev_hash` is what turns
-- a list of independent hashes into a chain.
--
-- IMMUTABLE and taking only the values (not the row type) so the verify pass
-- and the insert trigger cannot drift into hashing two different things —
-- there is one definition of what a row's hash is.
create or replace function public.moderation_log_hash(
  p_prev text, p_id bigint, p_created timestamptz, p_actor_phone text,
  p_actor_role text, p_target_phone text, p_action text, p_reason text,
  p_until timestamptz)
returns text language sql immutable as $$
  select encode(
    sha256(convert_to(
      coalesce(p_prev, '') || '|' ||
      p_id::text || '|' ||
      -- A fixed offset, so the same instant hashes the same regardless of
      -- what TimeZone the session that reads it happens to be set to.
      to_char(p_created at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.USOF') || '|' ||
      coalesce(p_actor_phone, '')  || '|' ||
      coalesce(p_actor_role, '')   || '|' ||
      coalesce(p_target_phone, '') || '|' ||
      coalesce(p_action, '')       || '|' ||
      coalesce(p_reason, '')       || '|' ||
      coalesce(to_char(p_until at time zone 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.USOF'), ''),
      'UTF8')),
    'hex');
$$;

-- ---------------------------------------------------------------------------
-- Append: link the new row to the last one
-- ---------------------------------------------------------------------------
-- The advisory lock serialises appends. Two moderators acting in the same
-- instant would otherwise both read the same tail and both claim it as their
-- predecessor, forking the chain — which reads exactly like tampering. It is
-- held to the end of the transaction, so a second appender waits for the first
-- to commit and then sees it; a rollback burns an identity value and leaves no
-- row, which the chain does not care about since it walks committed rows.
-- Moderation is a handful of actions a day, so the lock costs nothing.
create or replace function public.moderation_log_append()
returns trigger language plpgsql as $$
declare
  last_hash text;
begin
  perform pg_advisory_xact_lock(hashtext('moderation_log_chain'));
  select l.row_hash into last_hash
    from public.moderation_log l
    order by l.id desc
    limit 1;

  new.prev_hash := last_hash;
  new.row_hash := public.moderation_log_hash(
    last_hash, new.id, new.created_at, new.actor_phone, new.actor_role,
    new.target_phone, new.action, new.reason, new.until);
  return new;
end $$;

drop trigger if exists moderation_log_append on public.moderation_log;
create trigger moderation_log_append
  before insert on public.moderation_log
  for each row execute function public.moderation_log_append();

-- ---------------------------------------------------------------------------
-- Append-only: nothing is ever edited or removed
-- ---------------------------------------------------------------------------
-- Deliberately one trigger for both verbs and one message. There is no
-- legitimate UPDATE on this table either — a correction is a new entry saying
-- what was corrected, which is what an audit trail IS.
create or replace function public.moderation_log_immutable()
returns trigger language plpgsql as $$
begin
  raise exception
    'moderation_log is append-only: entries cannot be % (%)',
    lower(tg_op), 'audit trail';
end $$;

drop trigger if exists moderation_log_no_update on public.moderation_log;
create trigger moderation_log_no_update
  before update on public.moderation_log
  for each row execute function public.moderation_log_immutable();

drop trigger if exists moderation_log_no_delete on public.moderation_log;
create trigger moderation_log_no_delete
  before delete on public.moderation_log
  for each row execute function public.moderation_log_immutable();

-- ---------------------------------------------------------------------------
-- Backfill, for a project whose log predates the chain
-- ---------------------------------------------------------------------------
-- Rows written before this file ran have no hashes, so they get them now, in
-- id order. Said plainly because it is a real limit and not a small one:
-- hashing an existing row proves nothing about whether it was already
-- altered — the chain can only vouch for what happens AFTER it is laid down.
-- What the backfill buys is that the old entries cannot be quietly changed
-- from here on, and that the chain is continuous rather than starting mid-log.
--
-- The no-update trigger is disabled for the backfill: this is the one write to
-- this table that is legitimate, it happens exactly once, inside this
-- migration, and only for rows that have no hash yet.
do $$
declare
  r record;
  last_hash text;
  filled int := 0;
begin
  if not exists (select 1 from public.moderation_log where row_hash is null) then
    return;
  end if;

  alter table public.moderation_log disable trigger moderation_log_no_update;

  select l.row_hash into last_hash
    from public.moderation_log l
    where l.row_hash is not null
    order by l.id desc
    limit 1;

  for r in
    select * from public.moderation_log where row_hash is null order by id
  loop
    update public.moderation_log
       set prev_hash = last_hash,
           row_hash = public.moderation_log_hash(
             last_hash, r.id, r.created_at, r.actor_phone, r.actor_role,
             r.target_phone, r.action, r.reason, r.until)
     where id = r.id;
    last_hash := public.moderation_log_hash(
      last_hash, r.id, r.created_at, r.actor_phone, r.actor_role,
      r.target_phone, r.action, r.reason, r.until);
    filled := filled + 1;
  end loop;

  alter table public.moderation_log enable trigger moderation_log_no_update;
  raise notice 'moderation_log: hashed % existing entries', filled;
end $$;

-- ---------------------------------------------------------------------------
-- Verify: what makes "immutable" a claim somebody can check
-- ---------------------------------------------------------------------------
-- Walks the log in order and recomputes each hash. Returns one row:
--   ok       — the whole chain adds up
--   entries  — how many were checked, so "ok" over an emptied table is not
--              mistaken for a clean bill of health
--   broken_id / detail — the FIRST entry that does not, and why
--
-- The first break is what is reported rather than every mismatch, because one
-- altered row breaks every hash after it: a list of two hundred "failures"
-- from one edit would bury the one that matters.
--
-- Not SECURITY DEFINER, deliberately. It reads a table under RLS with no
-- policies, so an invoker function returns nothing to a client even if the
-- EXECUTE grant were somehow reachable — the caller has to be the service
-- role, which is what the Edge Function is. A definer here would build a door
-- into the log that only exists because the verifier needed one.
create or replace function public.moderation_log_verify()
returns table (ok boolean, entries bigint, broken_id bigint, detail text)
language plpgsql as $$
declare
  r record;
  last_hash text;
  want text;
  n bigint := 0;
begin
  for r in select * from public.moderation_log order by id loop
    n := n + 1;
    if r.row_hash is null then
      return query select false, n, r.id, 'entry has no hash'::text;
      return;
    end if;
    if coalesce(r.prev_hash, '') is distinct from coalesce(last_hash, '') then
      return query select false, n, r.id,
        'entry does not follow the one before it'::text;
      return;
    end if;
    want := public.moderation_log_hash(
      last_hash, r.id, r.created_at, r.actor_phone, r.actor_role,
      r.target_phone, r.action, r.reason, r.until);
    if want is distinct from r.row_hash then
      return query select false, n, r.id, 'entry has been altered'::text;
      return;
    end if;
    last_hash := r.row_hash;
  end loop;
  return query select true, n, null::bigint, ''::text;
end $$;

-- No client calls this — the console asks the Edge Function, which is the
-- service role.
--
-- PUBLIC is named as well as the two client roles, and that is not padding:
-- a new function is granted EXECUTE to PUBLIC by Postgres itself, and `anon`
-- holds it through that membership as well as through Supabase's own default
-- privileges. Revoking one and not the other leaves the function callable —
-- the mirror of the `find_people_by_hashes` bug in
-- docs/directory_phone_privacy.sql, where revoking PUBLIC left the explicit
-- anon grant standing. Both ends, or neither works.
revoke all on function public.moderation_log_verify()
  from public, anon, authenticated;
revoke all on function public.moderation_log_hash(
  text, bigint, timestamptz, text, text, text, text, text, timestamptz)
  from public, anon, authenticated;

-- …and give it back to the one caller there is. Guarded because a plain
-- Postgres (the throwaway one `tool/check_sql.sh` stands up, before its
-- harness runs) has no such role.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.moderation_log_verify() to service_role;
    grant execute on function public.moderation_log_hash(
      text, bigint, timestamptz, text, text, text, text, text, timestamptz)
      to service_role;
  end if;
end $$;
