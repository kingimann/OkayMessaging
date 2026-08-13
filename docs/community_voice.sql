-- Voice channel presence, Phase 2 of "central authority" (2026-08-13): the
-- direct answer to "is Discord voice channels the same way" — a deterministic
-- SELECT for full current occupancy the moment a voice channel is opened,
-- instead of only ever knowing who's here from accumulated broadcasts.
--
-- SAME SHAPE AS PHASE 1 (docs/community_structure.sql), reusing its helpers
-- directly: is_community_member gates reads, can_moderate_community gates a
-- force-disconnect. This file adds near-zero new design — one table.
--
-- PRESENCE STAYS A LIVE SIGNAL; THIS IS A GROUND-TRUTH READ, NOT A SECOND
-- SOURCE OF TRUTH. The existing `vpres` broadcast (VoicePresenceStore) is
-- UNTOUCHED and stays the low-latency path for "someone just joined/left/
-- muted while I'm already watching this room" — nobody wants a 20-second
-- heartbeat lag for that. What this table buys is the ONE moment broadcast
-- can't cover at all: opening a room you weren't already watching. Every
-- state-changing action a joined device already takes (join, leave, mute,
-- camera, screen-share, and the existing 20s heartbeat) upserts or deletes
-- this device's own row alongside the broadcast it already sends — one
-- callback (VoicePresenceStore.onPresence), two consequences, the exact
-- shape publishCommunityStructure took off onStructureChanged in Phase 1.
--
-- NO SERVER-SIDE SWEEP, ON PURPOSE. A force-quit or a dead network stops the
-- heartbeat, which stops the row's `last_seen` from advancing — nothing
-- deletes it. A reader filters `last_seen > now() - interval '65 seconds'`
-- CLIENT-SIDE (VoicePresenceStore.staleAfter, the exact 65s rule its own
-- sweep() already enforces for broadcast-heard occupants), so a stale row
-- simply never renders rather than needing a cron or a trigger to clean up
-- after devices that never got to say goodbye. The row itself outlives its
-- own truth for a while; nothing downstream believes it past 65 seconds.
--
-- A FORCE-DISCONNECT CAPABILITY THE OLD MODEL LITERALLY COULD NOT OFFER —
-- there was nothing to delete. A moderator's DELETE reaches this table
-- (can_moderate_community), which the client can use to remove someone from
-- a room server-side; it does NOT tear down that person's actual WebRTC
-- connection (that stays a client-driven hangup the same way it always has),
-- so this is the roster-eviction half of a kick, not the media half. No
-- "kick from voice" button is wired to it in this pass — the capability is
-- built and tested; a UI for it is a stated follow-up, not invented here.
--
-- Run ONCE in the Supabase SQL editor, AFTER docs/community_structure.sql
-- (needs community_servers for the FK, and is_community_member /
-- can_moderate_community). Safe to re-run: every statement is idempotent.

create table if not exists public.community_voice_presence (
  channel_id   text not null,
  member_phone text not null,
  community_id text not null
                 references public.community_servers(id) on delete cascade,
  member_name  text not null default '',
  muted        boolean not null default false,
  video        boolean not null default false,
  screen       boolean not null default false,
  joined_at    timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  primary key (channel_id, member_phone)
);

create index if not exists community_voice_presence_community_idx
  on public.community_voice_presence (community_id);

alter table public.community_voice_presence enable row level security;

-- Same lesson Phase 1 had to re-learn live (docs/community_structure.sql):
-- a Supabase project grants table-wide privileges to anon on every NEW
-- table by default. Closed here from the start rather than found after —
-- anon should never reach this table at all, same as every table in
-- community_structure.sql.
revoke all on public.community_voice_presence from anon;
grant select, insert, update, delete on public.community_voice_presence
  to authenticated;

drop policy if exists community_voice_presence_read
  on public.community_voice_presence;
create policy community_voice_presence_read on public.community_voice_presence
  for select to authenticated
  using (public.is_community_member(community_id));

drop policy if exists community_voice_presence_insert
  on public.community_voice_presence;
create policy community_voice_presence_insert on public.community_voice_presence
  for insert to authenticated
  with check (
    member_phone = (auth.jwt() ->> 'phone')
    and public.is_community_member(community_id)
  );

-- Own row only — a member's mic/camera/screen state is theirs to update,
-- never another member's or a moderator's to rewrite (a moderator's power
-- here is limited to DELETE, i.e. eviction, never impersonating state).
drop policy if exists community_voice_presence_update
  on public.community_voice_presence;
create policy community_voice_presence_update on public.community_voice_presence
  for update to authenticated
  using (member_phone = (auth.jwt() ->> 'phone'))
  with check (member_phone = (auth.jwt() ->> 'phone'));

-- Self-leave, or a moderator+ force-disconnecting someone else.
drop policy if exists community_voice_presence_delete
  on public.community_voice_presence;
create policy community_voice_presence_delete on public.community_voice_presence
  for delete to authenticated
  using (
    member_phone = (auth.jwt() ->> 'phone')
    or public.can_moderate_community(community_id)
  );
