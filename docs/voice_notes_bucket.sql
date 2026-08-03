-- Storage bucket for sealed voice notes longer than the relay envelope.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor → New query → Run).
--
-- WHY A BUCKET. A short voice note rides the message relay inline, sealed like
-- a photo. A long one cannot: one broadcast caps out around a quarter megabyte
-- and a few minutes of audio is several of that, each chunk a mailbox row per
-- offline recipient, one lost chunk a broken note. So a long note goes here
-- instead — the same bucket machinery marketplace videos and chat backups use.
--
-- WHAT'S IN IT. One object per note, at a random name ending .sealed. The
-- bytes are AES-256-GCM ciphertext sealed with a PER-NOTE random key that
-- never touches this bucket: it travels inside the E2E-encrypted chat message
-- that names the object, so only that conversation's devices can unseal it.
-- The bucket operator sees ciphertext, and even the object path leaks nothing
-- without the key. Plaintext audio must never be stored here.

-- Private bucket; 24 MB per object comfortably covers a sealed 12 MB note
-- (base64 + encryption inflate ~4/3) and stops runaways.
insert into storage.buckets (id, name, public, file_size_limit)
values ('voice-notes', 'voice-notes', false, 25165824)
on conflict (id) do update
  set public = false,
      file_size_limit = 25165824;

-- Access model, matching the relay: with REQUIRE_OTP off there is no verified
-- caller for RLS to bind to, so the seal is the real protection — exactly as
-- it is for relay traffic. The per-note key lives only in the sealed message.
drop policy if exists voice_notes_read on storage.objects;
create policy voice_notes_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'voice-notes');

drop policy if exists voice_notes_insert on storage.objects;
create policy voice_notes_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'voice-notes');

drop policy if exists voice_notes_update on storage.objects;
create policy voice_notes_update on storage.objects
  for update to anon, authenticated
  using (bucket_id = 'voice-notes');

drop policy if exists voice_notes_delete on storage.objects;
create policy voice_notes_delete on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'voice-notes');
