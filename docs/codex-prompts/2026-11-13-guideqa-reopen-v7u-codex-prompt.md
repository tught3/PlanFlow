# v7u 지시 — QA 앱 자체 수정: deadlineExpired 시 새 수동 세션 부트스트랩 (2026-11-13, Claude 작성)

**정본**: v7t·v7t-r2 델타. **스토리지 추적은 종료 — 앱 코드가 해답이다.**

## Claude 진단 (브랜치 소스 직접 확인)
- "The saved guide QA session deadline has passed."는 `integration_test/real_ui_guide_manual_app.dart` L336의 **앱 자체 판정 문자열**이다. 앱이 기동 시 FlutterSecureResumeStore의 resume record를 읽어 deadline이 지났으면 복구 화면을 띄운다 — secure storage 파일 이름을 추적하는 것보다 **이 판정을 바꾸는 것이 확실하다.**
- QA 앱은 우리가 빌드·설치하는 우리 앱이다. CEO 요구("바로 띄워줘")에 맞는 최소 수정: **deadlineExpired일 때 복구 화면 대신 저장된 resume record를 폐기하고 새 수동 세션(새 runId·새 deadline)을 부트스트랩한다.**

## v7u 실행 절차
1. **QA 워크트리 재생성**: `.tmp/voice-first-tour-20261017`은 소실됐다. `git worktree add E:/FluxStudio/PlanFlow/.tmp/voice-first-tour-20261017 fix/voice-first-tour-20261017`(tip 058f107b — 기능은 main에 통합돼 있어 소실 위험 없음). `.tmp/guide-step3-cta-fix-20261113`는 타 세션 워크트리 — 절대 건드리지 말 것.
2. **코드 수정 1건**: `integration_test/real_ui_guide_manual_app.dart` 기동 부트스트랩에서 `ManualResumeFailure.deadlineExpired`를 복구 화면 대신 **새 수동 세션 부트스트랩 경로**로 처리 — 저장된 resume record 삭제(secure store key 포함) → 새 runId·새 deadline(기존 config 기본값)으로 env 재구성 → 정상 기동. deadlineExpired 케이스만(다른 failure는 기존 fail-closed 유지). 주석에 "QA relaunch: expired manual resume bootstraps a fresh session" 명시.
3. **테스트**: manual resume 관련 테스트 실행 + deadlineExpired 케이스 신규 검증(만료 record → 새 세션 부트스트랩 → 기동 성공). 기존 guide 계약 스위트 통과 유지.
4. **빌드·설치**: QA debug APK 재빌드 → install -r(versionCode 198, SHA256 기록, dumpsys 확인).
5. **기동 확인**: 앱 실행 → 만료 화면 부재 + 인트로 또는 1/7 홈 마이크 코치마크 표시 → 스크린샷+dump. **튜토리얼이 떴으면 CEO가 자연스럽게 진행(발화·탭 — AI 잔여 3회).**
6. **커밋·push**: 브랜치 fix/voice-first-tour-20261017에 커밋·push(훅 지연 감안 — 완료까지 대기, stale lock 시 경로 보고).
7. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고.
8. 그래도 만료 화면이면 빌드 로그·dump 수집 후 중단 보고(Claude 판정).

## 불변
수정은 위 1파일(+테스트)만. 메인 앱 lib 터치 금지. AI 하드캡 5회(2 사용·3 잔여). 건너뛰기 버튼 절대 탭 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰 출력 금지. 완료 판정은 화면 증거로. `.tmp/guide-step3-cta-fix-20261113` 건드림 금지. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 코드 수정 diff 요약 / 테스트 증거 / APK SHA256·설치 확인 / 튜토리얼 표시 증거 경로 / 잔여 경로.
