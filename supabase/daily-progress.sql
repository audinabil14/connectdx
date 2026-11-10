-- CONNECTD Event Tracker: Daily progress (team updates before 4:00 PM, department submission, management follow-up).
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again. Run schema.sql first.
-- The tables have no policies: everything goes through the functions below, which check who is asking.
--   Member      updates their own tasks and sees their department.
--   Dept PIC    also submits the department's daily update.
--   Project Mgr also sees and comments on tasks in the projects they manage.
--   Director    sees everything, comments, and manages departments, projects and people. Tracker admins count as directors here.
-- People who are not tracker admins are "staff": once added here, they sign in and see only the Daily progress tab.

-- 1. Set-up lists, managed from Settings -> Team & departments.
create table if not exists public.dp_departments (
  id text primary key,
  name text not null,
  sort int not null default 0,
  active boolean not null default true
);
create table if not exists public.dp_projects (
  id text primary key,
  name text not null,
  pm_email text,
  active boolean not null default true
);
create table if not exists public.dp_people (
  email text primary key,
  name text not null default '',
  dept_id text references public.dp_departments (id),
  role text not null default 'member' check (role in ('member', 'pic', 'pm', 'director')),
  active boolean not null default true
);
insert into public.dp_departments (id, name, sort) values
  ('bd', 'Business Development', 1), ('marketing', 'Marketing', 2), ('ops', 'Operations', 3), ('mgmt', 'Management', 4)
on conflict (id) do nothing;
insert into public.dp_projects (id, name) values ('connectdx', 'CONNECTD X') on conflict (id) do nothing;

-- 2. The work. A task is kept once and carried to the next day until it is Done; each day's progress is a new update row.
create table if not exists public.dp_tasks (
  id bigint generated always as identity primary key,
  title text not null,
  dept_id text not null references public.dp_departments (id),
  project_id text references public.dp_projects (id),
  pic_email text not null,
  created_by text not null,
  created_at timestamptz not null default now(),
  created_day date not null default (now() at time zone 'Asia/Kuala_Lumpur')::date
);
-- One update per task per day. Saving again the same day edits that day's update; earlier days stay as they were.
create table if not exists public.dp_updates (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.dp_tasks (id) on delete cascade,
  day date not null,
  status text not null check (status in ('done', 'progress', 'blocked')),
  remarks text not null default '',
  next_action text not null default '',
  author text not null,
  at timestamptz not null default now(),
  edited_at timestamptz,
  unique (task_id, day)
);
-- One final submission per department per day. Never overwritten.
create table if not exists public.dp_submissions (
  dept_id text not null references public.dp_departments (id),
  day date not null,
  submitted_by text not null,
  at timestamptz not null default now(),
  primary key (dept_id, day)
);
create table if not exists public.dp_comments (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.dp_tasks (id) on delete cascade,
  author text not null,
  body text not null,
  at timestamptz not null default now()
);
create index if not exists dp_updates_task on public.dp_updates (task_id, day desc);
create index if not exists dp_comments_task on public.dp_comments (task_id, at);
alter table public.dp_departments enable row level security;
alter table public.dp_projects enable row level security;
alter table public.dp_people enable row level security;
alter table public.dp_tasks enable row level security;
alter table public.dp_updates enable row level security;
alter table public.dp_submissions enable row level security;
alter table public.dp_comments enable row level security;

-- 3. Who is asking.
create or replace function public.dp_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $$;

create or replace function public.dp_my_email() returns text
language sql stable as $$ select lower(auth.jwt() ->> 'email') $$;

create or replace function public.dp_is_director() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_editor() or exists (select 1 from public.dp_people where email = public.dp_my_email() and active and role = 'director');
$$;

-- Can the caller see this task (and its updates)?
create or replace function public.dp_can_see(t public.dp_tasks) returns boolean
language sql stable security definer set search_path = public as $$
  select public.dp_is_director()
    or t.pic_email = public.dp_my_email()
    or exists (select 1 from public.dp_people p where p.email = public.dp_my_email() and p.active and p.dept_id = t.dept_id)
    or exists (select 1 from public.dp_projects j where j.id = t.project_id and lower(j.pm_email) = public.dp_my_email());
