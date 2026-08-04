-- Server-side persistence for community feed posts and marketplace listings.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor.
--
-- WHY. Server posts used to be broadcast-only: a sealed envelope relayed
-- live plus a mailbox copy for whoever was offline that minute. If delivery
-- missed — a member joined later, a mailbox write failed, a device was
-- reinstalled — the listing existed only on its author's phone, which read
-- as "the marketplace doesn't show listings". This table is the durable
-- copy: every post stored ONCE, fetched by members whenever they open or
-- refresh.
--
-- WHAT THE SERVER CAN READ: nothing. `payload` is the same AES-GCM
-- ciphertext the broadcast carries, sealed to the community's secret —
-- which lives only on members' devices, handed over inside invites the
-- server also cannot read. Like the mailbox, possession of the community id
-- fetches ciphertext; the secret is what turns it into posts. Chats are
-- NOT here and never will be: message content stays on devices, full stop.
--
-- Row lifecycle: upserted on post and on every listing update (revision
-- checks on the client keep replays harmless), deleted when the author
-- deletes the post. The client caps a payload the same place the relay
-- does; the CHECK below is the backstop.

create table if not exists public.community_posts (
  community_id text not null,
  post_id      text not null,
  payload      text not null check (char_length(payload) <= 400000),
  updated_at   timestamptz not null default now(),
  primary key (community_id, post_id)
);

create index if not exists community_posts_cid_idx
  on public.community_posts (community_id, updated_at desc);

alter table public.community_posts enable row level security;

-- The mailbox's trust model: the app key may write and read rows, because
-- rows are sealed ciphertext and the community id is unguessable. A delete
-- needs the row's exact ids — the same capability writing needed.
drop policy if exists community_posts_insert on public.community_posts;
create policy community_posts_insert on public.community_posts
  for insert to anon, authenticated with check (true);

drop policy if exists community_posts_select on public.community_posts;
create policy community_posts_select on public.community_posts
  for select to anon, authenticated using (true);

drop policy if exists community_posts_update on public.community_posts;
create policy community_posts_update on public.community_posts
  for update to anon, authenticated using (true) with check (true);

drop policy if exists community_posts_delete on public.community_posts;
create policy community_posts_delete on public.community_posts
  for delete to anon, authenticated using (true);
