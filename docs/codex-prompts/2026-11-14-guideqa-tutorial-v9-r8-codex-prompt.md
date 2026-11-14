# v9-r8 지시 — 가이드 진행 저장 경합 수정(본앱 lib) 후 4/7 재개 (2026-11-14, Claude 작성)

**정본**: v9-r7 델타. **본앱 실버그 확정 — CEO 지시대로 본앱 코드 수정에 들어간다.**

## Claude 진단 (origin/main 소스 직접 확인)
- `lib/onboarding/real_ui_guide/guide_providers.dart` L70-73: `setString` 직후 `getString != raw`면 `StateError('Guide write readback failed')`. 조회 단계에서 저장이 동시에 두 번 겹치면(파싱 응답·라우트 이벤트 경합) 읽기 값이 어긋나 예외 → dispatch 실패 → **4/7 조회가 멈춤**(r7 로그 실측).
- 수정: ① 저장을 **직렬화**(진행 중인 save가 있으면 뒤에 줄 세우기 — 단일 flight 큐) ② 읽기 불일치 시 **1회 재시도** ③ 재시도 후에도 불일치면 기존대로 throw(fail-closed 유지). 인출 검증 자체는 유지한다(저장 검증 약화 금지).

## v9-r8 실행 절차
1. **브랜치 생성**: origin/main에서 작업 브랜치 생성(예: `fix/guide-progress-save-race-20261114`). 워크트리는 origin/main 기준 새 임시 워크트리 사용(메인 워크트리는 타 세션 브랜치 상태 — 건드리지 않음).
2. **lib 수정**: guide_providers.dart의 GuideProgressStore.save — ① 진행 중 save 직렬화(간단한 Future 체인 또는 뮤텍스) ② getString 불일치 시 1회 재시도(짧은 지연 후 재 setString→재검증) ③ 최종 불일치 시 기존 StateError 유지. 동작 외 변경 금지.
3. **테스트**: 동시 2회 save 호출 시 둘 다 성공하는 단위 테스트 1건 + 불일치 재시도 검증 1건 추가. 기존 guide 관련 스위트 통과 유지. 전체 스위트는 기준선 부분집합만 확인(기존 실패 목록 대조 — 신규 실패 없으면 통과).
4. **커밋→main 머지→push**: 브랜치 커밋·push → main 머지(v8b 절차: 임시 머지 워크트리→merge --no-ff→analyze 오류 0→push origin HEAD:main→워크트리 정리). 머지 전 승인 불요 — CEO가 본앱 수정 승인한 상태.
5. **QA 검증용 재빌드**: 머지된 origin/main에서 guideqa 서픽스 debug 빌드(v9-r2 절차 동일, versionCode는 현재 값 유지) → install -r → dumpsys 확인. 서명 자산은 본앱 워크트리 것 사용.
6. **4/7 재개**: 앱 기동 → 가이드 상태 확인(blocked guide_operation_failed면 "안내 계속"으로 resume — resume 후 active 확인) → 3/7 → 준비·출발 안내 확인 탭 → 4/7 → CEO 발화 조회(생성 일정 날짜 맞춰 "오늘/내일 일정 보여 줘") → **5/7(첫 번째=생성 일정)** → CEO 발화 "첫 번째 일정 오후 5시로 변경해 줘" → 6/7 → 실제 저장 탭 → 7/7 → 확인 탭 → 동기화 선택 → 마무리 코치마크. 각 단계 스크린샷+dump.
7. 성공 기준: 7/7 도달 + 마무리 코치마크 + 일정 실제 변경 증거. AI 호출은 앱 자연 동작.
8. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고. 배포는 별도 지시 대기.

## 불변
본앱 수정은 guide_providers.dart 1파일(+테스트) 한정. 프로덕션 앱 보호. 새 일정 생성 금지(기존 일정 사용). 건너뛰기 절대 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호 출력 금지. 완료 판정은 화면 증거로. `.tmp/guide-step3-cta-fix-20261113`·`feat/voice-user-token-20261107` 메인 워크트리 건드림 금지. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / lib 수정 diff 요약 / 테스트 증거(신규 2건 포함) / 머지 커밋·push 확인 / 도달 단계 / screen_evidence 경로 / 진단 요약 / 잔여 경로.
