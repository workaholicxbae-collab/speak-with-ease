-- ============================================================
-- STEP 1 — ADMIN SETUP
--
-- Run this in the Supabase SQL editor AFTER 00-diagnostic.sql.
-- Safe to run more than once.
--
-- What it does:
--   * creates an admins registry
--   * adds an is_admin() check that cannot recurse
--   * lets admins read every learner's rows (adds to, never
--     replaces, the existing "learners read their own" rules)
--   * adds two reporting functions the app calls
--
-- What it does NOT do:
--   * it never grants admins the right to WRITE another
--     learner's data. Read only, deliberately.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Who is an admin
-- ------------------------------------------------------------
create table if not exists public.admins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  note     text
);

alter table public.admins enable row level security;


-- ------------------------------------------------------------
-- 2. The admin check
--
-- security definer matters here. A policy on profiles that
-- queried profiles to decide who may read profiles would
-- recurse forever. This function runs as its owner, so its
-- own lookup is not filtered by the policies it feeds.
-- ------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admins where user_id = auth.uid()
  );
$$;

revoke all     on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;


-- Admins may read the admin list. Nobody may write it from the
-- client — adding an admin is a SQL-editor action, on purpose.
drop policy if exists "admins read admin list" on public.admins;
create policy "admins read admin list"
  on public.admins for select to authenticated
  using (public.is_admin());


-- ------------------------------------------------------------
-- 3. Safety net: guarantee every learner can still reach their
--    own rows.
--
--    These duplicate whatever you already have. Duplicate
--    permissive policies are harmless — Postgres ORs them
--    together — but if RLS was off and you switch it on, these
--    are what stop the app going dark for existing learners.
-- ------------------------------------------------------------
alter table public.profiles              enable row level security;
alter table public.daily_progress        enable row level security;
alter table public.weekly_assessments    enable row level security;
alter table public.consultation_requests enable row level security;

drop policy if exists "own profile rw" on public.profiles;
create policy "own profile rw" on public.profiles
  for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "own daily rw" on public.daily_progress;
create policy "own daily rw" on public.daily_progress
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own weekly rw" on public.weekly_assessments;
create policy "own weekly rw" on public.weekly_assessments
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own consultations rw" on public.consultation_requests;
create policy "own consultations rw" on public.consultation_requests
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ------------------------------------------------------------
-- 4. Admin read access
--
--    SELECT only. An admin can see a learner's progress and
--    never overwrite it.
-- ------------------------------------------------------------
drop policy if exists "admin reads all profiles" on public.profiles;
create policy "admin reads all profiles" on public.profiles
  for select to authenticated using (public.is_admin());

drop policy if exists "admin reads all daily" on public.daily_progress;
create policy "admin reads all daily" on public.daily_progress
  for select to authenticated using (public.is_admin());

drop policy if exists "admin reads all weekly" on public.weekly_assessments;
create policy "admin reads all weekly" on public.weekly_assessments
  for select to authenticated using (public.is_admin());

drop policy if exists "admin reads all consultations" on public.consultation_requests;
create policy "admin reads all consultations" on public.consultation_requests
  for select to authenticated using (public.is_admin());


-- ------------------------------------------------------------
-- 5. Reporting functions
--
--    These are security definer, so they bypass RLS. That means
--    the is_admin() guard inside each one is the ONLY thing
--    standing between a curious learner and everyone's data.
--    Do not remove it.
-- ------------------------------------------------------------

-- One row per learner, with their headline numbers.
create or replace function public.admin_learner_overview()
returns table (
  user_id             uuid,
  full_name           text,
  email               text,
  profession          text,
  speaking_goal       text,
  start_date          date,
  starting_confidence int,
  days_done           int,
  pct                 int,
  weeks_assessed      int,
  consultations       int,
  last_active         timestamptz,
  signed_up           timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorised' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.full_name::text,
    u.email::text,
    p.profession::text,
    p.speaking_goal::text,
    p.start_date::date,
    p.starting_confidence::int,
    coalesce(d.done, 0)::int,
    (coalesce(d.done, 0) * 100 / 56)::int,
    coalesce(w.n, 0)::int,
    coalesce(c.n, 0)::int,
    d.last_at,
    u.created_at
  from public.profiles p
  join auth.users u on u.id = p.id
  left join (
    select dp.user_id,
           count(*) filter (where dp.completed) as done,
           max(dp.updated_at)                   as last_at
    from public.daily_progress dp group by dp.user_id
  ) d on d.user_id = p.id
  left join (
    select wa.user_id, count(*) as n
    from public.weekly_assessments wa group by wa.user_id
  ) w on w.user_id = p.id
  left join (
    select cr.user_id, count(*) as n
    from public.consultation_requests cr group by cr.user_id
  ) c on c.user_id = p.id
  order by coalesce(d.done, 0) desc, p.full_name nulls last;
end;
$$;

revoke all     on function public.admin_learner_overview() from public, anon;
grant  execute on function public.admin_learner_overview() to authenticated;


-- Everything about one learner.
create or replace function public.admin_learner_detail(target uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if not public.is_admin() then
    raise exception 'not authorised' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'days', coalesce((
      select jsonb_agg(dp.day_number order by dp.day_number)
      from public.daily_progress dp
      where dp.user_id = target and dp.completed
    ), '[]'::jsonb),
    'weeks', coalesce((
      select jsonb_agg(to_jsonb(wa) order by wa.week_number)
      from public.weekly_assessments wa
      where wa.user_id = target
    ), '[]'::jsonb),
    'consultations', coalesce((
      select jsonb_agg(to_jsonb(cr))
      from public.consultation_requests cr
      where cr.user_id = target
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all     on function public.admin_learner_detail(uuid) from public, anon;
grant  execute on function public.admin_learner_detail(uuid) to authenticated;


-- ============================================================
-- 6. MAKE YOURSELF AN ADMIN
--
-- Replace the email below with the address you sign in with,
-- then run these two lines. Nothing above this point grants
-- anyone admin rights — the table starts empty.
-- ============================================================

-- insert into public.admins (user_id, note)
-- select id, 'programme owner' from auth.users where email = 'you@example.com'
-- on conflict (user_id) do nothing;

-- Check it worked — should return one row, and true:
-- select a.user_id, u.email, a.added_at from public.admins a join auth.users u on u.id=a.user_id;
