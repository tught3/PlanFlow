# Guide QA bound detail — v7b 델타 지시 (2026-11-07, Claude 작성)

**정본**: v7 델타 (`docs/codex-prompts/2026-11-06-guide-qa-bound-detail-rerun-v7-delta-codex-prompt.md`) + v3~v6b. 충돌 시 이 문서가 이긴다.

## v7 리뷰 판정 (Claude)
BLOCKED 인정 — 원인은 무선 ADB 기기 offline(S23 Ultra 192.168.0.45:40345 응답 없음, 기기 1대 offline). 서버 호출 0회: `action_link` 원문·승인 B 전부 유효, 재발급 불필요(호출 금지 유지). 환경 복구 후 즉시 재개 가능.

## 사전 조건 (Codex 시작 전 사용자 확인 사항)
- S23 Ultra가 네트워크에 붙어 있고 화면이 켜져 있을 것. 무선 ADB가 끊겼으므로 사용자가 폰에서 무선 디버깅을 다시 켜거나 USB를 연결한 뒤 지시해야 함. **Codex가 폰 물리 조작을 대신하지 않는다.**

## v7b 델타 (v7 절차 재개 시)
1. **serial 하드코딩 금지**: `40345` 등 과거 포트는 재연결 후 무의미. lease 획득 후 `adb devices`로 온라인 기기를 새로 탐색하고, 모델명(SM-S918N) + QA 앱(versionCode 198)으로 정확히 1대만 매칭되면 그 serial을 사용. 0대 또는 2대 이상이면 BLOCKED 보고.
2. **남은 티켓 파일 정리**: v7이 남긴 `qa-live/guide-qa-bound-v7-20261107-new.adb-ticket.json`은 재사용 금지 — 공식 helper로 취소(만료 상태면 상태 확인 후)하고 파일을 제거한 뒤 새 FIFO 티켓으로 시작. state 파일 직접 편집 금지 유지.
3. 그 외 전부 v7 그대로: 최상위 `id` == QA UID 검증 → `action_link`으로 /verify 1회(원문 즉시 저장 → 원자적 교체) → 승인 B 1회씩 → 라운드 시작 → 30분 창(세션 잔여기간과 min) 내 스크린샷+uiautomator dump → `screen_evidence` 기록 → lease 반납, 회전값 전후 기록.

## 불변
- generate_link 재호출 금지. verify 1회, events 읽기 1회, begin 1회. `adb kill-server`·monkey·state 편집 금지. 증거 없는 완료 판정 금지.
