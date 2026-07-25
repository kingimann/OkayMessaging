-- One-time setup for Okay Messaging's encrypted cloud sync.
-- Run this in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Privacy model: the client encrypts everything with AES-256-GCM using a key
-- derived (PBKDF2, 120k rounds) from the user's sync passphrase BEFORE
-- upload. The row id is an HMAC of that key, so rows can't be tied to a
-- person. The server only ever stores ciphertext it cannot read.

create table if not exists public.sync_blobs (
  id text primary key,
  data text not null,
  updated_at timestamptz not null default now()
);

alter table public.sync_blobs enable row level security;

-- Blob ids are 256-bit HMACs: unguessable, so possession of the id is the
-- capability to read/write that blob (contents are E2E-encrypted anyway).
create policy "sync_blobs_select" on public.sync_blobs
  for select using (true);
create policy "sync_blobs_insert" on public.sync_blobs
  for insert with check (true);
create policy "sync_blobs_update" on public.sync_blobs
  for update using (true);

-- Keep updated_at fresh on upsert.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists sync_blobs_touch on public.sync_blobs;
create trigger sync_blobs_touch before update on public.sync_blobs
  for each row execute function public.touch_updated_at();
