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
-- Without this, a user can overwrite their backup but never delete it
-- (deletes silently affect zero rows while still returning 204).
create policy "sync_blobs_delete" on public.sync_blobs
  for delete using (true);

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

-- =============================================================================
-- Crash reports
-- =============================================================================
-- Dart-side crashes and errors, reported by the app so problems can be read
-- from the dashboard instead of reconstructed from user descriptions. Rows
-- carry an error, a trimmed stack, build stamp, platform — never message
-- content or phone numbers. The client rate-limits itself; size caps here
-- are the backstop.
create table if not exists public.crash_reports (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  error       text not null check (char_length(error) <= 2000),
  stack       text not null default '' check (char_length(stack) <= 8000),
  context     text not null default '',
  app_version text not null default '',
  platform    text not null default '',
  mode        text not null default ''
);

alter table public.crash_reports enable row level security;

-- Anyone with the app (publishable key) may file a report...
drop policy if exists crash_reports_insert on public.crash_reports;
create policy crash_reports_insert on public.crash_reports
  for insert to anon, authenticated with check (true);

-- ...and reports are readable with the same key, so whoever is debugging can
-- pull them without service-role access. Crash stacks contain no user data.
drop policy if exists crash_reports_read on public.crash_reports;
create policy crash_reports_read on public.crash_reports
  for select to anon, authenticated using (true);
