-- Server-authoritative community structure (2026-08-13): a durable, RLS-scoped
-- copy of a server's identity, channel list, roster, and custom roles.
--
-- WHY THIS EXISTS. Until now a "server" had no server-side authority at all —
-- CommunityStore was pure local state, and every structural change (rename,
-- add a channel, change a role, remove a member, ban someone) was a full
-- re-serialization of the WHOLE community broadcast + mailboxed to every other
-- member, who unconditionally overwrote their local copy from whatever arrived
-- last. There was no conflict resolution and — the part worth saying plainly —
-- no server-side permission check at all: a modified client could forge any
-- structural change today and nothing would object.
--
-- This file is a CACHE-COHERENCE BACKSTOP layered on top of that gossip
-- protocol, not a replacement for it. Every existing broadcast/mailbox/mesh
-- path (chupd, chjoin, applyRemoteStructure, sendServerJoin, rotateServerKey,
-- the sender-key handshake) stays completely untouched, and keeps being the
-- ONLY path for a fully offline device or one reachable only over Bluetooth
-- mesh — that is not a migration-window limitation, it is the permanent,
-- correct shape for a local-first app. What this buys: a device that opens
-- the app can pull the current, permission-checked truth in one read instead
-- of trusting whatever the last full-snapshot broadcast happened to say, and
-- — for the first time — a real server-side check that a structural change
-- actually came from someone allowed to make it.
--
-- WHAT STAYS EXACTLY AS TODAY: message and channel-message CONTENT. chmsg,
-- chdel, chedt, chrxn, chpin, and every forum event are untouched — still
-- end-to-end sealed under the server's Signal-style sender key, still
-- peer-relayed. Nothing in this file can read a message body, and the
-- sender-key rotation that locks a removed member out of future content
-- (SenderKeyStore.rotate / RelayService.rotateServerKey) is unaffected by
-- where roster AUTHORITY lives — it stays a client-observed, client-triggered
-- event, same as today.
--
-- THE SECRET IS NEVER STORED HERE, ONLY ITS HASH. A public (listed) server's
-- secret already lives in the clear in `server_directory` (docs/public_servers.sql)
-- — that is the deliberate trade "anyone may join" already makes. A PRIVATE
-- server has never had a durable server-side home for its content-decryption
-- key, and this file does not give it one: `community_servers.secret_hash` is
-- sha256(secret), computed CLIENT-SIDE (AccountService.phoneHashHex's own
-- pattern, package:crypto), and the join RPC below only ever compares hashes.
-- A single RLS misconfiguration or compromised service-role credential can
-- never expose a private server's content key through this table.
--
-- A NEW RLS SHAPE FOR THIS CODEBASE. Every other table's read policy here is
-- either world-readable-minus-sanctioned or owner-only. Real membership needs
-- a third shape — "readable only by the N actual members of server X" — so
-- this file adds the first is_community_member()-style predicate, modeled on
-- community_pass_active()'s existing style (docs/paid_servers.sql).
--
-- JOIN IS AN RPC, NOT A PERMISSIVE INSERT POLICY, ON PURPOSE. Community.id is
-- 'c_${name.hashCode}_${count}' (lib/state/community_store.dart) — low-entropy
-- and guessable. A plain insert policy would let a stranger enumerate ids and
-- add themselves to a roster without ever holding an invite. The RPC compares
-- the caller-supplied hash against the stored one and silently no-ops on any
-- mismatch, exactly like every other RPC in this codebase that guards a real
-- secret (community_pass_active, the moderation functions).
--
-- PAID-SERVER JOIN NOW ENFORCED SERVER-SIDE — a real tightening, confirmed
-- with the owner. Today `joinFromInvite` performs NO payment check at all;
-- the paywall is a UI convention the app is trusted to have already applied.
-- The join RPC reuses the existing `community_pass_active()` (docs/paid_servers.sql)
-- so a leaked invite for a paid server can no longer register a holder as an
-- authoritative member without an active pass. This does not change the
-- underlying crypto exposure — anyone holding the secret can still decrypt
-- content regardless of payment, same as today — it only tightens who is
-- listed as a roster member.
--
-- NUMBERLESS ACCOUNTS ARE NOT REACHED BY THIS FILE. Every policy/helper below
-- is phone-JWT-based (auth.jwt() ->> 'phone'), and a numberless account has no
-- Supabase session to carry one (see docs/directory_numberless.sql). Such an
-- account transparently keeps using legacy peer-broadcast membership for
-- every community it's in, indefinitely — stated here rather than discovered
-- later. Closing that gap is its own follow-up, not this file's scope.
--
-- MIGRATION: NOTHING IS REQUIRED, EVERYTHING IS OPPORTUNISTIC. An existing
-- (legacy, local-only) server needs no manual recreation: the owner's device
-- upserts it here on its very next structural change (and, going forward,
-- once per relay start for every server it owns); every member's device
-- idempotently re-registers itself once per relay start for every community
-- it is already locally in (community_join's `on conflict do nothing` makes
-- that safe to call repeatedly). A community whose owner never opens the app
-- again simply never gets a row here and keeps working exactly as it does
-- today, forever.
--
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (is_locked_out/is_silenced), docs/public_feed.sql (is_silenced is actually
-- defined there), and docs/paid_servers.sql (community_pass_active). Safe to
-- re-run: every statement is idempotent.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.community_servers (
  id            text primary key,               -- matches Community.id
  owner_phone   text not null,
  -- sha256(secret) hex, client-computed. NEVER the raw secret — see the file
  -- header. Withheld from every client grant below on top of that.
  secret_hash   text not null,
  name          text not null default '',
  color         text not null default '#7A5CFF',
  color2        text not null default '',
  icon          text not null default '',
  description   text not null default '',
  slow_mode_seconds int not null default 0,
  members_can_create_channels boolean not null default true,
  members_can_post boolean not null default true,
  members_can_message boolean not null default true,
  invite_policy text not null default 'everyone',
  banned_words  text[] not null default '{}',
  paid          boolean not null default false,
  price_cents   int not null default 0,
  sub_pitch     text not null default '',
  updated_at    timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create table if not exists public.community_members (
  community_id text not null
                 references public.community_servers(id) on delete cascade,
  member_phone text not null,
  role         text not null default 'member'
                 check (role in ('owner', 'admin', 'moderator', 'member')),
  role_id      text not null default '',       -- CustomRole.id, or '' for none
  joined_at    timestamptz not null default now(),
  primary key (community_id, member_phone)
);

create table if not exists public.community_channels (
  id           text primary key,
  community_id text not null
                 references public.community_servers(id) on delete cascade,
  name         text not null default '',
  type         text not null default 'text',
  category     text not null default '',
  topic        text not null default '',
  position     int not null default 0,
  updated_at   timestamptz not null default now()
);

create table if not exists public.community_roles (
  id           text primary key,
  community_id text not null
                 references public.community_servers(id) on delete cascade,
  name         text not null default '',
  color        text not null default '#17708A',
  -- Never 'owner' — a role can lift at most to admin, mirroring
  -- CustomRole.tier's own clamp in lib/models/community.dart.
  tier         text not null default 'member'
                 check (tier in ('admin', 'moderator', 'member')),
  badge        text not null default ''
);

create table if not exists public.community_bans (
  community_id text not null
                 references public.community_servers(id) on delete cascade,
  member_phone text not null,
  member_name  text not null default '',
  banned_at    timestamptz not null default now(),
  primary key (community_id, member_phone)
);

create index if not exists community_members_phone_idx
  on public.community_members (member_phone);
create index if not exists community_channels_community_idx
  on public.community_channels (community_id);
create index if not exists community_roles_community_idx
  on public.community_roles (community_id);

alter table public.community_servers  enable row level security;
alter table public.community_members  enable row level security;
alter table public.community_channels enable row level security;
alter table public.community_roles    enable row level security;
alter table public.community_bans     enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the tables above have to exist first)
-- ---------------------------------------------------------------------------

