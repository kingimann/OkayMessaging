-- Owner-editable legal documents (2026-08-06). The Terms of Service and
-- Privacy Policy, so the owner can update them from inside the app without
-- shipping a new build. A single row (id = 1).
--
-- READABLE BY EVERYONE — the app fetches the current text on launch, the same
-- way it fetches any public config; the documents are public policy. WRITABLE
-- ONLY by the `legal-set` Edge Function (service role), which first checks the
-- caller is the platform owner. No client write grants at all.
--
-- The `version` is what the acceptance gate compares against: bumping it (which
-- publishing does) asks every user to agree again.
--
-- Run this in the SQL editor, then paste the `legal-set` function. Until then
-- the app shows its built-in documents and the owner editor says it isn't set
-- up yet.
-- ---------------------------------------------------------------------------

create table if not exists public.legal_documents (
  id           int primary key default 1,
  terms        jsonb not null default '[]'::jsonb,
  privacy      jsonb not null default '[]'::jsonb,
  version      int  not null default 0,
  last_updated text not null default '',
  edited_at    timestamptz not null default now(),
  constraint legal_documents_singleton check (id = 1)
);

alter table public.legal_documents enable row level security;

-- Anyone may READ the current documents (public policy, fetched on launch).
drop policy if exists legal_documents_read on public.legal_documents;
create policy legal_documents_read on public.legal_documents
  for select using (true);
grant select on table public.legal_documents to anon, authenticated;

-- Nobody writes through the API. The legal-set function (service role, which
-- bypasses RLS) is the only writer, and it checks platform ownership first.
revoke insert, update, delete on table public.legal_documents
  from anon, authenticated;
