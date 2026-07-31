-- Storage bucket for encrypted chat backups.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor → New query → Run),
-- after docs/supabase_setup.sql.
--
-- WHY A BUCKET, NOT A TABLE. Chat backups are the only large, paid thing the
-- server holds. Storage buckets bill at ~$0.0213/GB where Postgres disk bills
-- at $0.125/GB — roughly 6× cheaper. Selling storage is only profitable at the
-- bucket rate, so backups live here and the small (free) communal sync blob
-- stays in the `sync_blobs` table.
--
-- WHAT'S IN IT. One object per account, named with the 256-bit HMAC of that
-- account's encryption key. The bytes are AES-256-GCM ciphertext the server
-- cannot read, exactly as before — moving backends changed the bill, not the
-- privacy model.

-- Private bucket: objects are never served over a public URL. A 50 MB per-file
-- ceiling is far above a text-only chat backup and stops a single object from
-- running away.
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-backups', 'chat-backups', false, 52428800)
on conflict (id) do update
  set public = false,
      file_size_limit = 52428800;

-- Access model, matching `sync_blobs`: the object name is an unguessable HMAC
-- of a key only the user holds, so possession of the name IS the capability to
-- read/write that object — and the contents are end-to-end encrypted anyway.
-- (With no server-side auth in this project, RLS cannot bind an object to a
-- verified caller; the name's entropy is what protects it.)
drop policy if exists chat_backups_read on storage.objects;
create policy chat_backups_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'chat-backups');

drop policy if exists chat_backups_insert on storage.objects;
create policy chat_backups_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'chat-backups');

drop policy if exists chat_backups_update on storage.objects;
create policy chat_backups_update on storage.objects
  for update to anon, authenticated
  using (bucket_id = 'chat-backups');

-- Without delete, a user could overwrite their backup but never remove it.
drop policy if exists chat_backups_delete on storage.objects;
create policy chat_backups_delete on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'chat-backups');

-- ----------------------------------------------------------------------------
-- Optional: usage accounting against the bucket
-- ----------------------------------------------------------------------------
-- If you ran docs/storage_usage_setup.sql, this view reports what the bucket
-- actually holds — the number your Supabase bill is computed from.
--
-- security_invoker, and granted to NOBODY. A view without it runs with its
-- owner's privileges, which is what Supabase's advisor flags as CRITICAL: it
-- reads storage.objects past the caller's RLS, so any signed-in client could
-- count and size every backup in the bucket. This is an operator's number,
-- read in the SQL editor by whoever owns the project.
create or replace view public.chat_backup_totals
with (security_invoker = on) as
  select
    count(*)                                          as backups,
    coalesce(sum((metadata->>'size')::bigint), 0)     as total_bytes,
    round(coalesce(sum((metadata->>'size')::bigint), 0)
          / 1073741824.0, 3)                          as total_gb
  from storage.objects
  where bucket_id = 'chat-backups';

revoke all on public.chat_backup_totals from anon, authenticated;
