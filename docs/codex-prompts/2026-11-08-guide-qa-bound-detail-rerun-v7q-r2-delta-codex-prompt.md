# Guide QA bound detail — v7q-r2 델타 지시 (2026-11-08, Claude 작성)

**정본**: v7q·v7q-r1 델타. 충돌 시 이 문서가 이긴다.

## v7q-r1 리뷰 판정 (Claude, 로그 분석 완료)
4 실패 전부 **선존재 실패로 판정** — 빌드 진행을 막는 근거 없음:
- H4 1건·H5 2건(guide_guards_consistency_test.dart): 이 테스트들은 **인수인계의 미해결 가설 H4/H5를 문서화하는 테스트**다(테스트 본문에 "Actual (H4): StateError bound_event_missing_duplicate_or_foreign" 등 현재 동작을 기술). 이슈가 해결 안 됐으니 실패하는 것이 설계된 상태. v7q 변경(fence 경로 1줄)과 무관.
- readback "(a)" 1건(event_detail_guide_readback_test.dart:76): saved.summary 미발견. v7q 변경은 const 목록에 경로 1건 추가 — HTTP를 안 쓰는 위젯 테스트에 영향 불가능. 참고로 같은 게이트를 검증하는 event_detail_screen_test "saved detail guide is visible for text-only place readback"은 **통과**(로그 +335 구간) — 개별 테스트 셋업 문제로 추정.
- 그래도 확정 증거를 위해 1회 실험을 허용한다(아래 1단계). 10분 안에 안 끝나면 중단하고 빌드 진행.

## v7q-r2 실행 절차
1. **선존재 실험(선택, 최대 10분)**: QA 트리에서 `git stash push -- integration_test/support/real_ui_guide_native_environment.dart test/integration/native_guide_environment_contract_test.dart` → 4개 실패 테스트만 재실행 → 결과 기록 → `git stash pop`(반드시 복구 확인). 4건이 동일 실패하면 선존재 확정. pop 실패·충돌 시 즉시 중단 보고(이때만 BLOCKED).
2. **APK 재빌드·폰 재설치**(versionCode 198 유지, v7l 절차 동일: 큐 lease로 설치, SHA256 기록). dirty 수·위 4 실패는 게이트 아님.
3. 설치 확인(dumpsys package versionCode 198)까지만. 폰 UI 조작·라운드 실행·서버 호출 금지(v7r 별도 지시).
4. 보고: 실험 결과(했다면), diff 요약, APK 경로·SHA256, 설치 확인 출력, 잔여 경로만.

## 불변
메인 앱 lib 터치 금지. 서버 호출 0. monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 호스트 파일 작업 막히면 경로 보고(Claude 정리). stash 사용은 위 2파일에 한정하고 반드시 pop까지.
