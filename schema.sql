-- Outpatient Queue Board: database schema for Supabase (Postgres 15+).
-- Run this whole file once in Supabase > SQL Editor.
--
-- Design rules enforced HERE, on the server, not in the browser:
--   * The queue order is fixed by registration time. Nobody can edit timestamps or reorder.
--   * The only exception is flag_priority(), which needs a written reason and is logged.
--   * Staff cannot write to the tables directly. They call the functions below.
--   * Doctors can only see and act on their own queue.
--   * The public waiting-room screen can only read a view that exposes ticket numbers and
--     first name + last initial. It never sees full names or priority reasons.

-- ---------------------------------------------------------------- types
create type user_role as enum ('doctor', 'desk');
create type ticket_status as enum ('waiting', 'serving', 'done', 'cancelled');

-- ---------------------------------------------------------------- tables
create table doctors (
  id    int generated always as identity primary key,
  name  text not null,
  dept  text not null
);

create table profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text not null,
  role       user_role not null,
  doctor_id  int references doctors (id),
  check ((role = 'doctor') = (doctor_id is not null))
);

-- 4-digit ticket numbers (1000 to 9999), wrapping around when the range is used up.
create sequence ticket_seq start 1000 minvalue 1000 maxvalue 9999 cycle;

create table tickets (
  id               bigint generated always as identity primary key,
  ticket_no        int not null default nextval('ticket_seq'),
  patient_name     text not null check (char_length(btrim(patient_name)) between 1 and 80),
  doctor_id        int not null references doctors (id),
  status           ticket_status not null default 'waiting',
  registered_at    timestamptz not null default now(),
  registered_by    uuid references profiles (id),
  priority_at      timestamptz,
  priority_reason  text,
  priority_by      uuid references profiles (id),
  started_at       timestamptz,
  ended_at         timestamptz,
  cancel_reason    text,
  check (priority_at is null or char_length(btrim(coalesce(priority_reason, ''))) >= 8)
);

create index tickets_queue_idx on tickets (doctor_id, status, registered_at);
-- A doctor can only be with one patient at a time.
create unique index one_serving_per_doctor on tickets (doctor_id) where status = 'serving';

create table events (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid references profiles (id),
  actor_name  text,
  ticket_id   bigint,
  message     text not null
);
create index events_at_idx on events (at desc);

-- ---------------------------------------------------------------- helpers
create function short_name(n text) returns text
language sql immutable as $$
  select case
    when position(' ' in btrim(n)) > 0
      then split_part(btrim(n), ' ', 1) || ' ' || upper(left(regexp_replace(btrim(n), '^.*\s+', ''), 1)) || '.'
    else btrim(n)
  end
$$;

create function auth_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create function auth_doctor() returns int
language sql stable security definer set search_path = public as $$
  select doctor_id from public.profiles where id = auth.uid()
$$;

-- ---------------------------------------------------------------- row level security
alter table doctors  enable row level security;
alter table profiles enable row level security;
alter table tickets  enable row level security;
alter table events   enable row level security;

create policy doctors_read on doctors for select to anon, authenticated using (true);
create policy profiles_own on profiles for select to authenticated using (id = auth.uid());
create policy tickets_staff_read on tickets for select to authenticated
  using (auth_role() = 'desk' or (auth_role() = 'doctor' and doctor_id = auth_doctor()));
create policy events_desk_read on events for select to authenticated
  using (auth_role() = 'desk');

-- No insert/update/delete policies exist on purpose. Writes go through the functions below.
revoke all on doctors, profiles, tickets, events from anon, authenticated;
grant select on doctors to anon, authenticated;
grant select on profiles, tickets, events to authenticated;

-- ---------------------------------------------------------------- views
-- Public waiting-room screen. Runs with the view owner's rights, so anon can read this
-- view without any access to the tickets table. pos = position in line among waiting patients.
create view public_queue as
select
  id,
  ticket_no,
  doctor_id,
  status,
  registered_at,
  (priority_at is not null) as is_priority,
  short_name(patient_name)  as short_name,
  case when status = 'waiting' then
    row_number() over (partition by doctor_id, status
                       order by (priority_at is null), priority_at, registered_at, id)
  end as pos
from tickets
where status in ('waiting', 'serving');

-- Staff view. security_invoker makes the tickets policies apply to the person asking.
create view staff_queue with (security_invoker = true) as
select
  t.*,
  case when t.status = 'waiting' then
    row_number() over (partition by t.doctor_id, t.status
                       order by (t.priority_at is null), t.priority_at, t.registered_at, t.id)
  end as pos
from tickets t
where t.status in ('waiting', 'serving') or t.ended_at > now() - interval '1 day';

revoke all on public_queue, staff_queue from anon, authenticated;
grant select on public_queue to anon, authenticated;
grant select on staff_queue to authenticated;

