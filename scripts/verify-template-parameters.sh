#!/usr/bin/env bash
# =============================================================================
# verify-template-parameters.sh (P10)
# -----------------------------------------------------------------------------
# docs/ios/templates/ 의 두 가지 계약을 fail-closed 로 검증한다.
#
#   CHECK 1  PARAMETERS.md 가 "정의한" 파라미터 집합
#            == .tmpl 파일들이 "사용한" {{PARAM}} 집합
#            양방향 검사다: 정의만 되고 안 쓰이는 것(죽은 파라미터)과
#            쓰이는데 정의가 없는 것(문서화 누락) 둘 다 실패로 잡는다.
#
#   CHECK 2  .tmpl 본문에 앱 고유 리터럴(planflow / fluxstudio)이 0건
#            대소문자 무관. 남아 있으면 다음 앱이 그대로 복사해
#            잘못된 번들 ID 로 빌드한다.
#
# 실패 시 exit 1. 성공 시 exit 0.
# Windows git-bash / macOS / Linux 에서 동일하게 동작한다
# (GNU 전용 옵션과 mapfile 을 쓰지 않는다).
#
# 사용법:  bash scripts/verify-template-parameters.sh
# =============================================================================
set -euo pipefail

# --- 저장소 루트를 스크립트 위치 기준으로 해석한다(cwd 의존 금지) ------------
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
templates_dir="$repo_root/docs/ios/templates"
parameters_md="$templates_dir/PARAMETERS.md"

fail() {
  echo "::error title=BLOCKED_TEMPLATE_PARAMETERS::$*" >&2
  echo "TEMPLATE_PARAMETERS_VERIFY: FAIL" >&2
  exit 1
}

[ -d "$templates_dir" ] || fail "templates directory not found: $templates_dir"
[ -f "$parameters_md" ] || fail "PARAMETERS.md not found: $parameters_md"

# --- .tmpl 파일 목록 (없으면 실패 — 조용한 통과 방지) ------------------------
tmpl_list="$(find "$templates_dir" -type f -name '*.tmpl' | sort)"
[ -n "$tmpl_list" ] || fail "no .tmpl files found under $templates_dir"

tmpl_count="$(printf '%s\n' "$tmpl_list" | grep -c . || true)"
echo "Scanning $tmpl_count template file(s) under docs/ios/templates/"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

defined_file="$work_dir/defined.txt"
used_file="$work_dir/used.txt"

# --- CHECK 1a: PARAMETERS.md 가 정의한 파라미터 수집 -------------------------
# 정의는 표 행의 첫 칸에 `PARAM_NAME` 형태(백틱 + 대문자/숫자/언더스코어)로 나온다.
# 표 행만 본다(행이 '|' 로 시작). 본문 산문의 백틱 언급은 정의로 치지 않는다.
grep '^|' "$parameters_md" \
  | sed 's/^| *//' \
  | sed 's/ *|.*$//' \
  | grep -o '`[A-Z][A-Z0-9_]*`' \
  | tr -d '`' \
  | sort -u > "$defined_file" || true

[ -s "$defined_file" ] || fail "PARAMETERS.md defined no parameters — the extraction pattern may have drifted."

# --- CHECK 1b: .tmpl 이 사용한 {{PARAM}} 수집 --------------------------------
# {{NAME}} 에서 NAME 이 대문자로 시작하고 [A-Z0-9_] 로만 이뤄진 것만 파라미터로 본다.
# GitHub Actions 표현식(${{ github.ref }}, ${{ steps.x.outputs.y }}, ${{ always() }})은
# 소문자/점/괄호를 포함하므로 이 패턴에 걸리지 않는다.
printf '%s\n' "$tmpl_list" | while IFS= read -r tmpl_file; do
  [ -n "$tmpl_file" ] || continue
  grep -o '{{[A-Z][A-Z0-9_]*}}' "$tmpl_file" || true
done | sed 's/^{{//; s/}}$//' | sort -u > "$used_file"

[ -s "$used_file" ] || fail "no {{PARAM}} placeholders found in any .tmpl — templates may have been flattened."

# --- CHECK 1c: 양방향 차집합 -------------------------------------------------
only_defined="$(comm -23 "$defined_file" "$used_file")"
only_used="$(comm -13 "$defined_file" "$used_file")"

check1_failed=0

if [ -n "$only_used" ]; then
  check1_failed=1
  echo "" >&2
  echo "  [UNDOCUMENTED] .tmpl 이 쓰지만 PARAMETERS.md 에 정의가 없는 파라미터:" >&2
  printf '%s\n' "$only_used" | sed 's/^/    - /' >&2
  echo "    -> PARAMETERS.md 표에 행을 추가하라." >&2
fi

if [ -n "$only_defined" ]; then
  check1_failed=1
  echo "" >&2
  echo "  [UNUSED] PARAMETERS.md 가 정의했지만 어떤 .tmpl 도 쓰지 않는 파라미터:" >&2
  printf '%s\n' "$only_defined" | sed 's/^/    - /' >&2
  echo "    -> 템플릿에서 실제로 쓰거나, 정의를 지워라(죽은 파라미터 금지)." >&2
fi

if [ "$check1_failed" -eq 1 ]; then
  echo "" >&2
  fail "PARAMETERS.md and .tmpl placeholder sets do not match."
fi

defined_count="$(grep -c . "$defined_file" || true)"
echo "PARAMETER_SET_MATCH_PASS: PASS ($defined_count parameters, defined == used)"

# --- CHECK 2: .tmpl 본문에 앱 고유 리터럴 0건 --------------------------------
# 앱 고유값이 남으면 다음 앱이 그대로 복사해 잘못된 번들 ID 로 빌드한다.
literal_hits="$work_dir/literals.txt"
: > "$literal_hits"

printf '%s\n' "$tmpl_list" | while IFS= read -r tmpl_file; do
  [ -n "$tmpl_file" ] || continue
  rel_path="${tmpl_file#"$repo_root/"}"
  grep -in -E 'planflow|fluxstudio' "$tmpl_file" \
    | sed "s|^|$rel_path:|" >> "$literal_hits" || true
done

if [ -s "$literal_hits" ]; then
  echo "" >&2
  echo "  [APP_LITERAL] .tmpl 본문에 앱 고유 리터럴이 남아 있다:" >&2
  sed 's/^/    /' "$literal_hits" >&2
  echo "" >&2
  echo "    -> 해당 값을 {{PARAM}} 플레이스홀더로 치환하라." >&2
  echo "    -> 실제 값은 docs/ios/templates/<app>.values.md 에만 둔다." >&2
  echo "" >&2
  fail "app-specific literals found in template bodies."
fi

echo "NO_APP_LITERAL_PASS: PASS (0 occurrences of planflow/fluxstudio, case-insensitive)"

echo "TEMPLATE_PARAMETERS_VERIFY: PASS"
