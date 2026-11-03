-- CONNECTD Event Tracker: database setup for Supabase.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.

-- One row per tracker section (commercial, pnl, programme, participants, marketing, ops).
create table if not exists public.tracker (
  key text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Emails allowed to see everything and edit.
create table if not exists public.editors (
  email text primary key
);

alter table public.tracker enable row level security;
alter table public.editors enable row level security;  -- no policies: only reachable through is_editor()

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.editors where lower(email) = lower(auth.jwt() ->> 'email'));
$$;
grant execute on function public.is_editor() to authenticated;

drop policy if exists "editors read" on public.tracker;
drop policy if exists "editors insert" on public.tracker;
drop policy if exists "editors update" on public.tracker;
create policy "editors read" on public.tracker for select to authenticated using (public.is_editor());
create policy "editors insert" on public.tracker for insert to authenticated with check (public.is_editor());
create policy "editors update" on public.tracker for update to authenticated using (public.is_editor()) with check (public.is_editor());

-- What signed-in viewers (sales and contractor views) get: packages, booths and partner names,
-- participant profile and the programme. No deal values, payments, salespeople, notes, speakers or P&L.
create or replace function public.public_tracker() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'commercial', (
      select jsonb_build_object(
        'tiers', coalesce((select jsonb_agg(jsonb_build_object('id', t->'id', 'name', t->'name', 'price', t->'price', 'booths', t->'booths', 'slots', t->'slots'))
                           from jsonb_array_elements(c.data->'tiers') t), '[]'::jsonb),
        'islands', coalesce(c.data->'islands', '[]'::jsonb),
        'partners', coalesce((select jsonb_agg(jsonb_build_object('id', p->'id', 'name', p->'name', 'status', p->'status', 'tier', p->'tier',
                                                                  'island', p->'island', 'booths', p->'booths', 'boothNo', p->'boothNo', 'logo', p->'logo'))
                              from jsonb_array_elements(c.data->'partners') p where p->>'status' in ('Confirmed', 'Negotiating')), '[]'::jsonb),
        'updatedAt', c.data->'updatedAt')
      from public.tracker c where c.key = 'commercial'),
    'participants', (select data from public.tracker where key = 'participants'),
    'programme', (
      select jsonb_build_object('agenda', coalesce(g.data->'agenda', '[]'::jsonb), 'days', coalesce(g.data->'days', '[]'::jsonb),
                                'cdDate', g.data->'cdDate', 'cdTime', g.data->'cdTime', 'cdVenue', g.data->'cdVenue', 'cdLabel', g.data->'cdLabel',
                                'updatedAt', g.data->'updatedAt')
      from public.tracker g where g.key = 'programme')
  ) end;
$$;
grant execute on function public.public_tracker() to authenticated;

-- Live updates for editors.
do $$ begin
  alter publication supabase_realtime add table public.tracker;
exception when duplicate_object then null; end $$;

-- Partner logos: anyone can view, only editors can upload or remove.
insert into storage.buckets (id, name, public) values ('logos', 'logos', true) on conflict (id) do nothing;
drop policy if exists "editors upload logos" on storage.objects;
drop policy if exists "editors update logos" on storage.objects;
drop policy if exists "editors delete logos" on storage.objects;
create policy "editors upload logos" on storage.objects for insert to authenticated with check (bucket_id = 'logos' and public.is_editor());
create policy "editors update logos" on storage.objects for update to authenticated using (bucket_id = 'logos' and public.is_editor());
create policy "editors delete logos" on storage.objects for delete to authenticated using (bucket_id = 'logos' and public.is_editor());

-- Contractor link (#contractor) opens without sign-in: booth layout only.
-- Partner names, booth numbers and status; no prices, tiers, salespeople, notes or P&L.
create or replace function public.contractor_layout() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('commercial', jsonb_build_object(
    'islands', coalesce(c.data->'islands', '[]'::jsonb),
    'tiers', '[]'::jsonb,
    'partners', coalesce((select jsonb_agg(jsonb_build_object('id', p->'id', 'name', p->'name', 'status', p->'status',
                                                              'island', p->'island', 'booths', p->'booths', 'boothNo', p->'boothNo'))
                          from jsonb_array_elements(c.data->'partners') p where p->>'status' in ('Confirmed', 'Negotiating')), '[]'::jsonb),
    'updatedAt', c.data->'updatedAt'))
  from public.tracker c where c.key = 'commercial';
$$;
grant execute on function public.contractor_layout() to anon, authenticated;
