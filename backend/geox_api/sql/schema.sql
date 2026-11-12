-- GeoX, Postgres schema with row level security.
--
-- Run this in the Supabase SQL editor. The API can also run on SQLite with no
-- setup at all, which is what the tests use; this is the version for anything
-- that more than one person touches.
--
-- The policies below are the point of this file. Without them every row in a
-- Supabase project is readable by anyone holding the anon key.

create table if not exists public.suggested_sites (
    id          bigint generated always as identity primary key,
    user_id     uuid references auth.users(id) on delete set null,
    email       text,
    name        text        not null check (length(trim(name)) between 2 and 120),
    latitude    double precision not null check (latitude between -90 and 90),
    longitude   double precision not null check (longitude between -180 and 180),
    category    text,
    why         text        not null check (length(trim(why)) >= 10),
    status      text        not null default 'pending'
                            check (status in ('pending','accepted','rejected')),
    created_at  timestamptz not null default now()
);

create table if not exists public.shortlists (
    code        text primary key,
    user_id     uuid references auth.users(id) on delete set null,
    target_id   text,
    site_ids    text[]      not null check (cardinality(site_ids) between 1 and 200),
    created_at  timestamptz not null default now()
);

create index if not exists suggested_sites_status_idx on public.suggested_sites(status);
create index if not exists suggested_sites_user_idx   on public.suggested_sites(user_id);

-- ---------------------------------------------------------------- security
alter table public.suggested_sites enable row level security;
alter table public.shortlists      enable row level security;

-- Anyone may read suggestions that have been accepted. Pending ones are
-- visible only to the person who sent them, so an unreviewed submission is not
-- published by accident.
drop policy if exists suggested_read on public.suggested_sites;
create policy suggested_read on public.suggested_sites
    for select
    using (status = 'accepted' or user_id = auth.uid());

-- Only a signed-in user may submit, only as themselves, and never straight to
-- accepted. Review is a separate step on purpose.
drop policy if exists suggested_insert on public.suggested_sites;
create policy suggested_insert on public.suggested_sites
    for insert
    with check (user_id = auth.uid() and status = 'pending');

-- A user may edit their own submission while it is still pending.
drop policy if exists suggested_update_own on public.suggested_sites;
create policy suggested_update_own on public.suggested_sites
    for update
    using (user_id = auth.uid() and status = 'pending')
    with check (user_id = auth.uid() and status = 'pending');

-- Moderation runs with the service role, which bypasses RLS. Do not hand the
-- service key to the app; keep review on the server or in the dashboard.

-- A shortlist is a list of public sites, so anyone with the code may open it.
-- The code is random, which is the only thing protecting it, so never put
-- anything private in one.
drop policy if exists shortlist_read on public.shortlists;
create policy shortlist_read on public.shortlists for select using (true);

drop policy if exists shortlist_insert on public.shortlists;
create policy shortlist_insert on public.shortlists
    for insert
    with check (user_id is null or user_id = auth.uid());

drop policy if exists shortlist_delete_own on public.shortlists;
create policy shortlist_delete_own on public.shortlists
    for delete using (user_id = auth.uid());