$$;

-- Comments are for the task's PIC, their department PIC, the project's PM and directors.
create or replace function public.dp_can_read_comments(t public.dp_tasks) returns boolean
language sql stable security definer set search_path = public as $$
  select public.dp_is_director()
    or t.pic_email = public.dp_my_email()
    or exists (select 1 from public.dp_people p where p.email = public.dp_my_email() and p.active and p.role = 'pic' and p.dept_id = t.dept_id)
    or exists (select 1 from public.dp_projects j where j.id = t.project_id and lower(j.pm_email) = public.dp_my_email());
$$;

-- Only directors and the project's PM add follow-ups.
create or replace function public.dp_can_comment(t public.dp_tasks) returns boolean
language sql stable security definer set search_path = public as $$
  select public.dp_is_director()
    or exists (select 1 from public.dp_projects j where j.id = t.project_id and lower(j.pm_email) = public.dp_my_email());
$$;

-- What the page needs to know about the caller, plus the set-up lists. Null for someone with no access.
create or replace function public.dp_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not (public.is_editor() or exists (select 1 from public.dp_people where email = public.dp_my_email() and active)) then null
  else jsonb_build_object(
    'email', public.dp_my_email(),
    'admin', public.is_editor(),
    'director', public.dp_is_director(),
    'person', (select to_jsonb(p) from public.dp_people p where p.email = public.dp_my_email()),
    'pmOf', coalesce((select jsonb_agg(j.id) from public.dp_projects j where lower(j.pm_email) = public.dp_my_email()), '[]'),
    'departments', coalesce((select jsonb_agg(to_jsonb(d) order by d.sort, d.name) from public.dp_departments d), '[]'),
    'projects', coalesce((select jsonb_agg(to_jsonb(j) order by j.name) from public.dp_projects j), '[]'),
    'people', coalesce((select jsonb_agg(jsonb_build_object('email', p.email, 'name', p.name, 'dept_id', p.dept_id, 'role', p.role, 'active', p.active) order by p.name)
                        from public.dp_people p), '[]')
  ) end;
$$;

-- 4. The day's board: every task the caller can see that was open that day, with its status as of that day.
--    A task stays on the board each day until the day it is marked Done; after that it is only in history.
create or replace function public.dp_board(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, public.dp_today()); me jsonb := public.dp_me();
begin
  if me is null then raise exception 'You do not have access to Daily progress'; end if;
  return jsonb_build_object(
    'day', d, 'today', public.dp_today(),
    'deadline', ((d + time '16:00') at time zone 'Asia/Kuala_Lumpur'),
    'tasks', coalesce((
      select jsonb_agg(x order by x ->> 'title') from (
        select jsonb_build_object(
          'id', t.id, 'title', t.title, 'dept_id', t.dept_id, 'project_id', t.project_id, 'pic', t.pic_email, 'created_day', t.created_day,
          'status', coalesce(cur.status, 'progress'),
          'today', (select to_jsonb(u) - 'task_id' from public.dp_updates u where u.task_id = t.id and u.day = d),
          'last', (select to_jsonb(u) - 'task_id' from public.dp_updates u where u.task_id = t.id and u.day < d order by u.day desc limit 1),
          'comments', case when public.dp_can_read_comments(t) then coalesce((
              select jsonb_agg(jsonb_build_object('id', c.id, 'author', c.author, 'body', c.body, 'at', c.at) order by c.at)
              from public.dp_comments c where c.task_id = t.id and (c.at at time zone 'Asia/Kuala_Lumpur')::date <= d), '[]') end,
          'canComment', public.dp_can_comment(t),
          'mine', t.pic_email = public.dp_my_email()) x
        from public.dp_tasks t
        left join lateral (select u.status from public.dp_updates u where u.task_id = t.id and u.day <= d order by u.day desc limit 1) cur on true
        where t.created_day <= d and public.dp_can_see(t)
          and coalesce((select u.status from public.dp_updates u where u.task_id = t.id and u.day < d order by u.day desc limit 1), 'progress') <> 'done'
      ) s), '[]'),
    'submissions', coalesce((
      select jsonb_agg(jsonb_build_object('dept_id', s.dept_id, 'by', s.submitted_by, 'at', s.at,
                                          'late', s.at > ((s.day + time '16:00') at time zone 'Asia/Kuala_Lumpur')))
      from public.dp_submissions s where s.day = d), '[]'));
