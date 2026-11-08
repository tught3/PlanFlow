# v8b-r3 델타 지시 (2026-11-08, Claude 작성)

**정본**: v8b-r2 델타. **r2 수행은 정확했다 — 이제 판정과 마무리 수정 지시다.**

## Claude 판정 (r2 결과 리뷰)
- 기준선(origin/main) 자체가 **83 실패**다. 머지 트리는 22 — 즉 **머지는 실패를 61건 줄인다**(76건 기준선 실패가 해소). main의 전체 스위트는 애초에 그린 게이트가 아니다.
- 머지 전용 15건은 QA 트리(브랜치 소스)에서 동일 재현 → 머지 사고가 아닌 **피처 코드/테스트 자체의 문제**. 이 중 실제 결함 후보는 음성 자동 저장 2건: 코드 설계(event_range_utils "시작 단독 수정 시 1시간 기본·스테일 종료 재계산", a20782d7에서 커밋된 의도 주석 있음)와 화면 자동 저장 경로(원래 길이 재사용)가 **서로 모순** — 테스트가 설계 문서 역할을 하므로 **프로덕션 화면 경로가 설계에 맞게 수정 대상**이다.
- non-FF 문제는 오해: origin/main이 r2 지시 문서 커밋(fcdd0c3)으로 앞선 것뿐 — **머지 트리를 reset --hard origin/main 후 재머지하면 끝나는 루틴 작업**이다.
- readback (a)의 saved.departure 절반 실패 + 테스트 구성 누락류(guide scope·source-order·QA define)는 테스트 측 정비 대상.

## v8b-r3 실행 절차 (QA 트리에서 수정 → 브랜치 → 재머지)
1. **음성 자동 저장 정합(우선)**: 화면 자동 저장 경로가 시작 단독 변경 시 `shiftEventEndWhenStartChanges`/event_range_utils 설계(1시간 기본, 스테일·무효 종료 재계산, 멀티데이 플래그 재계산, 명시적 종료 큐는 실패 폐쇄 — utteranceHasExplicitEndOrDurationCue)를 따르도록 수정. 테스트 2건("1시간 기본 길이", "1박2일 종료·멀티데이 재계산")이 스펙. 수정은 화면 경로와 컨트롤러 중 **설계 경로에 이미 있는 유틸을 재사용하는 쪽**으로 최소화.
2. **readback (a) saved.departure**: saved.summary는 렌더되고 departure가 0개인 원인 규명 — event_detail_screen의 `saved.departure` 앵커 조건(`_smartPreparationAlarms.isNotEmpty || _guideAckVisible()`)과 테스트 fixture(빈 준비알람 서비스 주입분) 대조. 게이트 버그면 최소 수정, fixture 문제면 테스트 수정. 어느 쪽이든 결과와 근거 기록.
3. **테스트 구성 누락류**(guide scope 누락·source-order·QA define 등 나머지 머지 전용 실패): 테스트 측 정비로 통과. 프로덕션 결함으로 판명되면 그 테스트는 수정 없이 실패 목록에 남기고 근거 보고(임의 완화 금지).
4. **브랜치 갱신**: 위 수정을 QA 트리에서 커밋(훅 지연 감안 — 완료까지 대기, 이전 성공 사례 있음) → push origin fix/voice-first-tour-20261017. 커밋 막히면 stale lock 확인 후 경로 보고(Claude 정리).
5. **재머지**: 머지 워크트리에서 fetch → `git reset --hard origin/main`(현재 fcdd0c3) → `git merge --no-ff fix/voice-first-tour-20261017` → analyze 오류 0 → 전체 테스트 1회. **푸시 게이트: 머지 트리 실패 ⊆ 기준선 실패(83건 집합)** — 즉 기준선에 없는 실패가 0이어야 한다. readback (a)·남은 구성 실패는 이 기준으로 판정(기준선에도 같은 테스트가 실패하는지 이름 대조).
6. 게이트 통과 시 `git push origin HEAD:main` → 머지·베이스라인 워크트리 remove --force + prune → 완료 보고. 미통과 시 실패 diff 보고 후 정지.
7. 보고: 결과 한 줄 / 음성 2건 수정 내용 / (a) 원인·조치 / 구성 실패 정비 결과 / 최종 실패 집합 비교 / 머지 커밋·push 확인 / 잔여 경로.

## 불변
v8b-r2 불변 전부 유효(베이스라인 워크트리 수정 금지, 타 세션 프로세스 접촉 금지, force push 금지, 폰·서버 0, 토큰 출력 금지). 프로덕션 수정은 1단계 화면 자동 저장 경로와 2단계 게이트 최소 수정 한정 — 그 외 발견은 기록만.
