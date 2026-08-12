-- ============================================================
-- hd-08 회원가입 스키마 (사이트 접두사: hd08_)
--
-- 실행 위치: Supabase SQL Editor (대표가 직접 실행 — DDL 권한 필요)
-- 대상 프로젝트: hcmgdztsgjvzcyxyayaj (전 사이트 공용 단일 프로젝트)
--
-- 이 스크립트는 재실행 안전(idempotent)하다.
-- 이미 무접두사 이름(site_member_profiles)으로 만들어 둔 것이 있으면
-- 데이터를 보존한 채 hd08_ 이름으로 이관한다.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0) 옛 무접두사 자산 이관 (있을 때만)
--
-- 강의 중 연습으로 만든 public.site_member_profiles가 이미 있으면
-- DROP하지 않고 RENAME해서 가입 기록을 살린다.
--
-- 주의: ALTER TABLE ... RENAME은 제약조건 이름을 바꾸지 않는다.
--       pkey/unique/fk/check가 옛 이름으로 남으므로 따로 훑어 고친다.
-- ------------------------------------------------------------
do $migrate$
declare
  r record;
begin
  if to_regclass('public.site_member_profiles') is not null
     and to_regclass('public.hd08_profiles') is null then

    -- 함수를 갈아끼우기 전에 옛 테이블 트리거부터 뗀다
    execute 'drop trigger if exists set_site_member_profiles_updated_at on public.site_member_profiles';
    execute 'alter table public.site_member_profiles rename to hd08_profiles';
    raise notice 'site_member_profiles -> hd08_profiles 이관 완료 (데이터 보존)';
  end if;

  if to_regclass('public.hd08_profiles') is not null then
    for r in
      select conname
        from pg_constraint
       where conrelid = 'public.hd08_profiles'::regclass
         and starts_with(conname, 'site_member_profiles')
    loop
      execute format(
        'alter table public.hd08_profiles rename constraint %I to %I',
        r.conname,
        'hd08_profiles' || substr(r.conname, length('site_member_profiles') + 1)
      );
      raise notice '제약조건 이름 정리: % -> %',
        r.conname, 'hd08_profiles' || substr(r.conname, length('site_member_profiles') + 1);
    end loop;
  end if;
end
$migrate$;

-- ------------------------------------------------------------
-- 1) 프로필 테이블
-- ------------------------------------------------------------
create table if not exists public.hd08_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null check (char_length(btrim(full_name)) between 2 and 50),
  phone text not null check (phone ~ '^01[016789][0-9]{7,8}$'),
  privacy_consent_at timestamptz not null default now(),
  site_code text not null default 'hd-08',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 이관해 온 테이블은 기본값이 'default'로 남아 있으므로 맞춰 준다
alter table public.hd08_profiles alter column site_code set default 'hd-08';

comment on table public.hd08_profiles is
'hd-08 회원가입 연습 사이트 전용 프로필. auth.users와 1:1. 이름/전화번호/동의시각 저장.';

comment on column public.hd08_profiles.phone is
'하이픈 없이 숫자만 저장. 예: 01012345678';

comment on column public.hd08_profiles.site_code is
'가입이 일어난 사이트 코드. 이 스크립트가 세우는 값은 항상 hd-08.';

-- ------------------------------------------------------------
-- 2) RLS + 권한
--
-- 브라우저의 비로그인(anon) 사용자는 프로필에 접근할 수 없다.
-- 로그인 사용자는 자기 행만 조회/수정한다.
-- 삽입은 아래 SECURITY DEFINER 트리거만 담당하므로 INSERT 정책을 두지 않는다.
-- DELETE 정책도 두지 않는다 — 탈퇴는 auth.users 삭제(on delete cascade)로만.
-- ------------------------------------------------------------
alter table public.hd08_profiles enable row level security;

revoke all on table public.hd08_profiles from anon;
revoke all on table public.hd08_profiles from authenticated;
grant select, update on table public.hd08_profiles to authenticated;

-- 옛 이름 정책이 남아 있으면 먼저 치운다
drop policy if exists "site_member_select_own" on public.hd08_profiles;
drop policy if exists "site_member_update_own" on public.hd08_profiles;

drop policy if exists "hd08_profiles_select_own" on public.hd08_profiles;
drop policy if exists "hd08_profiles_update_own" on public.hd08_profiles;

create policy "hd08_profiles_select_own"
on public.hd08_profiles
for select
to authenticated
using ((select auth.uid()) = id);

create policy "hd08_profiles_update_own"
on public.hd08_profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

-- ------------------------------------------------------------
-- 3) 가입 시 프로필 자동 생성
--
-- 트리거는 raw_user_meta_data.signup_source가 'hd08-membership-v1'일 때만
-- 발화한다. 이 프로젝트에는 사이트 수십 곳의 가입이 함께 들어오므로,
-- 조건 없이 걸면 여기서 raise한 예외가 전 사이트 가입을 마비시킨다.
-- (2026-06-19 실제 사고: search_path 미고정 핸들러 하나가 전체 가입을 막았다)
--
-- 이 문자열은 index.html의 SIGNUP_SOURCE와 한 글자도 다르면 안 된다.
-- ------------------------------------------------------------
create or replace function public.hd08_handle_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_email text;
  v_name text;
  v_phone text;
  v_site_code text;
  v_consent text;