end $$;

-- A task's full history, oldest first.
create or replace function public.dp_history(p_task bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t public.dp_tasks;
begin
  select * into t from public.dp_tasks where id = p_task;
  if t.id is null or not public.dp_can_see(t) then raise exception 'Task not found'; end if;
  return jsonb_build_object(
    'updates', coalesce((select jsonb_agg(to_jsonb(u) - 'task_id' order by u.day, u.at) from public.dp_updates u where u.task_id = t.id), '[]'),
    'comments', case when public.dp_can_read_comments(t) then coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'author', c.author, 'body', c.body, 'at', c.at) order by c.at)
      from public.dp_comments c where c.task_id = t.id), '[]') end);
end $$;

-- 5. Changes.
-- New task. Staff add their own; a department PIC or director can also add one for someone else.
create or replace function public.dp_add_task(p_title text, p_project text default null, p_pic text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me public.dp_people; pic public.dp_people; who text := lower(trim(coalesce(nullif(p_pic, ''), public.dp_my_email()))); new_id bigint;
begin
  if coalesce(trim(p_title), '') = '' then raise exception 'Add a short task name'; end if;
  select * into me from public.dp_people where email = public.dp_my_email() and active;
  select * into pic from public.dp_people where email = who and active;
  if pic.email is null or pic.dept_id is null then raise exception 'That person is not in a department yet. A director can set it in Settings'; end if;
  if who <> public.dp_my_email() and not (public.dp_is_director() or (me.role = 'pic' and me.dept_id = pic.dept_id)) then
    raise exception 'Only a department PIC or director can add tasks for someone else';
  end if;
  insert into public.dp_tasks (title, dept_id, project_id, pic_email, created_by)
  values (trim(p_title), pic.dept_id, nullif(p_project, ''), who, public.dp_my_email()) returning id into new_id;
  return new_id;
end $$;

-- Rename a task or change its project: the task's PIC, their department PIC or a director.
create or replace function public.dp_edit_task(p_task bigint, p_title text, p_project text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t public.dp_tasks;
begin
  select * into t from public.dp_tasks where id = p_task;
  if t.id is null or not (t.pic_email = public.dp_my_email() or public.dp_is_director()
     or exists (select 1 from public.dp_people p where p.email = public.dp_my_email() and p.active and p.role = 'pic' and p.dept_id = t.dept_id)) then
    raise exception 'Only the task''s PIC, the department PIC or a director can change this task';
  end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Add a short task name'; end if;
  update public.dp_tasks set title = trim(p_title), project_id = nullif(p_project, '') where id = p_task;
end $$;

-- Today's update on a task. Only the task's PIC. Saving again today edits today's update.
create or replace function public.dp_save_update(p_task bigint, p_status text, p_remarks text, p_next text) returns void
language plpgsql security definer set search_path = public as $$
declare t public.dp_tasks;
begin
  select * into t from public.dp_tasks where id = p_task;
  if t.id is null or t.pic_email <> public.dp_my_email() then raise exception 'Only the task''s PIC can update it'; end if;
  if p_status not in ('done', 'progress', 'blocked') then raise exception 'Pick Done, In progress or Blocked'; end if;
  if p_status <> 'done' and coalesce(trim(p_next), '') = '' then raise exception 'Add the next action for tasks that are not done'; end if;
  insert into public.dp_updates (task_id, day, status, remarks, next_action, author)
  values (p_task, public.dp_today(), p_status, coalesce(trim(p_remarks), ''), case when p_status = 'done' then '' else trim(p_next) end, public.dp_my_email())
  on conflict (task_id, day) do update
    set status = excluded.status, remarks = excluded.remarks, next_action = excluded.next_action, edited_at = now();
end $$;

-- The department's final daily submission. Its PIC (or a director), once per day; after 4:00 PM it is marked late.
create or replace function public.dp_submit(p_dept text, p_day date default null) returns void
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_day, public.dp_today());
begin
  if not (public.dp_is_director() or exists (select 1 from public.dp_people p where p.email = public.dp_my_email() and p.active and p.role = 'pic' and p.dept_id = p_dept)) then
    raise exception 'Only the department PIC can submit its daily update';
  end if;
  if d > public.dp_today() then raise exception 'You cannot submit for a future day'; end if;
  if exists (select 1 from public.dp_submissions where dept_id = p_dept and day = d) then raise exception 'This department has already submitted for that day'; end if;
  insert into public.dp_submissions (dept_id, day, submitted_by) values (p_dept, d, public.dp_my_email());
end $$;

create or replace function public.dp_comment(p_task bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare t public.dp_tasks;
begin
  select * into t from public.dp_tasks where id = p_task;
  if t.id is null or not public.dp_can_comment(t) then raise exception 'Only directors and the project''s PM can add follow-ups'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Write the follow-up first'; end if;
  insert into public.dp_comments (task_id, author, body) values (p_task, public.dp_my_email(), trim(p_body));
end $$;

-- 6. Settings -> Team & departments. Directors only.
create or replace function public.dp_set_department(p_id text, p_name text, p_sort int default 0, p_active boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.dp_is_director() then raise exception 'Only directors can change departments'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Add a department name'; end if;
  insert into public.dp_departments (id, name, sort, active) values (p_id, trim(p_name), coalesce(p_sort, 0), coalesce(p_active, true))
  on conflict (id) do update set name = excluded.name, sort = excluded.sort, active = excluded.active;
end $$;

create or replace function public.dp_set_project(p_id text, p_name text, p_pm text, p_active boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.dp_is_director() then raise exception 'Only directors can change projects'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Add a project name'; end if;
  insert into public.dp_projects (id, name, pm_email, active) values (p_id, trim(p_name), nullif(lower(trim(p_pm)), ''), coalesce(p_active, true))
  on conflict (id) do update set name = excluded.name, pm_email = excluded.pm_email, active = excluded.active;
end $$;

-- Add or change a person. Turning someone off keeps their tasks and history; they just can't open Daily progress any more.
create or replace function public.dp_set_person(p_email text, p_name text, p_dept text, p_role text, p_active boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email));
begin
  if not public.dp_is_director() then raise exception 'Only directors can change the team'; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email'; end if;
  if p_role not in ('member', 'pic', 'pm', 'director') then raise exception 'Pick a role'; end if;
  if e = public.dp_my_email() and not public.is_editor() and (p_role <> 'director' or not coalesce(p_active, true)) then
    raise exception 'You cannot remove your own director role';
  end if;
  insert into public.dp_people (email, name, dept_id, role, active) values (e, trim(coalesce(p_name, '')), nullif(p_dept, ''), p_role, coalesce(p_active, true))
  on conflict (email) do update set name = excluded.name, dept_id = excluded.dept_id, role = excluded.role, active = excluded.active;
end $$;

-- 7. Staff accounts are not admin requests: keep them out of the Admins -> Requests waiting list.
create or replace function public.admin_requests() returns table (email text, created_at timestamptz, confirmed boolean)
language sql stable security definer set search_path = public, auth as $$
  select u.email::text, u.created_at, u.email_confirmed_at is not null
  from auth.users u
  where public.is_editor() and u.email is not null
    and lower(u.email) not in (select lower(e.email) from public.editors e)
    and lower(u.email) not in (select lower(d.email) from public.admin_denied d)
    and lower(u.email) not in (select p.email from public.dp_people p)
  order by u.created_at desc;
$$;

revoke execute on function public.dp_is_director(), public.dp_can_see(public.dp_tasks), public.dp_can_read_comments(public.dp_tasks), public.dp_can_comment(public.dp_tasks) from public;
grant execute on function public.dp_me(), public.dp_board(date), public.dp_history(bigint), public.dp_add_task(text, text, text), public.dp_edit_task(bigint, text, text),
  public.dp_save_update(bigint, text, text, text), public.dp_submit(text, date), public.dp_comment(bigint, text),
  public.dp_set_department(text, text, int, boolean), public.dp_set_project(text, text, text, boolean), public.dp_set_person(text, text, text, text, boolean)
  to authenticated;
