-- CONNECTD Event Tracker: which tabs each staff member can open (Settings -> Tab access).
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again.
-- Run it after schema.sql, finance-access.sql and daily-progress.sql. If you re-run either of those two later, run this one again after.
-- Staff = people in Daily progress who are not tracker admins. They always have Daily progress; each tick here adds one more tab,
-- which they can read and edit. Commercial comes without deal values, collections or target (the same as admins without P&L access).
-- Tracker admins are not affected: they keep every tab, and P&L still needs P&L access.

-- 1. One row per person per extra tab. No policies: only the functions below read or change it.
do $$
declare fresh boolean := to_regclass('public.tab_access') is null;
begin
  create table if not exists public.tab_access (
    email text not null references public.dp_people (email) on delete cascade,
    tab text not null check (tab in ('commercial', 'programme', 'participants', 'marketing', 'ops')),
    primary key (email, tab)
  );
  alter table public.tab_access enable row level security;
  -- First run only: everyone in a department with the old "Marketing tab" tick keeps Marketing performance.
  if fresh then
    insert into public.tab_access (email, tab)
    select p.email, 'marketing' from public.dp_people p join public.dp_departments d on d.id = p.dept_id
    where d.marketing and not exists (select 1 from public.editors e where lower(e.email) = p.email)
    on conflict do nothing;
  end if;
end $$;
-- The department tick is replaced by the grid, so it no longer gives access to anyone.
update public.dp_departments set marketing = false where marketing;

-- 2. Does the caller (an active staff member) have this tab ticked?
create or replace function public.staff_has_tab(p_tab text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tab_access a join public.dp_people p on p.email = a.email
                 where a.email = public.dp_my_email() and p.active and a.tab = p_tab);
$$;
grant execute on function public.staff_has_tab(text) to authenticated;

-- Kept for the Daily progress functions that still ask "is this person on the marketing team".
create or replace function public.dp_is_marketer() returns boolean
language sql stable security definer set search_path = public as $$
  select public.staff_has_tab('marketing');
$$;

-- The caller's tabs, for the page to build its menu. Admins get every tab here; P&L is still checked separately.
create or replace function public.my_tabs() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.is_editor() then '["commercial", "programme", "participants", "marketing", "ops"]'::jsonb
    else coalesce((select jsonb_agg(a.tab order by a.tab) from public.tab_access a join public.dp_people p on p.email = a.email
                   where a.email = public.dp_my_email() and p.active), '[]'::jsonb) end;
$$;
grant execute on function public.my_tabs() to authenticated;

-- 3. Staff read and save only the sections they have ticked. Commercial goes through the functions in step 4 instead.
drop policy if exists "marketers read marketing" on public.tracker;
drop policy if exists "marketers insert marketing" on public.tracker;
drop policy if exists "marketers update marketing" on public.tracker;
drop policy if exists "staff read ticked tabs" on public.tracker;
drop policy if exists "staff insert ticked tabs" on public.tracker;
drop policy if exists "staff update ticked tabs" on public.tracker;
create policy "staff read ticked tabs" on public.tracker for select to authenticated
  using (key in ('programme', 'participants', 'marketing', 'ops') and public.staff_has_tab(key));
create policy "staff insert ticked tabs" on public.tracker for insert to authenticated
  with check (key in ('programme', 'participants', 'marketing', 'ops') and public.staff_has_tab(key));
create policy "staff update ticked tabs" on public.tracker for update to authenticated
  using (key in ('programme', 'participants', 'marketing', 'ops') and public.staff_has_tab(key))
  with check (key in ('programme', 'participants', 'marketing', 'ops') and public.staff_has_tab(key));

-- 4. Commercial without money figures (as in finance-access.sql), now also for staff with Commercial ticked.
create or replace function public.commercial_safe() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not (public.is_editor() or public.staff_has_tab('commercial')) then null else (
    select jsonb_set(c.data - 'target', '{partners}',
      coalesce((select jsonb_agg(p - 'value' - 'collected' order by i)
                from jsonb_array_elements(coalesce(c.data -> 'partners', '[]'::jsonb)) with ordinality as t(p, i)), '[]'::jsonb))
    from public.tracker c where c.key = 'commercial') end;
$$;
grant execute on function public.commercial_safe() to authenticated;

create or replace function public.commercial_save_safe(new_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old jsonb; merged jsonb;
begin
  if not (public.is_editor() or public.staff_has_tab('commercial')) then raise exception 'You do not have access to Commercial'; end if;
  select data into old from public.tracker where key = 'commercial' for update;
  old := coalesce(old, '{}'::jsonb);
  merged := new_data - 'target';
  if old ? 'target' then merged := merged || jsonb_build_object('target', old -> 'target'); end if;
  merged := jsonb_set(merged, '{partners}', coalesce((
    select jsonb_agg((p - 'value' - 'collected') || coalesce((
        select jsonb_strip_nulls(jsonb_build_object('value', o -> 'value', 'collected', o -> 'collected'))
        from jsonb_array_elements(coalesce(old -> 'partners', '[]'::jsonb)) o where o ->> 'id' = p ->> 'id' limit 1), '{}'::jsonb)
      order by i)
    from jsonb_array_elements(coalesce(new_data -> 'partners', '[]'::jsonb)) with ordinality as t(p, i)), '[]'::jsonb));
  insert into public.tracker (key, data, updated_at) values ('commercial', merged, now())
  on conflict (key) do update set data = excluded.data, updated_at = now();
end $$;
grant execute on function public.commercial_save_safe(jsonb) to authenticated;

-- 5. The grid in Settings. Directors (and admins) see and change it; nobody but an admin can change their own row.
-- Returns {access: {email: [tabs]}, admins: [emails]}; admins are listed so the grid can show them as having every tab.
create or replace function public.tab_access_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.dp_is_director() then null else jsonb_build_object(
    'access', coalesce((select jsonb_object_agg(email, tabs) from (select email, jsonb_agg(tab order by tab) tabs from public.tab_access group by email) x), '{}'::jsonb),
    'admins', coalesce((select jsonb_agg(lower(email) order by lower(email)) from public.editors), '[]'::jsonb)) end;
$$;
grant execute on function public.tab_access_list() to authenticated;

create or replace function public.set_tab_access(p_email text, p_tab text, p_allow boolean) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email));
begin
  if not public.dp_is_director() then raise exception 'Only directors can change tab access'; end if;
  if e = public.dp_my_email() and not public.is_editor() then raise exception 'You cannot change your own tab access'; end if;
  if p_tab not in ('commercial', 'programme', 'participants', 'marketing', 'ops') then raise exception 'Unknown tab'; end if;
  if not exists (select 1 from public.dp_people where email = e) then raise exception 'Add this person under Team first'; end if;
  if p_allow then insert into public.tab_access (email, tab) values (e, p_tab) on conflict do nothing;
  else delete from public.tab_access where email = e and tab = p_tab; end if;
end $$;
grant execute on function public.set_tab_access(text, text, boolean) to authenticated;
