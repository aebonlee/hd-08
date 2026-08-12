-- ============================================================
-- hd08_ 스키마 검증 ASSERT
-- 실패하면 exception으로 죽는다. 통과 시 마지막에 검사 개수를 찍는다.
-- (로컬 검증 전용)
-- ============================================================

\set ON_ERROR_STOP on

do $assert$
declare
  n int := 0;
  v_count int;
  v_text text;
  v_uid uuid;
  v_stamp timestamptz;
  v_ok boolean;
begin
  raise notice '검사 예정: 17건';

  -- ---------- 구조 ----------
  n := n + 1;
  if to_regclass('public.hd08_profiles') is null then
    raise exception '[1] hd08_profiles 테이블이 없다';
  end if;

  n := n + 1;
  select count(*) into v_count
    from pg_constraint
   where conrelid = 'public.hd08_profiles'::regclass
     and starts_with(conname, 'site_member_profiles');
  if v_count <> 0 then
    raise exception '[2] 제약조건에 옛 이름이 %건 남았다 (RENAME은 제약조건 이름을 바꾸지 않는다)', v_count;
  end if;

  n := n + 1;
  select count(*) into v_count
    from pg_constraint
   where conrelid = 'public.hd08_profiles'::regclass
     and not starts_with(conname, 'hd08_profiles');
  if v_count <> 0 then
    raise exception '[3] hd08_profiles_* 가 아닌 제약조건이 %건 있다', v_count;
  end if;

  n := n + 1;
  if to_regclass('public.site_member_profiles') is not null then
    raise exception '[4] 옛 테이블 site_member_profiles가 아직 있다';
  end if;

  n := n + 1;
  if to_regproc('public.handle_site_member_signup') is not null
     or to_regproc('public.set_site_member_updated_at') is not null then
    raise exception '[5] 옛 함수가 아직 있다';
  end if;

  n := n + 1;
  select column_default into v_text
    from information_schema.columns
   where table_schema = 'public' and table_name = 'hd08_profiles' and column_name = 'site_code';
  if v_text is null or v_text not like '%hd-08%' then
    raise exception '[6] site_code 기본값이 hd-08이 아니다: %', coalesce(v_text, '(null)');
  end if;

  n := n + 1;
  select relrowsecurity into v_ok from pg_class where oid = 'public.hd08_profiles'::regclass;
  if not v_ok then
    raise exception '[7] RLS가 꺼져 있다';
  end if;

  n := n + 1;
  select count(*) into v_count from pg_policies
   where schemaname = 'public' and tablename = 'hd08_profiles';
  if v_count <> 2 then
    raise exception '[8] 정책이 2개여야 하는데 %개다', v_count;
  end if;

  n := n + 1;
  select count(*) into v_count from pg_policies
   where schemaname = 'public' and tablename = 'hd08_profiles'
     and cmd in ('INSERT', 'DELETE');
  if v_count <> 0 then
    raise exception '[9] INSERT/DELETE 정책이 있으면 안 된다 (삽입은 트리거, 삭제는 cascade)';
  end if;

  -- ---------- 권한 ----------
  -- "REVOKE 했으니 됐겠지"로 넘어가면 anon=X가 남는다. proacl을 직접 읽는다.
  n := n + 1;
  select count(*) into v_count
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and starts_with(p.proname, 'hd08_')
     and array_to_string(p.proacl, ',') like '%anon=X%';
  if v_count <> 0 then
    raise exception '[10] hd08_ 함수 %건에 anon EXECUTE가 남아 있다', v_count;
  end if;

  n := n + 1;
  select count(*) into v_count
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and starts_with(p.proname, 'hd08_')
     and array_to_string(p.proacl, ',') like '%authenticated=X%';
  if v_count <> 2 then
    raise exception '[11] 트리거 함수 2개 모두 authenticated EXECUTE를 가져야 한다 (현재 %건)', v_count;
  end if;

  n := n + 1;
  if has_table_privilege('anon', 'public.hd08_profiles', 'select')
     or has_table_privilege('anon', 'public.hd08_profiles', 'insert') then
    raise exception '[12] anon이 프로필 테이블에 접근할 수 있다';
  end if;

  -- ---------- 동작: 정상 가입 ----------
  n := n + 1;
  v_uid := '22222222-2222-2222-2222-222222222222';
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'Normal.User@Example.com', jsonb_build_object(
    'signup_source', 'hd08-membership-v1',
    'full_name', '홍길동',
    'phone', '010-1234-5678',
    'privacy_consent', 'true'
  ));

  select count(*) into v_count from public.hd08_profiles where id = v_uid;
  if v_count <> 1 then
    raise exception '[13] 정상 가입인데 프로필이 생기지 않았다';
  end if;

  select email into v_text from public.hd08_profiles where id = v_uid;
  if v_text <> 'normal.user@example.com' then
    raise exception '[13] 이메일이 소문자로 정규화되지 않았다: %', v_text;
  end if;
  select phone into v_text from public.hd08_profiles where id = v_uid;
  if v_text <> '01012345678' then
    raise exception '[13] 전화번호에서 하이픈이 제거되지 않았다: %', v_text;
  end if;

  -- ---------- 동작: 다른 사이트 가입은 건드리지 않는다 ----------
  n := n + 1;
  v_uid := '33333333-3333-3333-3333-333333333333';
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'other.site@example.com', '{"signup_source":"some-other-site"}'::jsonb);

  select count(*) into v_count from public.hd08_profiles where id = v_uid;
  if v_count <> 0 then
    raise exception '[14] 다른 사이트 가입에서도 트리거가 발화했다';
  end if;

  -- ---------- 동작: site_code 빈 문자열 회귀 테스트 ----------
  -- 원본은 nullif(v_site_code, '')를 not null 컬럼에 넣어
  -- site_code가 빈 문자열로 오면 가입 전체가 실패했다.
  n := n + 1;
  v_uid := '44444444-4444-4444-4444-444444444444';
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'empty.sitecode@example.com', jsonb_build_object(
    'signup_source', 'hd08-membership-v1',
    'full_name', '김빈값',
    'phone', '01098765432',
    'privacy_consent', 'true',
    'site_code', ''
  ));

  select site_code into v_text from public.hd08_profiles where id = v_uid;
  if v_text is distinct from 'hd-08' then
    raise exception '[15] site_code 빈 문자열이 hd-08으로 채워지지 않았다: %', coalesce(v_text, '(null)');
  end if;

  -- ---------- 동작: 잘못된 입력은 막는다 ----------
  n := n + 1;
  begin
    insert into auth.users (id, email, raw_user_meta_data)
    values ('55555555-5555-5555-5555-555555555555', 'no.consent@example.com', jsonb_build_object(
      'signup_source', 'hd08-membership-v1',
      'full_name', '무동의',
      'phone', '01011112222',
      'privacy_consent', 'false'
    ));
    raise exception '[16] 동의 없이 가입이 통과했다';
  exception
    when others then
      if position('동의' in sqlerrm) = 0 then
        raise exception '[16] 예상과 다른 오류: %', sqlerrm;
      end if;
  end;

  n := n + 1;
  begin
    insert into auth.users (id, email, raw_user_meta_data)
    values ('66666666-6666-6666-6666-666666666666', 'bad.phone@example.com', jsonb_build_object(
      'signup_source', 'hd08-membership-v1',
      'full_name', '번호오류',
      'phone', '02012345678',
      'privacy_consent', 'true'
    ));
    raise exception '[17] 잘못된 전화번호로 가입이 통과했다';
  exception
    when others then
      if position('휴대전화' in sqlerrm) = 0 then
        raise exception '[17] 예상과 다른 오류: %', sqlerrm;
      end if;
  end;

  raise notice '통과: %건', n;
  if n <> 17 then
    raise exception '검사 개수가 예정과 다르다: 예정 17, 실제 %', n;
  end if;
end
$assert$;

-- updated_at 트리거는 별도 트랜잭션이라야 now()가 움직인다 (같은 트랜잭션이면 값이 같다)
do $touch$
begin
  update public.hd08_profiles
     set full_name = '홍길동2'
   where id = '22222222-2222-2222-2222-222222222222';
end
$touch$;

do $assert_updated$
declare
  v_created timestamptz;
  v_updated timestamptz;
begin
  select created_at, updated_at into v_created, v_updated
    from public.hd08_profiles
   where id = '22222222-2222-2222-2222-222222222222';
  if v_updated <= v_created then
    raise exception '[18] updated_at 트리거가 동작하지 않았다 (created=%, updated=%)', v_created, v_updated;
  end if;
  raise notice '통과: updated_at 트리거 1건';
end
$assert_updated$;
