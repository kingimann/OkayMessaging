-- Server-authoritative call presence (2026-08-13): Phase 4 of "central
-- authority" — a durable, RLS-scoped roster for a live call, the same
-- cache-coherence backstop Phase 1/2/3 built for servers, voice channels and
-- chats.
--
-- WHY THIS EXISTS. CallSession.members has never had a ground truth beyond
-- accumulated signaling events (onRemoteJoined/onRemoteLeft) — a `left`
-- event that never arrives (a force-quit, a dropped connection) leaves that
-- peer permanently `joined` on every other device, with no sweep or
-- server-side read that could correct it. This table is that correction: a
-- durable row per (call, member) that a reconnecting device can read to
-- learn who is actually still on the call, plus a real place to enforce
-- "only someone who was actually dialed may join this call's roster."
--
-- WHAT STAYS EXACTLY AS TODAY: call SIGNALING and MEDIA. `offer`/`answer`/
-- `ice`/`end`/`decline`/`joined`/`left` all keep riding the pairwise Double
-- Ratchet/static-ECDH ladder exactly as they do now (RelayService.sendCall,
-- sealContent), and this table carries none of that traffic. Media itself
-- stays DTLS-SRTP, WebRTC's own layer, below any of this. There is no
-- sender-key/rotation concept here — this is presence bookkeeping, not a
-- broadcast key.
--
-- NO DURABLE PARENT ROW, UNLIKE community_voice_presence. A voice channel's
-- presence FKs to community_servers, whose id is a real, durable, join-gated
-- identity. A call has nothing like that: CallSession.callId is minted
-- client-side purely as a signaling correlation id
-- ('call_${peerDigits}_${epochMs}_${seq}', see CallService._newCallId) —
-- there is no "the call" row anywhere to reference, and inventing one would
-- be a bigger, unasked-for change (a durable call-log table, which
-- CallLog.dart already deliberately keeps LOCAL-ONLY — see its own doc
-- comment — and this file does not change that). So call_rosters is keyed
-- purely by call_id with no foreign key at all, and the RLS below has to
-- answer "who may touch this call's rows" from first principles rather than
-- delegating to a parent table's membership, the way every other central-
-- authority table so far has been able to.
--
-- ELIGIBILITY IS DIAL-LIST-BASED, NOT MEMBERSHIP-BASED — the real design
-- difference from every earlier central-authority table. The INITIATOR's
-- row is the one that ever carries a real `dial_phones` array (who they
-- actually rang); `call_dial_list(cid)` reads it off whichever row has a
-- non-empty one, and `is_call_eligible` is true for anyone named on that
-- list OR the initiator themselves (covering the initiator's own later
-- re-inserts/heartbeats, once their first row already exists).
--
-- THE BOOTSTRAP HOLE THIS DESIGN KNOWINGLY ACCEPTS, STATED PLAINLY. Because
-- call_id has no durable parent to gate against, the FIRST row for any
-- call_id is insertable by whoever gets there first, as long as they name
-- themselves both member and initiator. call_id is guessable within a
-- narrow window (a predictable prefix plus an epoch-millisecond timestamp
-- and a small sequence counter — see CallService._newCallId), so in
-- principle a caller could race to squat a call_id before its real
-- initiator's row lands, or invent one nobody is using. This is bounded
-- exposure, not a security hole in the call itself: the ACTUAL ringing,
-- the ACTUAL WebRTC media, and who can decrypt either are governed entirely
-- by the existing sealed pairwise signaling, which this table cannot see or
-- influence — a forged row here can at most confuse a READ of this table
-- (RelayService.fetchCallPresence, wired conservatively — see that
-- function's own doc comment for exactly how little UI trusts it), never
-- grant access to a call's audio, video, or signaling. Closing it properly
-- would need the server itself to mint call ids (a real architecture
-- change to how calls start) — a stated follow-up, not solved here.
--
-- CLEANUP IS BOTH CLIENT-SIDE (best-effort, on every real call end/decline —
-- see RelayService.leaveCallRoster's call sites in call_service.dart) AND A
-- SCHEDULED pg_cron JOB, chosen deliberately over client-side-only: a call
-- that ends by a force-quit or a dropped connection never runs any client
-- cleanup code at all, and unlike a voice channel's presence (which sweeps
-- CLIENT-SIDE off a live staleAfter clock the moment anyone opens the
-- channel screen) a call has no "someone will open this again soon" moment
-- to piggyback a sweep onto — an ended call's stale rows would otherwise sit
-- forever. This is genuinely the first use of pg_cron in this project;
-- the whole cron block below is guarded so a Postgres without the extension
-- (this repo's own throwaway-Postgres test harness, or a Supabase plan/
-- region that doesn't offer it) skips scheduling rather than failing the
-- whole migration.
--
-- Run ONCE in the Supabase SQL editor, after docs/platform_moderation.sql
-- (not a hard dependency here, but kept in migration order with the rest of
-- central authority). Safe to re-run: every statement is idempotent.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table if not exists public.call_rosters (
  call_id         text not null,
  member_phone    text not null,
  -- Set only on the row that named the dial list — see call_dial_list().
  initiator_phone text not null default '',
  -- Only ever non-empty on the initiator's own row.
  dial_phones     text[] not null default '{}',
  member_name     text not null default '',
  video           boolean not null default false,
  joined_at       timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  primary key (call_id, member_phone)
);

create index if not exists call_rosters_last_seen_idx
  on public.call_rosters (last_seen);

alter table public.call_rosters enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the table above has to exist first)
-- ---------------------------------------------------------------------------

-- The real dial list for [cid] — whichever row carries a non-empty one (the
-- initiator's). '{}' when no such row exists yet, which is also how the
-- insert policy's bootstrap branch recognizes "nobody has claimed this call
-- id yet."
create or replace function public.call_dial_list(cid text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select dial_phones from public.call_rosters
      where call_id = cid and cardinality(dial_phones) > 0
      limit 1),
    '{}'::text[]
  );
$$;

-- True when [p] was actually dialed for [cid], or is the call's own
-- initiator (covering their later re-inserts/heartbeats, once their first
-- row — the one that established the dial list at all — already exists).
create or replace function public.is_call_eligible(cid text, p text default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p, auth.jwt() ->> 'phone') = any(public.call_dial_list(cid))
      or exists (
        select 1 from public.call_rosters
         where call_id = cid
           and initiator_phone = coalesce(p, auth.jwt() ->> 'phone')
      );
$$;

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- No column-hiding dance — nothing here is a secret the way secret_hash is
-- for a server, and the table is never world-readable (RLS scopes it to
-- eligible callers only).
revoke select, insert, update, delete on public.call_rosters from anon, authenticated;
grant select, insert, update, delete on public.call_rosters to authenticated;

-- REVOKE ANON EXPLICITLY — the lesson this codebase already learned once
-- live (find_people_by_hashes, docs/directory_phone_privacy.sql) and has
-- restated in every central-authority file since: a live Supabase project
-- grants table-wide privileges to `anon` on every NEW table by default, and
-- `revoke ... from public` does not take that away.
revoke all on public.call_rosters from anon;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------

drop policy if exists call_rosters_read on public.call_rosters;
create policy call_rosters_read on public.call_rosters
  for select to authenticated
  using (public.is_call_eligible(call_id));

-- Self-row only, and either the bootstrap case (nothing claims this call_id
-- yet — you may found it, naming yourself as initiator) or real eligibility
-- (you're on the existing dial list, or you're re-inserting your own row as
-- the initiator who already founded it).
drop policy if exists call_rosters_insert on public.call_rosters;
create policy call_rosters_insert on public.call_rosters
  for insert to authenticated
  with check (
    member_phone = (auth.jwt() ->> 'phone')
    and (
      (cardinality(public.call_dial_list(call_id)) = 0
        and initiator_phone = member_phone)
      or public.is_call_eligible(call_id)
    )
  );

-- Own row only — a heartbeat (last_seen) or a mid-call video toggle.
drop policy if exists call_rosters_update on public.call_rosters;
create policy call_rosters_update on public.call_rosters
  for update to authenticated
  using (member_phone = (auth.jwt() ->> 'phone'))
  with check (member_phone = (auth.jwt() ->> 'phone'));

-- Own row only. Deliberately NO moderator-delete, unlike voice presence's
-- force-disconnect — a call has no owner/moderator concept to grant that
-- power to, and inventing one is out of scope here.
drop policy if exists call_rosters_delete on public.call_rosters;
create policy call_rosters_delete on public.call_rosters
  for delete to authenticated
  using (member_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 5. Scheduled cleanup — guarded, since pg_cron may not be available
-- ---------------------------------------------------------------------------
do $outer$
begin
  begin
    execute 'create extension if not exists pg_cron';
  exception when others then
    raise notice '  pg_cron unavailable in this environment — skipping '
      'scheduled call_rosters cleanup (docs/call_presence.sql). Client-side '
      'cleanup (RelayService.leaveCallRoster) still runs on every real '
      'call end; only the force-quit/dropped-connection backstop is missing.';
    return;
  end;

  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('call_rosters_cleanup');
    exception when others then
      null; -- no existing job to unschedule — fine on a first run
    end;
    perform cron.schedule(
      'call_rosters_cleanup',
      '*/15 * * * *',
      $cron$delete from public.call_rosters where last_seen < now() - interval '2 hours'$cron$
    );
  end if;
end
$outer$;