begin
  v_email := lower(btrim(coalesce(new.email, '')));
  v_name := btrim(coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  v_phone := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '[^0-9]', '', 'g');
  v_consent := lower(coalesce(new.raw_user_meta_data ->> 'privacy_consent', 'false'));

  -- 빈 문자열이면 기본값으로 되돌린다.
  -- nullif만 쓰면 NULL이 되어 not null 컬럼에서 가입이 통째로 실패한다.
  v_site_code := coalesce(
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'site_code', '')), ''),
    'hd-08'
  );

  if v_email = '' then
    raise exception '이메일이 없어 회원 프로필을 만들 수 없습니다.';
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 50 then
    raise exception '회원 이름이 올바르지 않습니다.';
  end if;

  if v_phone !~ '^01[016789][0-9]{7,8}$' then
    raise exception '휴대전화 번호가 올바르지 않습니다.';
  end if;

  if v_consent <> 'true' then
    raise exception '필수 개인정보 수집·이용 동의가 필요합니다.';
  end if;

  insert into public.hd08_profiles (
    id, email, full_name, phone, privacy_consent_at, site_code
  )
  values (
    new.id, v_email, v_name, v_phone, now(), v_site_code
  )
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = excluded.full_name,
    phone = excluded.phone,
    site_code = excluded.site_code,
    updated_at = now();

  return new;
end;
$fn$;

-- 권한은 두 겹으로 미리 붙는다:
--   ① PostgreSQL이 생성 시 PUBLIC에 EXECUTE 기본 부여
--   ② Supabase가 ALTER DEFAULT PRIVILEGES로 anon/authenticated/service_role에 자동 부여
-- PUBLIC만 지우면 anon=X가 남아 비로그인 호출이 그대로 뚫린다.
revoke all on function public.hd08_handle_signup() from public;
revoke all on function public.hd08_handle_signup() from anon;
-- 트리거 전용 함수라 authenticated는 남긴다.
-- 발화 시 호출자 EXECUTE를 검사하는지 확실치 않은데, 검사한다면 끊는 순간 가입이 막힌다.
-- 직접 호출하면 "can only be called as trigger"로 죽으므로 남겨도 무해하다.
grant execute on function public.hd08_handle_signup() to authenticated;

drop trigger if exists on_auth_user_created_site_member_profiles on auth.users;
drop trigger if exists hd08_on_auth_user_created on auth.users;

create trigger hd08_on_auth_user_created
after insert on auth.users
for each row
when ((new.raw_user_meta_data ->> 'signup_source') = 'hd08-membership-v1')
execute function public.hd08_handle_signup();

-- ------------------------------------------------------------
-- 4) updated_at 자동 갱신
-- ------------------------------------------------------------
create or replace function public.hd08_set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

revoke all on function public.hd08_set_updated_at() from public;
revoke all on function public.hd08_set_updated_at() from anon;
grant execute on function public.hd08_set_updated_at() to authenticated;

drop trigger if exists set_site_member_profiles_updated_at on public.hd08_profiles;
drop trigger if exists hd08_set_updated_at on public.hd08_profiles;

create trigger hd08_set_updated_at
before update on public.hd08_profiles
for each row
execute function public.hd08_set_updated_at();

-- ------------------------------------------------------------
-- 5) 옛 이름 함수 정리 (트리거를 뗀 뒤라야 지워진다)
-- ------------------------------------------------------------
drop function if exists public.handle_site_member_signup();
drop function if exists public.set_site_member_updated_at();

commit;

-- ============================================================
-- 실행 후 확인
--
-- 1) 이름 잔재가 없는가
--    select conname from pg_constraint
--     where conrelid = 'public.hd08_profiles'::regclass;
--    -> 전부 hd08_profiles_* 로 나와야 한다.
--
-- 2) 함수 권한에 anon이 남지 않았는가 (§3.7 — REVOKE 했으니 됐겠지로 넘어가지 말 것)
--    select proname, array_to_string(proacl, E'\n')
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and proname like 'hd08\_%';
--    -> anon=X 가 보이면 안 된다.
--
-- 3) 옛 객체가 남지 않았는가
--    select to_regclass('public.site_member_profiles');            -> null
--    select to_regproc('public.handle_site_member_signup');        -> null
--
-- Supabase Dashboard에서 함께 확인할 것
--   Authentication > Providers > Email: 활성화, Confirm email 권장
--   Authentication > Password Security: 최소 10자 이상
--   Authentication > URL Configuration:
--     Site URL / Redirect URLs 에 https://aebonlee.github.io/hd-08/ 등록
--
-- 주의: 브라우저에는 sb_publishable_... 키만 쓴다.
--       sb_secret_... / service_role 키는 절대 HTML/JS에 넣지 않는다.
-- ============================================================
