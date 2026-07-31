# Admin setup

How to give yourself a view of every learner's progress.

Two SQL files, run once, in order, in the **Supabase SQL editor** (Dashboard → SQL Editor → New query).

---

## Before you start: the one rule

**Never put the `service_role` key in `index.html`.**

That key bypasses row-level security completely. Anything in the page is readable by every learner who opens their browser's dev tools — so a service-role key in the page hands every learner full read and write access to everyone else's data, and the ability to delete it.

Everything below works through your **own** signed-in account instead. You get admin access because your user id is in an `admins` table, not because the page holds a privileged key. The page keeps using the same publishable key it already uses.

---

## Step 1 — Look before you touch

Run **`00-diagnostic.sql`**. It changes nothing.

It answers four things:

| Query | Tells you |
|---|---|
| A | Whether row-level security is on for each table |
| B | Which policies already exist |
| C | How many learners and rows you have |
| D | Your user id and email |

**Read section A carefully.** If `rls_enabled` is `false` for any table, that table is currently wide open — any signed-in learner can already read and write everyone's rows. Step 2 switches RLS on, which fixes that, and it also installs "learners can reach their own rows" policies so nobody gets locked out when it does.

If section A shows RLS already enabled and section B shows policies you wrote yourself, Step 2 adds to them rather than replacing them. Postgres combines permissive policies with OR, so your existing rules keep working.

**Keep the output of section D** — you need your email for Step 3.

---

## Step 2 — Install

Run **`01-admin-setup.sql`**. It is safe to run more than once.

It creates:

- **`public.admins`** — the registry. Starts empty, so nobody is an admin yet.
- **`is_admin()`** — the check. It is `security definer`, which matters: a policy on `profiles` that queried `profiles` to decide who may read `profiles` would recurse forever. This function runs as its owner, so its own lookup is not filtered by the policies it feeds.
- **Self-access policies** on all four tables, so every learner can always reach their own rows.
- **Admin read policies** on all four tables. `SELECT` only — an admin can see a learner's progress and never overwrite it.
- **`admin_learner_overview()`** — one row per learner with their headline numbers.
- **`admin_learner_detail(uuid)`** — everything about one learner.

### The part not to remove

Both reporting functions are `security definer`, so they bypass RLS by design. Each one opens with:

```sql
if not public.is_admin() then
  raise exception 'not authorised' using errcode = '42501';
end if;
```

That guard is the only thing between a curious learner and everyone's data. If you edit these functions later, keep it.

---

## Step 3 — Make yourself an admin

At the bottom of `01-admin-setup.sql` there is a commented-out block. Uncomment it, put your own email in, and run it:

```sql
insert into public.admins (user_id, note)
select id, 'programme owner' from auth.users where email = 'you@example.com'
on conflict (user_id) do nothing;
```

Verify:

```sql
select a.user_id, u.email, a.added_at
from public.admins a join auth.users u on u.id = a.user_id;
```

One row, your email. Done.

---

## Step 4 — Use it

Sign in to the site with that account. An **Admin — Learner progress** panel appears above your own profile, showing every learner with:

- name, email and profession
- start date and days completed out of 56
- a progress bar and percentage
- weekly assessments completed out of 8
- when they were last active

**View** opens one learner in full: their goal, every day they have ticked off, every weekly assessment with scores and reflection, and every consultation request they have submitted.

**Download CSV** exports the whole roster.

The panel is hidden for everyone else. A learner who is not in the `admins` table sees exactly what they saw before.

---

## Adding learners

Two ways:

**They sign up themselves.** Send them the link; they use Create account. A `profiles` row appears when they first save their profile.

**You invite them.** Dashboard → Authentication → Users → Invite user. They get an email to set a password.

Either way they appear in your panel once they have signed in and saved a profile.

---

## Removing an admin

```sql
delete from public.admins where user_id = (
  select id from auth.users where email = 'them@example.com'
);
```

Takes effect on their next request. Their own learner data is untouched.

---

## What this deliberately does not do

- **Admins cannot edit learner data.** The policies grant `SELECT` only. If you later want a coach to leave feedback, add a separate `coach_notes` table rather than opening up writes to `daily_progress`.
- **Admins cannot delete accounts.** Do that from the Supabase dashboard.
- **There are no admin tiers.** Everyone in `admins` sees everything. If you take on a second coach who should only see their own learners, this needs an assignment table and narrower policies — worth doing before you add one, not after.

---

## Troubleshooting

**Panel does not appear.** Confirm your row exists in `admins` (Step 3). Sign out and back in — the check runs at sign-in.

**"Couldn't load learners: function ... does not exist".** `01-admin-setup.sql` has not run, or errored partway. Re-run it.

**"not authorised".** You are signed in as an account that is not in `admins`. Check which account — the panel's own page shows it under "My learner account".

**A learner is missing.** They have signed up but never saved a profile, so there is no `profiles` row to join. Ask them to open the site and fill in their name.

**Learners report they cannot save anything, right after Step 2.** RLS was off before and is now on, and something about your column names differs from what the policies assume — the self-access policies key on `profiles.id` and on `user_id` for the other three tables. Check section B of the diagnostic and compare.
