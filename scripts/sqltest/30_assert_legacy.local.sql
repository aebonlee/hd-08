-- ============================================================
-- 이관 시나리오 전용 ASSERT: 강의 중 가입한 회원이 살아남았는가
-- (로컬 검증 전용)
-- ============================================================

\set ON_ERROR_STOP on

do $assert_legacy$
declare
  v_name text;
  v_site text;
begin
  raise notice '검사 예정: 2건 (이관)';

  select full_name, site_code into v_name, v_site
    from public.hd08_profiles
   where id = '11111111-1111-1111-1111-111111111111';

  if v_name is null then
    raise exception '[L1] 옛 테이블의 가입 기록이 사라졌다 (RENAME이 아니라 재생성된 것)';
  end if;
  if v_name <> '강의수강생' then
    raise exception '[L1] 이관된 이름이 다르다: %', v_name;
  end if;

  -- 기존 행의 site_code는 그대로 둔다. 기본값만 바뀌므로 과거 값은 보존돼야 한다.
  if v_site <> 'default' then
    raise exception '[L2] 기존 행의 site_code가 임의로 바뀌었다: %', v_site;
  end if;

  raise notice '통과: 2건 (이관)';
end
$assert_legacy$;
