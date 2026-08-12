#!/usr/bin/env bash
# ============================================================
# supabase/2026-08-12_hd08_membership.sql 을 임시 PostgreSQL에 실제로 적용해 검증한다.
#
# tsc도 vite build도 SQL을 잡아 주지 않는다. 운영에서 처음 돌리지 않기 위한 하네스다.
#
#   scripts/sqltest/run.sh          두 시나리오 검증
#   scripts/sqltest/run.sh --break  하네스가 실패를 실제로 잡는지 확인
#
# 시나리오 A(fresh)  : 빈 DB에 처음 적용 → 두 번 적용(재실행 안전성)
# 시나리오 B(legacy) : 옛 무접두사 스키마 + 가입 1건이 있는 DB에 적용(데이터 보존)
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${REPO}/supabase/2026-08-12_hd08_membership.sql"

PGBIN="${PGBIN:-/usr/local/opt/postgresql@17/bin}"
PGDATA="$(mktemp -d "${TMPDIR:-/tmp}/hd08-pg.XXXXXX")"
PGPORT="${PGPORT:-55432}"
PGHOST="${PGDATA}"

BREAK_MODE=0
[[ "${1:-}" == "--break" ]] && BREAK_MODE=1

cleanup() {
  "${PGBIN}/pg_ctl" -D "${PGDATA}" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "${PGDATA}"
}
trap cleanup EXIT

echo "== 임시 PostgreSQL 기동 (${PGDATA}) =="
"${PGBIN}/initdb" -D "${PGDATA}" -U postgres --no-sync >/dev/null
"${PGBIN}/pg_ctl" -D "${PGDATA}" -o "-p ${PGPORT} -k ${PGDATA} -c listen_addresses=''" -w start >/dev/null

psql() { "${PGBIN}/psql" -h "${PGHOST}" -p "${PGPORT}" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

run_scenario() {
  local db="$1" legacy="$2"
  echo
  echo "== 시나리오: ${db} =="
  psql -d postgres -c "drop database if exists ${db};" >/dev/null
  psql -d postgres -c "create database ${db};" >/dev/null

  psql -d "${db}" -f "${HERE}/00_stub.local.sql" >/dev/null
  if [[ "${legacy}" == "yes" ]]; then
    psql -d "${db}" -f "${HERE}/10_legacy.local.sql" >/dev/null
    echo "  옛 무접두사 스키마 + 가입 1건 준비"
  fi

  local target="${SCRIPT}"
  if [[ "${BREAK_MODE}" == "1" ]]; then
    # 일부러 깨뜨린 사본: anon REVOKE를 빼면 하네스가 잡아야 한다.
    target="${PGDATA}/broken.sql"
    sed 's/^revoke all on function public\.hd08_handle_signup() from anon;/-- (일부러 제거)/' \
      "${SCRIPT}" > "${target}"
    echo "  [--break] anon REVOKE 한 줄을 제거한 사본으로 실행"
  fi

  psql -d "${db}" -f "${target}" >/dev/null
  echo "  1차 적용 완료"

  psql -d "${db}" -f "${target}" >/dev/null
  echo "  2차 적용 완료 (재실행 안전)"

  assert_with "${db}" "${HERE}/20_assert.local.sql"
  if [[ "${legacy}" == "yes" ]]; then
    assert_with "${db}" "${HERE}/30_assert_legacy.local.sql"
  fi
}

# psql 출력을 파이프로 넘기면 종료코드가 grep 것으로 바뀐다.
# 파일로 받아 종료코드를 직접 본다 — 안 그러면 실패한 ASSERT가 조용히 통과한다.
assert_with() {
  local db="$1" file="$2" out="${PGDATA}/assert.out" rc=0
  psql -d "${db}" -f "${file}" >"${out}" 2>&1 || rc=$?
  # psql은 알림에 'psql:파일:줄: NOTICE:' 접두를 붙인다. 접두를 걷어내고 보여 준다.
  # 리포 경로에 공백이 있어 접두 길이를 가정할 수 없다. NOTICE:/ERROR: 앞을 통째로 자른다.
  grep -E 'NOTICE:|ERROR:' "${out}" | sed -E 's/^.*(NOTICE|ERROR):/  \1:/' || true
  if [[ ${rc} -ne 0 ]]; then
    echo "  !! 검증 실패 (${file##*/})"
    grep -E 'ERROR|DETAIL|CONTEXT' "${out}" | head -10 | sed 's/^/     /'
    return 1
  fi
}

# 2차 적용까지 성공해야 하므로 실패는 set -e로 즉시 드러난다
run_scenario fresh_db no
run_scenario legacy_db yes

echo
if [[ "${BREAK_MODE}" == "1" ]]; then
  echo "!! --break 모드인데 통과했다면 하네스가 고장 난 것이다."
else
  echo "== 전 시나리오 통과 =="
fi
