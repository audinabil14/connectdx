-- CONNECTD Event Tracker: activity log (Settings -> Activity report).
-- The database itself records who changed what, on every save, so nothing can skip it.
-- It keeps the names of the fields that changed, never the amounts. P&L entries are shown to finance admins only.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again. Run finance-access.sql first.

-- 1. Where the log is kept. No policies: it is only reachable through activity_report() below.
create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  email text not null,
  section text not null,
  changes jsonb not null default '[]'::jsonb
);
create index if not exists activity_log_at on public.activity_log (at desc);
alter table public.activity_log enable row level security;

-- 2. What changed between two saved copies of a section, as a list like
--    [{"op":"changed","list":"partners","name":"Pandai","fields":["status","notes"],"to":"Confirmed"}, {"op":"set","field":"target"}].
--    Lists of items with an id (partners, speakers, workstreams…) are compared item by item; anything else is just named.
create or replace function public.activity_diff(o jsonb, n jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  out jsonb := '[]'::jsonb;
  k text; ov jsonb; nv jsonb; it jsonb; old_it jsonb; f text; fields jsonb; before int;
  label constant text := 'coalesce(nullif(x->>''name'',''''), nullif(x->>''title'',''''), nullif(x->>''item'',''''), nullif(trim(concat_ws('' '', x->>''channel'', x->>''period'')),''''), x->>''date'', ''(unnamed)'')';
begin
  o := coalesce(o, '{}'::jsonb); n := coalesce(n, '{}'::jsonb);
  for k in select key from jsonb_each(o) union select key from jsonb_each(n) loop
    continue when k = 'updatedAt';
    ov := o -> k; nv := n -> k;
    continue when ov is not distinct from nv;
    if coalesce(jsonb_typeof(ov), 'array') = 'array' and coalesce(jsonb_typeof(nv), 'array') = 'array'
       and exists (select 1 from jsonb_array_elements(coalesce(ov, '[]') || coalesce(nv, '[]')) e where jsonb_typeof(e) = 'object' and e ? 'id') then
      before := jsonb_array_length(out);
      for it in select e from jsonb_array_elements(coalesce(nv, '[]')) e loop
        select e into old_it from jsonb_array_elements(coalesce(ov, '[]')) e where e ->> 'id' = it ->> 'id' limit 1;
        if old_it is null then
          execute 'select ' || label || ' from (select $1 as x) s' into f using it;
          out := out || jsonb_build_array(jsonb_build_object('op', 'added', 'list', k, 'name', f));
        elsif old_it <> it then
          select coalesce(jsonb_agg(fk order by fk), '[]') into fields from (
            select key fk from jsonb_each(old_it) union select key from jsonb_each(it)) s
            where fk <> 'updatedAt' and (old_it -> fk) is distinct from (it -> fk);
          continue when jsonb_array_length(fields) = 0;
          execute 'select ' || label || ' from (select $1 as x) s' into f using it;
          out := out || jsonb_build_array(jsonb_build_object('op', 'changed', 'list', k, 'name', f, 'fields', fields)
            || case when fields ? 'status' then jsonb_build_object('to', it -> 'status') else '{}' end);
        end if;
      end loop;
      for it in select e from jsonb_array_elements(coalesce(ov, '[]')) e
                where not exists (select 1 from jsonb_array_elements(coalesce(nv, '[]')) x where x ->> 'id' = e ->> 'id') loop
        execute 'select ' || label || ' from (select $1 as x) s' into f using it;
        out := out || jsonb_build_array(jsonb_build_object('op', 'removed', 'list', k, 'name', f));
      end loop;
      -- Same items, nothing edited: the order changed.
      if jsonb_array_length(out) = before then out := out || jsonb_build_array(jsonb_build_object('op', 'reordered', 'list', k)); end if;
    else
      out := out || jsonb_build_array(jsonb_build_object('op', 'set', 'field', k));
    end if;
  end loop;
  return out;
end $$;
revoke execute on function public.activity_diff(jsonb, jsonb) from public;

-- 3. Record every tracker save. Signed-in saves carry the person's email; anything else (e.g. the SQL Editor) shows as "system".
create or replace function public.log_tracker_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  c := public.activity_diff(case when tg_op = 'UPDATE' then old.data end, new.data);
  if jsonb_array_length(c) > 0 then
    insert into public.activity_log (email, section, changes) values (coalesce(auth.jwt() ->> 'email', 'system'), new.key, c);
  end if;
  return null;
end $$;
drop trigger if exists log_tracker_change on public.tracker;
create trigger log_tracker_change after insert or update on public.tracker for each row execute function public.log_tracker_change();

-- 4. Record admin changes: approvals, removals, rejected requests and P&L access.
create or replace function public.log_admin_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; op text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  op := case tg_table_name
    when 'editors' then case tg_op when 'INSERT' then 'admin_added' else 'admin_removed' end
    when 'finance_admins' then case tg_op when 'INSERT' then 'finance_on' else 'finance_off' end
    else 'request_rejected' end;
  insert into public.activity_log (email, section, changes)
  values (coalesce(auth.jwt() ->> 'email', 'system'), 'admins', jsonb_build_array(jsonb_build_object('op', op, 'name', r.email)));
  return null;
end $$;
drop trigger if exists log_admin_change on public.editors;
create trigger log_admin_change after insert or delete on public.editors for each row execute function public.log_admin_change();
drop trigger if exists log_admin_change on public.finance_admins;
create trigger log_admin_change after insert or delete on public.finance_admins for each row execute function public.log_admin_change();
drop trigger if exists log_admin_change on public.admin_denied;
create trigger log_admin_change after insert on public.admin_denied for each row execute function public.log_admin_change();
revoke execute on function public.log_tracker_change(), public.log_admin_change() from public;

-- 5. The report: admins only, newest first. P&L entries only for finance admins.
create or replace function public.activity_report(since timestamptz default null, max_rows int default 1000)
returns table (id bigint, at timestamptz, email text, section text, changes jsonb)
language sql stable security definer set search_path = public as $$
  select l.id, l.at, l.email, l.section, l.changes from public.activity_log l
  where public.is_editor() and (l.section <> 'pnl' or public.is_finance()) and (since is null or l.at >= since)
  order by l.at desc, l.id desc limit least(greatest(coalesce(max_rows, 1000), 1), 5000);
$$;
grant execute on function public.activity_report(timestamptz, int) to authenticated;
