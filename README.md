# Outpatient Queue Board

A first-come-first-served queue for hospital waiting rooms.

- **Waiting-room screen** (public, no sign-in): ticket numbers, first name + last initial, registration time, which doctor.
- **Doctor desk**: each doctor sees only their own queue, calls the next patient, marks done.
- **Front desk**: registers patients and issues a 4-digit ticket. Can flag a priority case (a written reason is required, it shows on the screen, and it is logged) or remove someone who left.

The order is fixed by the server clock. Nobody can reorder it. The rules live in the database (`schema.sql`), not in the browser, so changing the page in a browser cannot cheat the queue.

Stack: static files on Vercel, Supabase for database, sign-in and live updates. No server to maintain.

## Deploy (about 20 minutes)

### 1. Supabase
1. Create a project at supabase.com. Pick the region closest to the hospital.
2. **SQL Editor > New query**: paste all of `schema.sql` and run it. (A warning about a "security definer view" is expected: that is the public screen view.)
3. **Authentication > Sign In / Providers**: turn **off** "Allow new users to sign up". Only the administrator creates staff accounts.
4. **Authentication > Users > Add user**: create one user per doctor and one for the front desk. Use real emails, strong passwords, and tick **Auto Confirm User**.
5. Open `staff.sql`, put in the same emails and names, and run it. This gives each account its role.
6. Edit the doctors list to match the hospital (examples are at the bottom of `staff.sql`).
7. **Project Settings > API**: copy the **Project URL** and the **anon public** key.

### 2. Configure the app
Open `config.js` and paste the URL and anon key. The anon key is designed to be public. Never put the `service_role` key anywhere in this project.

### 3. Vercel
Either:
- **CLI:** `npm i -g vercel`, then inside this folder run `vercel --prod`. Answer: framework "Other", no build command, output directory left empty.
- **GitHub:** push this folder to a repo, then Vercel > Add New > Project > import it. Framework "Other", no build command.

You get a link like `https://your-project.vercel.app`.

### 4. Put it to use
- **TV in the waiting room:** open the link in the TV's browser and press F11 for full screen. It refreshes by itself every 4 seconds. The text scales up on large screens.
- **Doctors and front desk:** open `https://your-project.vercel.app/#/staff` and sign in.
- Optional: set `SHOW_NAMES_ON_SCREEN: false` in `config.js` to show only ticket numbers on the public screen.

## Check it works before going live
1. Sign in as front desk, register two patients for the same doctor.
2. Open the public link on another device. Both tickets show, in order.
3. Flag the second one as priority. The reason must be at least 8 characters. It jumps to first and shows a Priority tag.
4. Sign in as that doctor on a third device. Only their patients appear. Call next, then done.
5. Try signing in as a doctor and opening the front desk page: it should not be available.

## Things to know
- **Patient data is personal health information.** Names are stored in your Supabase database and shown in full to the doctor and front desk. The public screen only gets first name + last initial (or nothing, with `SHOW_NAMES_ON_SCREEN: false`). Get the hospital's approval and check the Nigeria Data Protection Act requirements before real use.
- **Supabase free projects pause after about a week without activity.** Fine for a hospital that uses it daily. For a real pilot, consider the paid plan for backups.
- The public screen checks for changes every 4 seconds. Staff screens update instantly through Supabase Realtime.
- Ticket numbers run 1000 to 9999 and then start again from 1000.
- No password-reset page yet. An administrator can reset passwords in Supabase > Authentication > Users.
- What was tested: the database rules against a real Postgres (every role, every action, and the attempts to cheat), and the pages in a browser against a stand-in for Supabase. It has not yet been run against your live Supabase project, so do the check above first.
