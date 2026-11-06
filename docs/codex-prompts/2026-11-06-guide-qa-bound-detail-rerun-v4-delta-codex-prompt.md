# Guide QA bound detail 재실행 — v4 델타 지시 (2026-11-06, Claude 작성)

**정본은 v3 그대로**: `docs/codex-prompts/2026-11-06-guide-qa-bound-detail-rerun-v3-codex-prompt.md`
이 문서는 v3 재실행 시 달라진 점만 정의한다. v3의 순서·중단 조건·금지사항은 모두 유효하며, 아래 델타와 충돌하면 이 문서가 이긴다.

## 배경 (v3 실행 결과)
- v3는 step_1(FIFO lease)에서 900초 대기 후 BLOCKED. 서버·adb 호출 0회, 승인 B·C 미사용(유효). 상태 파일: `.codex/tasks/planflow-tutorial-bound-round-20261106-v3.json`.
- v3 때 소유자였던 ValueFlow `d20c738 release and install`는 큐에서 해제됨(2026-11-06 16:00 Claude가 state/queue.json 읽기로 확인).
- 현재 큐에 만료된 대기 job 2개(`일상캐치 남은 예약 작업`, `legacy-pid-43324`)가 남아 있을 수 있다. **state 파일 편집·강제 제거 금지는 유지** — 만료 정리는 helper가 하게 두고, 새 FIFO 티켓을 enqueue한 뒤 최대 30분 대기한다.

## 승인 상태 (변화 없음, 재확인)
- 승인 A(refresh_token grant): **소비됨 — 어떤 형태로도 재시도 금지.** 세션 토큰 재확보는 승인 C 경로만.
- 승인 B(events 읽기 + `begin_real_ui_guide` 1회), 승인 C(generate_link + verify 총 1회, 실패 시 재시도 금지): 미사용·유효. v3 문서 기록 범위만.

## v3 대비 델타 (이것만 추가/변경)
1. **lease 획득 직후 첫 행동**: 폰 회전값(`settings get system accelerometer_rotation`)을 작업 시작 전 값으로 읽고 기록한다(작업 종료 시 전후 0→0 비교용). v3에서 NOT_READ였던 것의 재발 방지.
2. **이전 큐 티켓 재사용 금지 유지**: v3 티켓(`9d9cbaa07ded49c780ae413b14a6de67`)은 이미 취소·삭제됨. 반드시 새 티켓.
3. **30분 대기 후에도 lease 실패 시**: 소유자 task 이름·ReservedUntil/Expires(호스트 시각 포함)를 상태 JSON에 남기고 BLOCKED 보고. 강제 제거 시도 금지.
4. 영수증(승인 B) 발급 후 5분 내 `start-bound-detail-round.ps1` 시작, 30분 QA 세션 창 안에서 UI 증거(스크린샷 + uiautomator dump) 수집 — v3와 동일. 증거 파일 경로를 상태 JSON `screen_evidence`에 채운다.
5. 서버 응답(토큰)은 수신 즉시 파일 write → 검증 → 원자적 교체(v2 소실 사고 재발 방지, v3와 동일).

## 완료 판정 (변경 없음)
폰 화면 증거(스크린샷+dump) 없이는 PARTIAL/BLOCKED. 서버 200·failed=false만으로 완료 아님.