-- owner=3 / admin=2 / moderator=1 / member=0 — matches roleRank in
-- lib/models/community.dart exactly.
create or replace function public.community_role_rank(r text)
returns int
language sql
immutable
as $$
  select case r
    when 'owner' then 3
    when 'admin' then 2
    when 'moderator' then 1
    else 0
  end;
$$;

-- The core new predicate — every table's read policy below is built on this.
create or replace function public.is_community_member(cid text, p text default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.community_members m
     where m.community_id = cid
       and m.member_phone = coalesce(p, auth.jwt() ->> 'phone')
  );
$$;

-- The higher of a member's built-in role and their custom role's tier —
-- mirrors Community.effectiveRole in lib/models/community.dart exactly,
-- including that a role can never lift someone past admin.
create or replace function public.community_effective_role(cid text, p text default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case greatest(
      public.community_role_rank(m.role),
      public.community_role_rank(coalesce(r.tier, 'member'))
    )
    when 3 then 'owner'
    when 2 then 'admin'
    when 1 then 'moderator'
    else 'member'
  end
  from public.community_members m
  left join public.community_roles r
    on r.id = m.role_id and r.community_id = m.community_id
  where m.community_id = cid
    and m.member_phone = coalesce(p, auth.jwt() ->> 'phone');
$$;

-- Owners and admins only — matches CommunityStore.canManageServer.
create or replace function public.can_manage_community(cid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.community_role_rank(
    coalesce(public.community_effective_role(cid), 'member')) >= 2;
$$;

-- Moderators and above — matches CommunityStore.canModerate.
create or replace function public.can_moderate_community(cid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.community_role_rank(
    coalesce(public.community_effective_role(cid), 'member')) >= 1;
$$;

-- Matches CommunityStore.canCreateChannels: a moderator+ always may; an
-- ordinary member may only while the server's own setting allows it.
create or replace function public.can_create_channel(cid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.can_moderate_community(cid)
    or coalesce(
      (select s.members_can_create_channels
         from public.community_servers s where s.id = cid),
      true);
$$;

-- THE JOIN GATE. Silently no-ops on any failure — a wrong secret, a ban, an
-- unpaid pass, a locked-out account — exactly like every other RPC here that
-- guards a real secret, rather than distinguishing failure reasons to a
-- caller who might be an attacker probing which one applied.
create or replace function public.community_join(cid text, secret_hash text, my_name text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me  text := (auth.jwt() ->> 'phone');
  row record;
begin
  if me is null or public.is_locked_out(me) then return; end if;
  select * into row from public.community_servers where id = cid;
  if row is null then return; end if;
  if row.secret_hash <> secret_hash then return; end if;
  if exists (
    select 1 from public.community_bans b
     where b.community_id = cid and b.member_phone = me
  ) then return; end if;
  if row.paid and not public.community_pass_active(cid) then return; end if;
  -- ON CONFLICT DO NOTHING is also what makes this safe to call
  -- OPPORTUNISTICALLY on every relay start for a community already joined
  -- locally — see the migration note in the file header.
  insert into public.community_members (community_id, member_phone, role)
  values (cid, me, 'member')
  on conflict (community_id, member_phone) do nothing;
end;
$$;

grant execute on function public.community_join(text, text, text) to authenticated;

-- THE OWNER'S BOOTSTRAP. community_members_insert (below) is deliberately
-- admin-only, which is correct for every OTHER insert but creates a genuine
-- chicken-and-egg problem for the very first row: can_manage_community reads
-- community_effective_role, which reads community_members itself — before the
-- owner has a row there, effective role resolves to nothing and the insert
-- policy refuses even the real owner. A trigger, not a policy branch, is the
-- fix: seeding the owner's own 'owner' row is a direct, mechanical consequence
-- of the community_servers row existing at all, not something that needs its
-- own client-facing insert path (which would just reopen a version of the
-- same self-insert hole the members policy exists to close). Runs as definer,
-- so it bypasses community_members' RLS entirely for this one seed insert;
-- ON CONFLICT DO NOTHING makes it safe on every opportunistic republish too.
create or replace function public.community_servers_seed_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.community_members (community_id, member_phone, role)
  values (new.id, new.owner_phone, 'owner')
  on conflict (community_id, member_phone) do nothing;
  return new;
end;
$$;

drop trigger if exists community_servers_seed_owner_trigger on public.community_servers;
create trigger community_servers_seed_owner_trigger
  after insert on public.community_servers
  for each row execute function public.community_servers_seed_owner();

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- Unlike most tables in this codebase there is no phone-hiding dance for most
-- columns here — the whole point is that real members see the real roster (a
-- member's own wire-id digits are already visible to every other member
-- locally today). The one column withheld is secret_hash: clients never need
-- to read it directly, only the join RPC (running as definer) compares it.
revoke select on table public.community_servers from anon, authenticated;
grant select (id, owner_phone, name, color, color2, icon, description,
              slow_mode_seconds, members_can_create_channels, members_can_post,
              members_can_message, invite_policy, banned_words, paid,
              price_cents, sub_pitch, updated_at, created_at)
  on public.community_servers to authenticated;
grant insert, update, delete on public.community_servers to authenticated;

-- No anon grant anywhere in this file: private structure should never be
-- reachable on the anon key even in principle. A numberless/no-session
-- device has no path here at all — see the file header.
grant select, insert, update, delete on public.community_members  to authenticated;
grant select, insert, update, delete on public.community_channels to authenticated;
grant select, insert, update, delete on public.community_roles    to authenticated;
grant select, insert, delete         on public.community_bans     to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------

-- Read if you own it OR are already a member. The OR is the bootstrap: right
-- after INSERTing your own new server you aren't a community_members row yet.
drop policy if exists community_servers_read on public.community_servers;
create policy community_servers_read on public.community_servers
  for select to authenticated
  using (owner_phone = (auth.jwt() ->> 'phone')
         or public.is_community_member(id));

drop policy if exists community_servers_insert_own on public.community_servers;
create policy community_servers_insert_own on public.community_servers
  for insert to authenticated
  with check (owner_phone = (auth.jwt() ->> 'phone')
              and not public.is_silenced(owner_phone));

drop policy if exists community_servers_update_managers on public.community_servers;
create policy community_servers_update_managers on public.community_servers
  for update to authenticated
  using (public.can_manage_community(id) or owner_phone = (auth.jwt() ->> 'phone'))
  with check (public.can_manage_community(id) or owner_phone = (auth.jwt() ->> 'phone'));

drop policy if exists community_servers_delete_owner on public.community_servers;
create policy community_servers_delete_owner on public.community_servers
  for delete to authenticated
  using (owner_phone = (auth.jwt() ->> 'phone'));

-- Read your own row (bootstrap, mirrors the servers table) or any row once
-- you're already a member.
drop policy if exists community_members_read on public.community_members;
create policy community_members_read on public.community_members
  for select to authenticated
  using (member_phone = (auth.jwt() ->> 'phone')
         or public.is_community_member(community_id));

-- Deliberately admin-only. Self-join does NOT get a policy branch here —
-- community_join() is a SECURITY DEFINER function, so it inserts as the
-- table owner and needs no client-facing INSERT privilege for the self-join
-- case at all. A policy that allowed "member_phone = you" directly would
-- let any authenticated stranger add themselves to ANY community_id with no
-- secret check whatsoever — exactly the guessable-id hole the RPC exists to
-- close (see the file header). Never widen this to allow a direct self-insert.
drop policy if exists community_members_insert on public.community_members;
create policy community_members_insert on public.community_members
  for insert to authenticated
  with check (role <> 'owner' and public.can_manage_community(community_id));

drop policy if exists community_members_update on public.community_members;
create policy community_members_update on public.community_members
  for update to authenticated
  using (public.can_manage_community(community_id))
  with check (role <> 'owner' and public.can_manage_community(community_id));

-- Self-leave, or a manager removing a non-owner — the owner-role guard is
-- enforced by the database itself now, not only by a client-side check.
drop policy if exists community_members_delete on public.community_members;
create policy community_members_delete on public.community_members
  for delete to authenticated
  using (
    (member_phone = (auth.jwt() ->> 'phone') or public.can_manage_community(community_id))
    and role <> 'owner'
  );

drop policy if exists community_channels_read on public.community_channels;
create policy community_channels_read on public.community_channels
  for select to authenticated
  using (public.is_community_member(community_id));

drop policy if exists community_channels_insert on public.community_channels;
create policy community_channels_insert on public.community_channels
  for insert to authenticated
  with check (public.can_create_channel(community_id));

drop policy if exists community_channels_update on public.community_channels;
create policy community_channels_update on public.community_channels
  for update to authenticated
  using (public.can_create_channel(community_id))
  with check (public.can_create_channel(community_id));

drop policy if exists community_channels_delete on public.community_channels;
create policy community_channels_delete on public.community_channels
  for delete to authenticated
  using (public.can_manage_community(community_id));

drop policy if exists community_roles_read on public.community_roles;
create policy community_roles_read on public.community_roles
  for select to authenticated
  using (public.is_community_member(community_id));

drop policy if exists community_roles_write on public.community_roles;
create policy community_roles_write on public.community_roles
  for insert to authenticated
  with check (public.can_manage_community(community_id));

drop policy if exists community_roles_update on public.community_roles;
create policy community_roles_update on public.community_roles
  for update to authenticated
  using (public.can_manage_community(community_id))
  with check (public.can_manage_community(community_id));

drop policy if exists community_roles_delete on public.community_roles;
create policy community_roles_delete on public.community_roles
  for delete to authenticated
  using (public.can_manage_community(community_id));

-- Bans: readable by fellow members (so a client can show "banned" state and
-- refuse to re-invite), written only by a moderator+.
drop policy if exists community_bans_read on public.community_bans;
create policy community_bans_read on public.community_bans
  for select to authenticated
  using (public.is_community_member(community_id));

drop policy if exists community_bans_insert on public.community_bans;
create policy community_bans_insert on public.community_bans
  for insert to authenticated
  with check (public.can_moderate_community(community_id));

drop policy if exists community_bans_delete on public.community_bans;
create policy community_bans_delete on public.community_bans
  for delete to authenticated
  using (public.can_moderate_community(community_id));

-- No `_view` layer here, unlike most files in this codebase — that pattern
-- exists for "world-readable minus one column"; nothing in these tables is
-- world-readable, RLS alone does the real work, and clients hit the base
-- tables directly through the fluent client (the same shape docs/paid_servers.sql
-- already uses for community_passes).
