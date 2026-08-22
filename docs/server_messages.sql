-- Server-stored direct messages (2026-08-22) — the owner's direction change:
-- "move away from privacy and storing things local and be more social media",
-- answered as "server-stored, encrypted at rest, keys held by the server".
--
-- WHAT THIS IS, SAID PLAINLY RATHER THAN DRESSED UP. Message bodies live in
-- this table in the clear. "Encrypted at rest" is the PLATFORM's disk
-- encryption, whose keys Supabase holds and manages — the same thing every
-- mainstream messenger means by the phrase, and the same thing that is
-- already true of every public post, listing and forum thread in this
-- project. It is NOT end-to-end encryption and this file must never be
-- described as if it were. Anyone with database access can read a message,
-- and that is the deliberate trade: it is what makes history follow an
-- account to a new phone, what makes a reported message readable by a
-- moderator, and what makes the app behave like the social apps it is being
-- pointed at.
--
-- THE LEGAL DOCUMENTS ARE PART OF THIS CHANGE, NOT A FOLLOW-UP. The
-- published Privacy Policy and Terms (legalVersion 7, live at
-- /pages/privacy and /pages/terms and submitted to App Store Connect) say
-- outright that message bodies cannot be read by us. That stops being true
-- the moment anything WRITES to this table, so the client wiring and a
-- legalVersion bump have to land together. Applying this migration alone
-- changes nothing: no code writes here yet, and an empty table makes no
-- promise either way.
--
-- WHAT IS NOT REPLACED. The existing sealed broadcast and the `mailbox`
-- store-and-forward stay exactly as they are and keep being the delivery
-- path — this table is DURABLE HISTORY, not transport. A device still
-- receives a message the way it does today; what changes is that the message
-- is also written somewhere it can be read back from on a different phone,
-- next year, after a reinstall. Keeping the two apart means an older build
-- goes on working unchanged, and a device with no session (a name-only
-- account) still sends and receives over the anon-key mailbox exactly as it
-- always has.
--
-- ROUTING, AND WHY BOTH SHAPES ARE ONE TABLE. A 1:1 message names a
-- recipient; a group message names a group and nobody in particular. Rather
-- than two tables with two sets of policies to keep in step, `group_id` is
-- the switch: empty means 1:1 (and `recipient_phone` is the other party),
-- non-empty means a group whose membership is already server-authoritative
-- in chat_members (docs/chat_structure.sql), so `is_chat_member` is the
-- whole read gate for that half and there is no second roster to maintain.
--
-- ANON HAS NOTHING HERE, granted explicitly rather than left to RLS. The
-- community_structure.sql lesson, learned live: Supabase grants table-wide
-- privileges to `anon` on every NEW table by default, and a policy scoped
-- `to authenticated` merely means no policy ever matches an anon caller —
-- the raw grant still sits there waiting for the day a policy changes.

create table if not exists public.direct_messages (
  -- The client's own message id. Already unique within a conversation, and
  -- paired with chat_id below it is unique everywhere; kept as the primary
  -- key so an edit, a delete and a receipt all address the same row the app
  -- already addresses locally, with no id translation layer.
  id              text primary key,
  chat_id         text not null,
  -- Never taken from the client: filled from the caller's own JWT, so a
  -- device cannot write a message as somebody else even before RLS looks.
  sender_phone    text not null default (auth.jwt() ->> 'phone'),
  -- '' for a group message.
  recipient_phone text not null default '',
  -- '' for a 1:1.
  group_id        text not null default '',
  -- The readable message. Empty for a message that carries no words (a
  -- photo, a poll, a location) — those live in `payload`.
  body            text not null default '',
  -- Everything else the app's Message model holds, verbatim, so a message
  -- kind added later needs no migration. Same shape community_posts and
  -- market_listings already use.
  payload         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  -- A delete-for-everyone. The row stays so the tombstone reaches a device
  -- that was offline, and so a moderator can still see what was reported.
  deleted         boolean not null default false
);

create index if not exists direct_messages_chat_idx
  on public.direct_messages (chat_id, created_at);
create index if not exists direct_messages_recipient_idx
  on public.direct_messages (recipient_phone, created_at);
create index if not exists direct_messages_sender_idx
  on public.direct_messages (sender_phone, created_at);

alter table public.direct_messages enable row level security;

revoke all on table public.direct_messages from anon;
revoke all on table public.direct_messages from authenticated;
grant select, insert, delete on table public.direct_messages to authenticated;
-- Column-scoped UPDATE: an edit may change the words and stamp itself, and a
-- delete-for-everyone may set the flag. Nothing else can move — a later
-- write can never reassign a message's author, its conversation, or when it
-- was sent, which is what keeps the history somebody reads back the history
-- that happened.
grant update (body, payload, edited_at, deleted)
  on table public.direct_messages to authenticated;

-- Whether the caller is a party to this message: its sender, its named
-- recipient, or a member of the group it was sent to.
--
-- SECURITY DEFINER because the group half reads chat_members, which is
-- itself behind RLS — the same self-reference trap is_chat_member and
-- is_community_member are already definer to avoid.
create or replace function public.is_message_party(
  p_sender text, p_recipient text, p_group text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.jwt() ->> 'phone' is null then false
    when p_sender = auth.jwt() ->> 'phone' then true
    when p_group <> '' then public.is_chat_member(p_group)
    else p_recipient = auth.jwt() ->> 'phone'
  end;
$$;

revoke all on function public.is_message_party(text, text, text) from public;
revoke all on function public.is_message_party(text, text, text) from anon;
grant execute on function public.is_message_party(text, text, text)
  to authenticated;

drop policy if exists direct_messages_read on public.direct_messages;
create policy direct_messages_read on public.direct_messages
  for select to authenticated
  using (public.is_message_party(sender_phone, recipient_phone, group_id));

-- Send. The sender is always yourself (the column default fills it from the
-- JWT, and this refuses it even if a client names somebody else), and a
-- group message is refused unless you are actually on that group's roster —
-- which is the thing `gupd` gossip could never check.
drop policy if exists direct_messages_send on public.direct_messages;
create policy direct_messages_send on public.direct_messages
  for insert to authenticated
  with check (
    sender_phone = auth.jwt() ->> 'phone'
    and not public.is_silenced(auth.jwt() ->> 'phone')
    and (
      (group_id = '' and recipient_phone <> '')
      or (group_id <> '' and public.is_chat_member(group_id))
    )
  );

-- Edit and delete-for-everyone: the author, and only the author. A
-- recipient deleting somebody else's message from the record is a different
-- feature from the one the app has, and it is not this one.
drop policy if exists direct_messages_edit on public.direct_messages;
create policy direct_messages_edit on public.direct_messages
  for update to authenticated
  using (sender_phone = auth.jwt() ->> 'phone')
  with check (sender_phone = auth.jwt() ->> 'phone');

-- A real DELETE, distinct from the `deleted` tombstone above: the tombstone
-- is what other devices need to see, this is "take it off the server
-- entirely" and is the author's own right over their own words.
drop policy if exists direct_messages_remove on public.direct_messages;
create policy direct_messages_remove on public.direct_messages
  for delete to authenticated
  using (sender_phone = auth.jwt() ->> 'phone');
