-- Per-row user data (2026-08-23) — the X model for the lists that used to
-- ride the backup blob.
--
-- WHY A GENERIC TABLE RATHER THAN ONE PER STORE. Roughly forty stores hold
-- list-shaped data (bookmarks and their folders, muted accounts, chat
-- folders, inbox tiers, quick replies, saved forms, stickers, saved cities,
-- watch history…). A table each would be forty migrations, forty policy
-- sets and forty client wrappers to keep in step, and this project has
-- already learned what happens when N copies of one idea drift. One table
-- with a `kind` column costs one migration and makes converting the next
-- store a few lines instead of a schema change.
--
-- WHAT IT FIXES. The blob is ONE document with last-writer-wins over the
-- whole of it: two devices that both change something offline do not merge —
-- the second uploader wins outright, including for categories it never
-- touched. Per ROW, that conflict shrinks to the single item both devices
-- actually touched, and everything else on both sides survives. That is the
-- difference between a backup and a sync, and it is why X-shaped apps store
-- rows rather than documents.
--
-- THE CLOCK IS THE SERVER'S. `updated_at` is stamped by a trigger, never by
-- the client, so "last write wins" means the last write to REACH THE SERVER
-- — not whichever device has the furthest-ahead clock. A client-supplied
-- timestamp would let a phone with a wrong clock win every conflict for
-- ever, and there would be no way to tell that from working correctly.
--
-- DELETES ARE TOMBSTONES. A row removed outright would come straight back
-- from any device that still had it locally, so `deleted` is a flag and the
-- row keeps its place in the incremental fetch. That is also what lets a
-- delete made on one device reach the others at all.

create table if not exists public.user_items (
  -- Never taken from the client: filled from the caller's own JWT, so a
  -- device cannot write into somebody else's items even before RLS looks.
  owner_phone text not null default (auth.jwt() ->> 'phone'),
  -- Which store this belongs to ('bookmark', 'mute', …). The one column that
  -- makes this generic.
  kind        text not null,
  -- The store's own id for the thing. Unique within a kind, per owner.
  item_id     text not null,
  payload     jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false,
  primary key (owner_phone, kind, item_id)
);

-- The incremental read: "everything of mine, of this kind, changed since X".
create index if not exists user_items_sync_idx
  on public.user_items (owner_phone, kind, updated_at);

-- The server's clock, on every write. See the header: a client-supplied
-- timestamp hands every conflict to whichever device is furthest ahead.
create or replace function public.user_items_touch()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists user_items_touch on public.user_items;
create trigger user_items_touch
  before insert or update on public.user_items
  for each row execute function public.user_items_touch();

alter table public.user_items enable row level security;

-- The community_structure.sql lesson, applied from the start: Supabase grants
-- table-wide privileges to `anon` on every new table, and a policy scoped
-- `to authenticated` only means no policy ever MATCHES an anon caller — the
-- raw grant sits there waiting for the day a policy changes.
revoke all on table public.user_items from anon;
revoke all on table public.user_items from authenticated;
grant select, insert, delete on table public.user_items to authenticated;
-- Column-scoped UPDATE: an edit may change the thing or retire it. It can
-- never move a row to a different owner, a different kind or a different id,
-- and it can never set its own timestamp — the trigger owns that.
grant update (payload, deleted) on table public.user_items to authenticated;

-- Yours and nobody else's, for every verb. There is no sharing model here at
-- all: these are one account's own lists.
drop policy if exists user_items_own on public.user_items;
create policy user_items_own on public.user_items
  for all to authenticated
  using (owner_phone = auth.jwt() ->> 'phone')
  with check (owner_phone = auth.jwt() ->> 'phone');
