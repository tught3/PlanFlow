#!/usr/bin/env bash
# verify-docs-consistency.sh — docs 안의 `path/to/file.ext:LINE` 참조가 실재하는지 검증한다.
#
# 왜 필요한가
#   이 저장소의 iOS 문서들은 판정 근거를 "파일:줄" 형태로 인용한다. 코드가 바뀌면
#   그 줄번호는 조용히 stale해지고, 문서는 존재하지 않는 근거를 확정 사실처럼
#   주장하게 된다. 이 스크립트는 최소한 (a) 인용된 파일이 실재하고 (b) 인용된
#   줄번호가 파일 길이 이내인지를 기계적으로 강제한다.
#
# 검증하지 않는 것 (정직 고백 — 이 게이트의 한계)
#   - 그 줄의 *내용*이 문서 주장과 맞는지는 검증하지 않는다. 줄 삽입/삭제로
#     번호만 밀린 경우는 잡지 못한다(범위 안에 남아 있으므로).
#   - 경로 부분에 '/'가 없는 bare 파일명 참조(예: `ios-readiness.yml:90`)는
#     저장소 어디의 파일인지 모호하므로 SKIP하고 개수만 보고한다.
#     이 SKIP은 조용하지 않다 — 실행할 때마다 요약에 출력된다.
#
# 사용법
#   bash scripts/verify-docs-consistency.sh [스캔루트 ...]     # 기본: docs/ios
#
# 종료 코드
#   0 = 깨진 참조 없음 / 1 = 깨진 참조 있음 / 2 = 사용법·환경 오류
#
# Windows git-bash(MINGW64)에서 실행 가능해야 한다.

set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)" || {
  echo "FATAL: cannot resolve repository root" >&2
  exit 2
}
cd "$repo_root" || exit 2

if [ "$#" -gt 0 ]; then
  scan_roots=("$@")
else
  scan_roots=("docs/ios")
fi

for root in "${scan_roots[@]}"; do
  if [ ! -d "$root" ] && [ ! -f "$root" ]; then
    echo "FATAL: scan root not found: $root" >&2
    exit 2
  fi
done

# 참조 토큰 패턴.
#   (선택적 선행 '.') + 확장자를 가진 경로 + ':' + 줄번호 (+ 선택적 '-끝줄')
#   예: scripts/ios/e2e_xctest_flow.sh:263 / lib/main.dart:107 / foo.md:10-20
#   선행 '.'을 허용하지 않으면 `.github/workflows/x.yml:52` 가 `github/...` 로
#   잘려 "파일 없음" 오탐이 된다(최초 구현에서 실제로 5건 발생, 이 주석이 그 회귀 가드다).
readonly TOKEN_RE='\.?[A-Za-z0-9_][A-Za-z0-9_./+-]*\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?'

checked=0
skipped_bare=0
failed=0
declare -a failures=()
declare -a skipped_samples=()

line_count() {
  # 마지막 줄에 개행이 없어도 정확히 세도록 awk 사용.
  awk 'END { print NR }' "$1"
}

doc_list="$(mktemp)" || exit 2
trap 'rm -f -- "$doc_list"' EXIT

for root in "${scan_roots[@]}"; do
  if [ -f "$root" ]; then
    printf '%s\n' "$root" >> "$doc_list"
  else
    find "$root" -type f -name '*.md' -print >> "$doc_list"
  fi
done

if [ ! -s "$doc_list" ]; then
  echo "FATAL: no markdown files found under: ${scan_roots[*]}" >&2
  exit 2
fi

doc_count="$(awk 'END { print NR }' "$doc_list")"

while IFS= read -r doc; do
  [ -n "$doc" ] || continue

  # 줄번호와 함께 토큰을 뽑아 실패 보고에 문서 위치를 남긴다.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    doc_line="${hit%%:*}"
    token="${hit#*:}"

    # http(s) URL 안의 host:port 등을 배제.
    case "$token" in
      http://*|https://*) continue ;;
    esac

    ref_path="${token%%:*}"
    ref_lines="${token#*:}"

    # 경로에 '/'가 없으면 저장소 내 위치가 모호하다 -> SKIP (개수 보고).
    case "$ref_path" in
      */*) : ;;
      *)
        skipped_bare=$((skipped_bare + 1))
        if [ "${#skipped_samples[@]}" -lt 5 ]; then
          skipped_samples+=("$doc:$doc_line -> $token")
        fi
        continue
        ;;
    esac

    checked=$((checked + 1))

    if [ ! -f "$ref_path" ]; then
      failures+=("$doc:$doc_line -> '$token': referenced file does not exist")
      failed=$((failed + 1))
      continue
    fi

    total="$(line_count "$ref_path")"
    start="${ref_lines%%-*}"
    end="${ref_lines##*-}"

    # 선행 0 제거 후 10진수 강제 (08 등을 8진수로 오해하지 않도록).
    start=$((10#$start))
    end=$((10#$end))

    if [ "$start" -lt 1 ]; then
      failures+=("$doc:$doc_line -> '$token': start line must be >= 1")
      failed=$((failed + 1))
      continue
    fi

    if [ "$end" -lt "$start" ]; then
      failures+=("$doc:$doc_line -> '$token': end line $end precedes start line $start")
      failed=$((failed + 1))
      continue
    fi

    if [ "$end" -gt "$total" ]; then
      failures+=("$doc:$doc_line -> '$token': line $end is beyond '$ref_path' length ($total lines)")
      failed=$((failed + 1))
      continue
    fi
  done < <(grep -noE "$TOKEN_RE" -- "$doc" 2>/dev/null)
done < "$doc_list"

echo "verify-docs-consistency: scanned $doc_count markdown file(s) under: ${scan_roots[*]}"
echo "  validated file:line references : $checked"
echo "  skipped (bare filename, no '/'): $skipped_bare"
if [ "$skipped_bare" -gt 0 ] && [ "${#skipped_samples[@]}" -gt 0 ]; then
  for s in "${skipped_samples[@]}"; do
    echo "    SKIP $s"
  done
  if [ "$skipped_bare" -gt "${#skipped_samples[@]}" ]; then
    echo "    ... and $((skipped_bare - ${#skipped_samples[@]})) more"
  fi
fi

if [ "$failed" -gt 0 ]; then
  echo
  echo "FAIL: $failed broken reference(s):"
  for f in "${failures[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "PASS: no broken file:line references"
exit 0
