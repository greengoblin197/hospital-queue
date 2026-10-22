-- Give each staff member a role. Run this in Supabase > SQL Editor AFTER:
--   1. schema.sql has been run, and
--   2. you created each person in Authentication > Users > Add user
--      (enter email + password, and tick "Auto Confirm User").
--
-- Replace the emails and names below with your real ones. Doctor names must match the
-- names in the doctors table (see the bottom of schema.sql, or edit them with the
-- UPDATE example further down).

-- Doctors: one row each. The doctor_id links them to their own queue.
insert into profiles (id, full_name, role, doctor_id)
select u.id, 'Dr. ujam', 'doctor', (select id from doctors where name = 'Dr. ujam')
from auth.users u where u.email = 'malangwarzo@gmail.com';

insert into profiles (id, full_name, role, doctor_id)
select u.id, 'Dr. Musa Bello', 'doctor', (select id from doctors where name = 'Dr. Musa Bello')
from auth.users u where u.email = 'ibrahimtgwarzo1@gmail.com';

insert into profiles (id, full_name, role, doctor_id)
select u.id, 'Dr. Funke Adeyemi', 'doctor', (select id from doctors where name = 'Dr. Funke Adeyemi')
from auth.users u where u.email = 'ibrahimtgwarzo2@gmail.com';

-- Front desk: no doctor_id.
insert into profiles (id, full_name, role)
select u.id, 'Nurse Amaka Obi', 'frontdesk'
from auth.users u where u.email = 'frontdesk@gmail.com';

-- ---------------------------------------------------------------------------
-- Useful later:
--   Rename a doctor or department:
--     update doctors set name = 'Dr. A. Bello', dept = 'Paediatrics' where id = 2;
--   Add a doctor:
--     insert into doctors (name, dept) values ('Dr. New Name', 'Dental');
--   Remove someone's access (delete the user in Authentication > Users, their profile goes too).
--   Clear the queue at the end of the day (keeps history):
--     update tickets set status = 'cancelled', ended_at = now(), cancel_reason = 'End of day'
--     where status in ('waiting', 'serving');
