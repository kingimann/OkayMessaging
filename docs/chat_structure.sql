-- Server-authoritative chat structure (2026-08-13): Phase 3 of "central
-- authority for the entire app" — the same cache-coherence backstop
-- community_structure.sql built for servers, now for 1:1 and group chats.
--
-- WHY THIS EXISTS. A chat's ROSTER (who's in a group, who a 1:1 is between)
-- has always been pure client gossip: `gupd` events, fanned out pairwise and
-- unconditionally trusted by every recipient, with no server-side check that
-- a payload claiming to add or remove a member actually came from someone
-- allowed to. This file adds a durable, RLS-scoped copy of that structure —
-- who is in the chat, and (for a group) its name/photo/about — so a device
-- can read a permission-checked truth instead of trusting whatever the last
-- `gupd` happened to say, and a removal can finally be enforced somewhere
-- other than "the sender's app chose to send it."
--
-- WHAT STAYS EXACTLY AS TODAY: message CONTENT. Every message — 1:1 or
-- group — keeps riding the Double Ratchet / static-ECDH pairwise ladder
-- (RelayService.sealContent/send/sendToGroup), fanned out one sealed copy
-- per recipient, exactly as it does now. Nothing in this file can read a
-- message body, and there is no sender-key/rotation concept here at all —
-- group content crypto is independent pairwise sessions, not a shared key a
-- roster change would need to rotate (see CLAUDE.md's own note on this).
-- `gupd`/`applyGroupUpdate` are untouched and remain the only path for a
-- fully offline device or one reachable only over Bluetooth mesh — that is
-- the permanent, correct shape for a local-first app, not a migration-window
-- limitation.
--
-- SHIPPED PERMISSIONS, NOT NEW ONES. Reading lib/screens/group_info_screen.dart
-- directly (not trusting a first-pass summary that turned out to be wrong)
-- found the app ALREADY enforces admin-only removal client-side (roster
-- index 0, `iAmAdmin && i != 0` gates the remove button) and there is no
-- "leave group" feature anywhere in the app at all. This file's RLS matches
-- that shipped behavior — admin-only delete from chat_members, nobody (not
-- even the admin) can remove themselves — rather than inventing a stricter
-- or looser rule than what the client already promises.
--
-- TWO KINDS OF CHAT, ONE PAIR OF TABLES. A group has a real owner (roster
-- index 0) and an objective shared name/photo/about everyone sees the same
-- way. A 1:1 has neither — Chat.contact.name is each side's OWN local name
-- for the other person (you might call them "Mom", they call you "John"),
-- so publishing a shared "name" for a 1:1 would either leak how you renamed
-- them or be meaningless. `direct_chats.owner_phone` is the switch: '' means
-- a 1:1 (name/avatar_color/about stay empty and are never published), a real
-- phone means a group whose owner is that phone.
--
-- BOOTSTRAP, TWO SHAPES. A group gets the same trigger-seed pattern
-- community_structure.sql uses for a server's owner: creating the
-- direct_chats row automatically seeds the owner's own chat_members row, so
-- there's no chicken-and-egg for the admin-only insert policy. A 1:1 has no
-- "owner" to seed from a trigger — BOTH real parties have to self-register —
-- so `phone_a`/`phone_b` (set once, at insert, and never grantable to update)
-- name the two real parties directly, and the chat_members bootstrap insert
-- policy checks a self-insert against those two named phones instead of
-- trusting a bare "insert yourself" policy. That distinction matters: a
-- group's id ('group_${epochMicroseconds}') is exactly as guessable as a
-- Community.id, which is why community_structure.sql refused a bare
-- self-insert bootstrap for a server's roster — the same discipline applies
-- here, so a group's ONLY bootstrap path is the owner-seed trigger, and every
-- other member is added by an EXISTING member (never a stranger guessing the
-- id). A 1:1's id ('chat_${contact.id}') is no safer in the abstract, but
-- self-inserting into ITS roster requires already being named as phone_a or
-- phone_b on a row that can only ever have been created by one of those two
-- phones in the first place — so guessing the id alone is not enough.
--
-- WHY direct_chats IS INSERT-ONCE FOR A 1:1, NEVER UPDATED. name/avatar_color/
-- about are deliberately never populated for a 1:1 (see above), and
-- is_group/owner_phone/phone_a/phone_b are immutable by design (not even in
-- the update column grant). So there is genuinely nothing about a 1:1's row
-- worth updating after creation — RelayService.publishChatStructure uses
-- `on conflict (id) do nothing` for a 1:1, which sidesteps a real
-- chicken-and-egg: the update policy requires is_chat_member(id), but the
-- SECOND party of a fresh 1:1 hasn't self-registered into chat_members yet
-- the first time their own device syncs.
--
-- NO DELETE PATH, ON PURPOSE — matches the shipped app exactly. There is no
-- "leave group" and no "delete this 1:1 forever" feature client-side, so
-- direct_chats grants no delete at all; the only delete grant is on
-- chat_members, gated to the group owner removing a non-owner. A local
-- ChatStore.deleteChat is exactly that — LOCAL, hides the conversation on
-- this device — and this table was never meant to track that.
--
-- MIGRATION: NOTHING IS REQUIRED, EVERYTHING IS OPPORTUNISTIC. Same as
-- community_structure.sql: an existing chat needs no manual recreation. A
-- group publishes on every `sendGroupUpdate` call (the one funnel every
-- structural change — create, rename, add member, remove member — already
-- goes through); a 1:1 publishes once, the first time either side sends a
-- message in it. A chat whose owner (for a group) or whose two parties (for
-- a 1:1) never open a build carrying this code simply never gets a row here
-- and keeps working exactly as it does today, over gossip alone, forever.
--
-- NUMBERLESS ACCOUNTS ARE NOT REACHED BY THIS FILE — same limit as
-- community_structure.sql, for the same reason (auth.jwt() ->> 'phone' needs
-- a session a numberless account never has). Such a device transparently
-- keeps using legacy peer-broadcast structure for every chat, indefinitely.
--
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (is_locked_out) and docs/public_feed.sql (is_silenced). Safe to re-run:
-- every statement is idempotent.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.direct_chats (
  id            text primary key,             -- matches Chat.id
  is_group      boolean not null default false,
  owner_phone   text not null default '',      -- group admin; '' means a 1:1
  -- The two real parties of a 1:1 — see the file header for why. Always ''
  -- for a group (a group's members live in chat_members like everything
  -- else; these two columns exist ONLY to make a 1:1's bootstrap safe).
  phone_a       text not null default '',
  phone_b       text not null default '',
  -- Never populated for a 1:1 — see the file header.
  name          text not null default '',
  avatar_color  text not null default '',
  about         text not null default '',
  updated_at    timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create table if not exists public.chat_members (
  chat_id      text not null
                 references public.direct_chats(id) on delete cascade,
  member_phone text not null,
  joined_at    timestamptz not null default now(),
  primary key (chat_id, member_phone)
);

create index if not exists chat_members_phone_idx
  on public.chat_members (member_phone);

alter table public.direct_chats enable row level security;
alter table public.chat_members enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the tables above have to exist first)
-- ---------------------------------------------------------------------------

-- Mirrors is_community_member(cid, p) exactly.
create or replace function public.is_chat_member(cid text, p text default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.chat_members m
     where m.chat_id = cid
       and m.member_phone = coalesce(p, auth.jwt() ->> 'phone')
  );
$$;

-- THE GROUP OWNER'S BOOTSTRAP — mirrors community_servers_seed_owner exactly.
-- chat_members_insert (below) requires already being a member for the
-- general case, which is correct for every OTHER add but is a chicken-and-egg
-- for the very first row: a brand-new group's owner isn't a chat_members row
-- yet, so their own insert policy would refuse even them. A trigger sidesteps
-- that the same way it does for a server. A 1:1 (owner_phone = '') has no
-- single identity to seed from here — both real parties self-register via
-- the phone_a/phone_b bootstrap branch in chat_members_insert instead.
create or replace function public.direct_chats_seed_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_group and new.owner_phone <> '' then
    insert into public.chat_members (chat_id, member_phone)
    values (new.id, new.owner_phone)
    on conflict (chat_id, member_phone) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists direct_chats_seed_owner_trigger on public.direct_chats;
create trigger direct_chats_seed_owner_trigger
  after insert on public.direct_chats
  for each row execute function public.direct_chats_seed_owner();

-- Whether [p] is one of a 1:1's two named parties. SECURITY DEFINER on
-- purpose, for the same reason is_chat_member is: a plain subquery embedded
-- directly in chat_members_insert's WITH CHECK below would run as the
-- CALLING role and so would itself be subject to direct_chats_read's own
-- is_chat_member(id) policy — which is false for the very party trying to
-- bootstrap their way IN, making the row invisible to its own check even
-- though it genuinely names them. Found by running this file's own tests:
-- the first version had the subquery inline and self-registration failed
-- with "new row violates row-level security policy" for a real named party.
create or replace function public.is_direct_chat_party(cid text, p text default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.direct_chats d
     where d.id = cid
       and not d.is_group
       and coalesce(p, auth.jwt() ->> 'phone') in (d.phone_a, d.phone_b)
  );
$$;

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- No phone-hiding dance here (unlike community_servers' secret_hash) — there
-- is no secret in either table, and neither is world-readable (RLS scopes
-- both to real members only), so a plain column-unrestricted select is fine.
-- What IS restricted: which columns an UPDATE may touch. is_group,
-- owner_phone, phone_a and phone_b are never in the update grant, so even a
-- caller who passes the update policy's USING/CHECK cannot rewrite a chat's
-- identity or flip a 1:1 into a group — the same "grant only the columns
-- that should ever move" pattern public_posts_update_own uses for edited
-- posts (docs/public_feed_edit.sql).
revoke select, insert, update, delete on public.direct_chats from anon, authenticated;
grant select, insert on public.direct_chats to authenticated;
grant update (name, avatar_color, about, updated_at) on public.direct_chats to authenticated;
-- No delete grant at all — see the file header ("no delete path, on purpose").

revoke select, insert, update, delete on public.chat_members from anon, authenticated;
grant select, insert, delete on public.chat_members to authenticated;
-- No update grant — a member row has nothing mutable but joined_at, which
-- should never move once set.

-- REVOKE ANON EXPLICITLY, ON EVERY TABLE — the lesson community_structure.sql
-- already had to state once for this codebase: a live Supabase project grants
-- table-wide privileges to `anon` on every NEW table by default, and
-- `revoke ... from public` does not take that away. Named here from the
-- start rather than found after.
revoke all on public.direct_chats from anon;
revoke all on public.chat_members from anon;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------

drop policy if exists direct_chats_read on public.direct_chats;
create policy direct_chats_read on public.direct_chats
  for select to authenticated
  using (public.is_chat_member(id));

-- A group: you may create it only as its own owner. A 1:1: owner_phone must
-- be '' and you must be one of the two named parties — see the file header
-- for why phone_a/phone_b exist at all.
drop policy if exists direct_chats_insert on public.direct_chats;
create policy direct_chats_insert on public.direct_chats
  for insert to authenticated
  with check (
    (is_group
      and owner_phone = (auth.jwt() ->> 'phone')
      and not public.is_silenced(owner_phone))
    or (not is_group
      and owner_phone = ''
      and phone_a <> '' and phone_b <> '' and phone_a <> phone_b
      and (auth.jwt() ->> 'phone') in (phone_a, phone_b))
  );

-- Rename/re-photo/about — any member, not just the owner. Matches the
-- shipped app exactly: openGroupEditor has no admin gate, only member
-- REMOVAL does. The update grant above already restricts which columns this
-- can ever touch, so is_chat_member alone is the whole gate needed here.
drop policy if exists direct_chats_update on public.direct_chats;
create policy direct_chats_update on public.direct_chats
  for update to authenticated
  using (public.is_chat_member(id))
  with check (public.is_chat_member(id));

drop policy if exists chat_members_read on public.chat_members;
create policy chat_members_read on public.chat_members
  for select to authenticated
  using (public.is_chat_member(chat_id));

-- General case: any existing member may add another — matches the shipped
-- app exactly (adding members has no admin gate, unlike removal). Bootstrap
-- case: a fresh 1:1's own two named parties may self-insert even before
-- either is a chat_member yet — see the file header for why this is safe
-- (phone_a/phone_b were fixed at insert time by one of the two real parties,
-- never by a client-supplied member_phone).
drop policy if exists chat_members_insert on public.chat_members;
create policy chat_members_insert on public.chat_members
  for insert to authenticated
  with check (
    public.is_chat_member(chat_id)
    or (member_phone = (auth.jwt() ->> 'phone')
        and public.is_direct_chat_party(chat_id))
  );

-- Admin-only, and the admin can never remove themselves — matches
-- group_info_screen.dart's shipped `iAmAdmin && i != 0` exactly. For a 1:1
-- (owner_phone = '') this can never match anyone, which is correct: there is
-- no member-removal concept for a 1:1 at all.
drop policy if exists chat_members_delete on public.chat_members;
create policy chat_members_delete on public.chat_members
  for delete to authenticated
  using (
    exists (
      select 1 from public.direct_chats d
       where d.id = chat_id and d.owner_phone = (auth.jwt() ->> 'phone')
    )
    and member_phone <> (auth.jwt() ->> 'phone')
  );

-- No `_view` layer here, same reasoning as community_structure.sql — nothing
-- in either table is world-readable, RLS alone does the real work.
