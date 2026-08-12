-- ============================================================
-- 이관 시나리오용: 강의 중 만들었던 옛 무접두사 스키마를 그대로 재현하고
-- 회원 1명을 넣어 둔다. 본 스크립트가 이 데이터를 보존하는지 확인한다.
-- (로컬 검증 전용 — 00_stub.local.sql의 가드가 먼저 돈다)
-- ============================================================

create table if not exists public.site_member_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null check (char_length(btrim(full_name)) between 2 and 50),
  phone text not null check (phone ~ '^01[016789][0-9]{7,8}$'),
  privacy_consent_at timestamptz not null default now(),
  site_code text not null default 'default',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.site_member_profiles enable row level security;

create policy "site_member_select_own"
on public.site_member_profiles
for select to authenticated
using ((select auth.uid()) = id);

create policy "site_member_update_own"
on public.site_member_profiles
for update to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create or replace function public.handle_site_member_signup()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  return new;
end;
$$;

create or replace function public.set_site_member_updated_at()
returns trigger language plpgsql security invoker set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger on_auth_user_created_site_member_profiles
after insert on auth.users
for each row
when ((new.raw_user_meta_data ->> 'signup_source') = 'reusable-membership-v1')
execute function public.handle_site_member_signup();

create trigger set_site_member_profiles_updated_at
before update on public.site_member_profiles
for each row
execute function public.set_site_member_updated_at();

-- 강의 중 가입한 수강생 1명
insert into auth.users (id, email, raw_user_meta_data)
values (
  '11111111-1111-1111-1111-111111111111',
  'lecture.student@example.com',
  '{"signup_source":"reusable-membership-v1"}'::jsonb
);

insert into public.site_member_profiles (id, email, full_name, phone, site_code)
values (
  '11111111-1111-1111-1111-111111111111',
  'lecture.student@example.com',
  '강의수강생',
  '01012345678',
  'default'
);
