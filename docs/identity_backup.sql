-- ============================================================================
-- Encryption recovery (run whole file in Supabase SQL editor; idempotent)
-- ============================================================================
-- One sealed blob per account: the device's identity private key, encrypted
-- ON THE DEVICE under a recovery code the app minted and only the user holds
-- (PBKDF2-HMAC-SHA256 at 120k rounds over a random salt, then AES-256-GCM).
-- The server stores ciphertext it can never open — 80 bits of code entropy
-- stand between a leaked row and the key. This is what lets a reinstall or a
-- new phone restore the SAME identity instead of minting a fresh one, which
-- is the root cause of "sealed to a key this device no longer has".
--
-- Access is the part worth being careful about, because a REPLACED blob is a
-- broken restore (nothing leaks — the thief's blob won't open with the
-- user's code — but the user's backup is gone):
--
--   * Phone accounts ride their session: RLS pins insert/update/select to
--     the JWT's own number, so nobody can read, plant, or replace anybody
--     else's backup.
--   * Numberless accounts (minted '00…' codes) have no session at all, so
--     two SECURITY DEFINER RPCs are their only door, and both refuse
--     anything that is not a '00' inbox. Writes are first-come: the blob
--     can be created but never overwritten anonymously.

create table if not exists public.identity_backups (
  inbox      text primary key,               -- phone digits / account code
  blob       text not null,                  -- sealed archive, never plaintext
  updated_at timestamptz not null default now()
);

alter table public.identity_backups enable row level security;

-- Supabase grants every new public table to anon and authenticated; the
-- policies below only mean anything once that blanket grant is gone.
revoke all on table public.identity_backups from anon;
revoke all on table public.identity_backups from authenticated;
grant select, insert, update on public.identity_backups to authenticated;

drop policy if exists identity_backups_own_select on public.identity_backups;
create policy identity_backups_own_select on public.identity_backups
  for select to authenticated
  using (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

drop policy if exists identity_backups_own_insert on public.identity_backups;
create policy identity_backups_own_insert on public.identity_backups
  for insert to authenticated
  with check (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

drop policy if exists identity_backups_own_update on public.identity_backups;
create policy identity_backups_own_update on public.identity_backups
  for update to authenticated
  using (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'))
  with check (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

-- The numberless door. First write wins: an anonymous caller can create a
-- '00' account's backup but never replace one, because "anonymous" and
-- "allowed to overwrite" cannot coexist without some proof of ownership,
-- and a numberless account has none to offer.
create or replace function public.put_identity_backup(inboxv text, blobv text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if inboxv is null or inboxv !~ '^00\d+$' or blobv is null or blobv = '' then
    return false;
  end if;
  insert into public.identity_backups (inbox, blob)
    values (inboxv, blobv)
    on conflict (inbox) do nothing;
  return exists (
    select 1 from public.identity_backups
    where inbox = inboxv and blob = blobv);
end $$;

-- Reading is also '00'-only: a REAL number's blob is reachable only through
-- its owner's session, so an anonymous caller can never even fetch the
-- ciphertext to brute-force offline.
create or replace function public.get_identity_backup(inboxv text)
returns text
language sql security definer set search_path = public as $$
  select blob from public.identity_backups
  where inbox = inboxv and inboxv ~ '^00\d+$';
$$;
