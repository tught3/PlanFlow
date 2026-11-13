# v7u-r3 델타 지시 — sessionExpired도 신세션 부트스트랩으로 (2026-11-14, Claude 작성)

**정본**: v7u·v7u-r2 델타. **한 걸음 남았다: 이번엔 sessionExpired 경로만 추가하면 된다.**

## Claude 진단
- 화면 문구가 바뀜("deadline has passed" → "session has expired") = v7u 수정(deadlineExpired → 새 세션 부트스트랩)은 **정상 동작**했고, 이제 resume record에 저장된 **세션 토큰 만료**가 다음 관문으로 나온 것.
- 앱에는 이미 세션 갱신 능력이 있다: 기동 시 `auth_bootstrap phase=refresh_start → refresh_success` 로그(logcat 실측, v7o) — 앱이 저장된 refresh_token으로 갱신 가능. autoRefreshToken:false라 자동은 아니지만 갱신 경로 자체는 존재.
- 따라서: **sessionExpired일 때도 부트스트랩으로 처리** — 저장된 refresh_token으로 갱신 1회 시도(기존 auth_bootstrap 경로 재사용) → 성공 시 새 수동 세션 기동, 실패 시 기존 fail-closed 유지. record 폐기는 하지 않는다(갱신 가능한 자산).

## v7u-r3 실행 절차
1. QA 워크트리에서 코드 확장: `real_ui_guide_manual_app.dart`(또는 resume record 검증 위치)의 `ManualResumeFailure.sessionExpired` 처리를 복구 화면 대신 **갱신 후 새 수동 세션 부트스트랩**으로 변경 — auth refresh 1회 성공 시 새 runId·deadline으로 기동, 실패 시 기존 fail-closed. deadlineExpired 케이스(v7u 완료분) 유지. 주석에 QA relaunch 목적 명시.
2. 테스트: sessionExpired 케이스 신규 검증(만료 세션 → 갱신 성공 → 기동; 갱신 실패 → fail-closed) + 기존 manual resume·환경 계약 스위트 통과 유지.
3. 빌드(debug, versionCode 198, SHA256 기록) → install -r → dumpsys 확인.
4. 기동 확인 → **만료 화면 부재 + 인트로 또는 1/7 홈 마이크 코치마크 표시** → 스크린샷+dump. 튜토리얼이 떴으면 CEO가 자연스럽게 진행(연습 발화 3회 → 2/7 → 3/7 → 4/7 조회 → 5/7; 6회째 제출은 ai_cap_exceeded 예상 → 5/7까지가 성공 기준).
5. 커밋·push(브랜치 fix/voice-first-tour-20261017, 훅 지연 감안).
6. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고. 그래도 만료 화면이면 journal·dump 수집 후 중단 보고(Claude 판정).

## 불변
v7u-r2 불변 전부 유효: 수정은 위 1파일(+테스트), 메인 앱 lib 터치 금지, AI 하드캡 5회(2 사용·3 잔여), 건너뛰기 절대 금지, monkey/kill-server/래퍼 우회/큐 state 편집 금지, OS 설정 변경 금지, 토큰·키 값 출력 금지, 완료 판정은 화면 증거로, .tmp/guide-step3-cta-fix-20261113 건드림 금지, 서명 자산은 복사 완료 상태 유지. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 코드 확장 diff 요약 / 테스트 증거 / APK SHA256·설치 확인 / 튜토리얼 표시 증거 경로 / 도달 단계·AI 소비 / 잔여 경로.
