-- ============================================================
-- STEP 0 — DIAGNOSTIC.  Read-only. Changes nothing.
-- Run this in the Supabase SQL editor and read the output
-- before running 01-admin-setup.sql.
-- ============================================================

-- A. Is row-level security switched on for each table?
select
  c.relname                        as table_name,
  c.relrowsecurity                 as rls_enabled,
  c.relforcerowsecurity            as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('profiles','daily_progress','weekly_assessments','consultation_requests')
order by c.relname;

-- B. What policies already exist?
select
  tablename,
  policyname,
  cmd          as applies_to,
  roles,
  qual         as using_expression,
  with_check   as check_expression
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles','daily_progress','weekly_assessments','consultation_requests')
order by tablename, policyname;

-- C. How many learners and rows are there right now?
select 'auth.users'            as source, count(*) from auth.users
union all select 'profiles',              count(*) from public.profiles
union all select 'daily_progress',        count(*) from public.daily_progress
union all select 'weekly_assessments',    count(*) from public.weekly_assessments
union all select 'consultation_requests', count(*) from public.consultation_requests;

-- D. Your own user id — you will need this to make yourself an admin.
select id, email, created_at
from auth.users
order by created_at
limit 20;
