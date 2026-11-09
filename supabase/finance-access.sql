-- CONNECTD Event Tracker: finance access.
-- Only finance admins can see the P&L and the money in Commercial (deal values, amounts collected, sales target).
-- Other admins keep editing partners, booths and status; the money they can't see is kept as it is when they save.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again.

-- 1. Who counts as a finance admin.
create table if not exists public.finance_admins (email text primary key);
alter table public.finance_admins enable row level security;  -- no policies: only reachable through the functions below

-- The first finance admins are added from a private copy of this script (emails stay out of the public repo):
-- insert into public.finance_admins (email) values ('name@example.com') on conflict do nothing;

-- A finance admin must also still be an admin.
create or replace function public.is_finance() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_editor() and exists (select 1 from public.finance_admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;
grant execute on function public.is_finance() to authenticated;

-- 2. The P&L and Commercial rows are readable and writable by finance admins only. Every other row stays open to all admins.
drop policy if exists "editors read" on public.tracker;
drop policy if exists "editors insert" on public.tracker;
drop policy if exists "editors update" on public.tracker;
create policy "editors read" on public.tracker for select to authenticated
  using (public.is_editor() and (key not in ('pnl', 'commercial') or public.is_finance()));
create policy "editors insert" on public.tracker for insert to authenticated
  with check (public.is_editor() and (key not in ('pnl', 'commercial') or public.is_finance()));
create policy "editors update" on public.tracker for update to authenticated
  using (public.is_editor() and (key not in ('pnl', 'commercial') or public.is_finance()))
  with check (public.is_editor() and (key not in ('pnl', 'commercial') or public.is_finance()));

-- 3. Commercial for admins without finance access: the same data with deal value, collected and target taken out.
create or replace function public.commercial_safe() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.is_editor() then null else (
    select jsonb_set(c.data - 'target', '{partners}',
      coalesce((select jsonb_agg(p - 'value' - 'collected' order by i)
                from jsonb_array_elements(coalesce(c.data -> 'partners', '[]'::jsonb)) with ordinality as t(p, i)), '[]'::jsonb))
    from public.tracker c where c.key = 'commercial') end;
$$;
grant execute on function public.commercial_safe() to authenticated;

-- Their save: take what they sent, drop any money fields in it, and put back the stored target and each partner's stored value and collected.
-- New partners they add start without a deal value until a finance admin fills it in.
create or replace function public.commercial_save_safe(new_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old jsonb; merged jsonb;
begin
  if not public.is_editor() then raise exception 'Only admins can edit the tracker'; end if;
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

-- 4. Managing finance access from the Admins page.
create or replace function public.finance_list() returns table (email text)
language sql stable security definer set search_path = public as $$
  select f.email from public.finance_admins f where public.is_editor() order by f.email;
$$;

-- Only a finance admin can give or remove finance access, and not for themselves.
create or replace function public.set_finance(target text, allow boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_finance() then raise exception 'Only finance admins can change P&L access'; end if;
  if lower(trim(target)) = lower(auth.jwt() ->> 'email') then raise exception 'You cannot change your own P&L access'; end if;
  if allow then
    if not exists (select 1 from public.editors where lower(email) = lower(trim(target))) then raise exception 'Only admins can be given P&L access'; end if;
    insert into public.finance_admins (email) values (lower(trim(target))) on conflict do nothing;
  else
    delete from public.finance_admins where lower(email) = lower(trim(target));
  end if;
end $$;
grant execute on function public.finance_list(), public.set_finance(text, boolean) to authenticated;

-- Removing an admin also removes their finance access, so it doesn't come back if they're approved again later.
create or replace function public.remove_admin(target text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_editor() then raise exception 'Only admins can remove admins'; end if;
  if lower(trim(target)) = lower(auth.jwt() ->> 'email') then raise exception 'You cannot remove yourself'; end if;
  delete from public.editors where lower(email) = lower(trim(target));
  delete from public.finance_admins where lower(email) = lower(trim(target));
end $$;