-- ---------------------------------------------------------------- actions
create function register_patient(p_name text, p_doctor int)
returns tickets language plpgsql security definer set search_path = public as $$
declare me profiles; t tickets;
begin
  select * into me from profiles where id = auth.uid();
  if me.role is distinct from 'desk' then
    raise exception 'Only front desk staff can register patients';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Enter the patient name';
  end if;
  if not exists (select 1 from doctors where id = p_doctor) then
    raise exception 'Unknown doctor';
  end if;
  insert into tickets (patient_name, doctor_id, registered_by)
    values (btrim(p_name), p_doctor, me.id) returning * into t;
  insert into events (actor, actor_name, ticket_id, message)
    values (me.id, me.full_name, t.id,
            'Registered ' || t.ticket_no || ' ' || short_name(t.patient_name) ||
            ' for ' || (select name from doctors where id = p_doctor));
  return t;
end $$;

create function flag_priority(p_ticket bigint, p_reason text)
returns tickets language plpgsql security definer set search_path = public as $$
declare me profiles; t tickets;
begin
  select * into me from profiles where id = auth.uid();
  if me.role is distinct from 'desk' then
    raise exception 'Only front desk staff can flag priority';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 8 then
    raise exception 'Enter a reason of at least 8 characters';
  end if;
  update tickets
     set priority_at = now(), priority_reason = btrim(p_reason), priority_by = me.id
   where id = p_ticket and status = 'waiting' and priority_at is null
   returning * into t;
  if not found then
    raise exception 'That patient is no longer waiting, or is already flagged';
  end if;
  insert into events (actor, actor_name, ticket_id, message)
    values (me.id, me.full_name, t.id,
            'Priority flag on ' || t.ticket_no || ' ' || short_name(t.patient_name) ||
            ' (reason: ' || t.priority_reason || ')');
  return t;
end $$;

create function cancel_ticket(p_ticket bigint, p_reason text)
returns tickets language plpgsql security definer set search_path = public as $$
declare me profiles; t tickets;
begin
  select * into me from profiles where id = auth.uid();
  if me.role is distinct from 'desk' then
    raise exception 'Only front desk staff can remove patients from the queue';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 4 then
    raise exception 'Enter a short reason, for example "left without being seen"';
  end if;
  update tickets
     set status = 'cancelled', ended_at = now(), cancel_reason = btrim(p_reason)
   where id = p_ticket and status = 'waiting'
   returning * into t;
  if not found then
    raise exception 'That patient is no longer waiting';
  end if;
  insert into events (actor, actor_name, ticket_id, message)
    values (me.id, me.full_name, t.id,
            'Removed ' || t.ticket_no || ' ' || short_name(t.patient_name) ||
            ' (reason: ' || t.cancel_reason || ')');
  return t;
end $$;

create function call_next()
returns tickets language plpgsql security definer set search_path = public as $$
declare me profiles; t tickets;
begin
  select * into me from profiles where id = auth.uid();
  if me.role is distinct from 'doctor' then
    raise exception 'Only doctors can call patients';
  end if;
  if exists (select 1 from tickets where doctor_id = me.doctor_id and status = 'serving') then
    raise exception 'Finish the current patient first';
  end if;
  select * into t from tickets
   where doctor_id = me.doctor_id and status = 'waiting'
   order by (priority_at is null), priority_at, registered_at, id
   limit 1
   for update skip locked;
  if not found then
    raise exception 'No one is waiting';
  end if;
  update tickets set status = 'serving', started_at = now() where id = t.id returning * into t;
  insert into events (actor, actor_name, ticket_id, message)
    values (me.id, me.full_name, t.id,
            me.full_name || ' called ' || t.ticket_no || ' ' || short_name(t.patient_name));
  return t;
end $$;

create function finish_current(p_call_next boolean default false)
returns tickets language plpgsql security definer set search_path = public as $$
declare me profiles; t tickets;
begin
  select * into me from profiles where id = auth.uid();
  if me.role is distinct from 'doctor' then
    raise exception 'Only doctors can finish consultations';
  end if;
  update tickets set status = 'done', ended_at = now()
   where doctor_id = me.doctor_id and status = 'serving'
   returning * into t;
  if not found then
    raise exception 'There is no patient in consultation';
  end if;
  insert into events (actor, actor_name, ticket_id, message)
    values (me.id, me.full_name, t.id,
            me.full_name || ' finished with ' || t.ticket_no || ' ' || short_name(t.patient_name));
  if p_call_next and exists (select 1 from tickets where doctor_id = me.doctor_id and status = 'waiting') then
    perform call_next();
  end if;
  return t;
end $$;

revoke all on function auth_role(), auth_doctor(),
  register_patient(text, int), flag_priority(bigint, text), cancel_ticket(bigint, text),
  call_next(), finish_current(boolean) from public, anon;
grant execute on function auth_role(), auth_doctor(),
  register_patient(text, int), flag_priority(bigint, text), cancel_ticket(bigint, text),
  call_next(), finish_current(boolean) to authenticated;

-- ---------------------------------------------------------------- live updates for staff screens
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table tickets;
  end if;
end $$;

-- ---------------------------------------------------------------- starter doctors (edit these)
insert into doctors (name, dept) values
  ('Dr. Ngozi Eze',      'General Outpatient'),
  ('Dr. Musa Bello',     'Internal Medicine'),
  ('Dr. Funke Adeyemi',  'Surgical Outpatient');
