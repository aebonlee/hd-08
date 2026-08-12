-- ============================================================
-- 로컬 검증 전용 Supabase 환경 스텁
--
-- 이 파일은 supabase/ 폴더에 두지 않는다.
-- 그 폴더의 다른 파일은 전부 "SQL Editor에서 실행하라"는 안내라서
-- 폴더가 주는 신호가 주석보다 세다. 실제로 "운영에서 실행 금지"라고
-- 적어 둔 파일이 운영에서 실행된 적이 있다(2026-08-07).
--
-- 그래서 적어 두는 대신, 아래 가드로 운영에서는 실행되지 않게 만든다.
-- ============================================================

-- 운영(Supabase) 감지 시 즉시 중단
do $guard$
begin
  if exists (select 1 from pg_roles where rolname in ('supabase_admin', 'authenticator'))
     or exists (select 1 from pg_namespace where nspname = 'graphql') then
    raise exception
      '운영 Supabase에서 실행하려 했습니다. 이 파일은 로컬 검증 전용입니다. (scripts/sqltest/)';
  end if;
end
$guard$;

-- ------------------------------------------------------------
-- Supabase가 기본 제공하는 역할
-- ------------------------------------------------------------
do $roles$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end
$roles$;

grant usage on schema public to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Supabase는 신규 함수마다 세 역할에 EXECUTE를 자동 부여한다.
-- 이걸 재현해야 "PUBLIC만 revoke하고 anon=X를 남기는" 실수를 로컬에서 잡는다.
-- ------------------------------------------------------------
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- auth 스키마 최소 스텁
-- ------------------------------------------------------------
create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
