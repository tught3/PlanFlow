# Guide QA bound detail — v7q 델타 지시 (2026-11-08, Claude 작성)

**정본**: v7p 델타 + v3~v7o. 충돌 시 이 문서가 이긴다. **이번은 QA 트리 코드 수정 라운드다(v7k 선례).**

## v7p 리뷰 판정 (Claude, 전문 분석 완료)
게이트 실패 원인 **확정 — (b) `_guideReadbackReady=false`**:
- events GET 3건 전부 200(목록 조회). 그런데 fetchEvent 쿼리 형태(`select,id,user_id` — event_repository.dart:951-956)의 events GET이 **`already failed` 사유로 거부됨**(events-fence-summary index 24/26).
- latch 원인: `group_event_comments` 읽기가 허용 목록에 없어 **fatal deny** (fence-records-summary index 16-17: `table group_event_comments not in read allowlist`) → `deny()`가 `failed=true`로 봉쇄(real_ui_guide_native_environment.dart L795) → 이후 모든 요청(fetchEvent 포함) `already failed` 거부.
- fetchEvent가 StateError로 던져지면 event_detail_screen.dart의 catch가 `_loadError`만 set하고 `_guideReadbackReady`는 false 유지(L231-237) → 앵커 미렌더 → "안내할 실제 화면을 기다리고 있어요". 라운드 상태 자체는 정상(persisted: savedDetail/createdEventId 있음/savedLocalDate=2026-11-05T05:00:00Z, errorCode 없음 — run=paused·rev21은 앱 suspend에 의한 정상 기록).
- createdEventId 불일치 가설(a)는 기각 — persisted 진행상태에 createdEventId 존재 확인.

## v7q 코드 수정 (QA 트리만: `.tmp/voice-first-tour-20261017/`)
1. `integration_test/support/real_ui_guide_native_environment.dart`의 `optionalBackgroundRestGetPaths`(L330 근처)에 `'/rest/v1/group_event_comments'`를 **추가** — groups/group_backups과 동일한 "optional background: 미전달·비봉쇄(NonGuideOptionalBackgroundBlocked), 호출처가 이미 내부 swallow" 계약. GroupInstructionInboxService는 오류를 스스로 잡는다(group_instruction_inbox_service.dart L82, L150) — 계약 충족. 파일 상단 계약 주석도 한 줄 업데이트(deliberate omission 목록에 추가됨을 명시).
2. `test/integration/native_guide_environment_contract_test.dart` L913 근처 기대값을 `<String>['/rest/v1/groups', '/rest/v1/group_backups', '/rest/v1/group_event_comments']`로 갱신 + `group_event_comments` exact-match true 케이스 1건 추가. 부정 케이스(쿼리 붙으면 false 등) 유지.
3. QA 트리 전체 테스트 실행(기존 관련 스위트 + 위 계약 테스트). 전부 통과 필수.
4. **APK 재빌드·재설치**(v7l 절차 동일: versionCode 198 유지, SHA256 기록). 빌드 전 `git -C E:\FluxStudio\PlanFlow\.tmp\voice-first-tour-20261017 status`로 수정 파일 2개만 dirty인지 확인.
5. 결과 보고: diff 요약, 테스트 수, APK 경로·SHA256, 잔여 파일 경로만(삭제 시도 금지).

## 다음 라운드 예고 (v7r — 별도 지시)
설치 확인 후 Claude가 최종 검증 라운드 지시서를 만든다. 이번 v7q에서는 폰 조작·라운드 실행 금지.

## 불변
메인 앱 lib 터치 금지. 수정은 위 2파일만. 서버 호출 0(refresh/begin 등 전부 금지). monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰·키 값 출력 금지. 호스트 파일 작업 막히면 경로 보고(Claude 정리).
