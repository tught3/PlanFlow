# v16 지시 — 튜토리얼 UX 최종 2건 수정 (2026-11-21, Claude 작성)

**CEO 실기기 테스트 결과: 전체 흐름 잘 작동함. 남은 UX 2건을 수정 후 다시 테스트.**

## CEO 보고 2건
1. **3/7 일정 확인이 일정 탭(캘린더)에서 이뤄짐**: 본앱에는 없던 동작(QA 앱 전용 경로). CEO 기대: **음성 입력 → 확인 → 저장 후 일정 확인은 홈 탭**에서 한다. → 3/7 안내·앵커를 홈 탭의 저장 일정(오늘 일정 목록 또는 홈의 해당 일정)으로 이동. 기존 캘린더 위 오버레이 앵커(calendar.saved)는 본앱 UX에 없던 것이므로 제거 대상. 본앱이 원래 가진 기능 위에서 검증해야 한다.
2. **동기화 선택이 튜토리얼 완료 모달보다 먼저 뜸**: 순서가 잘못됐다 — **7/7 확인 → 튜토리얼 완료 모달(확인) → 그 다음 동기화 선택** 순서로. 현재는 완료 모달 없이 바로 동기화가 뜨는 듯.

## 조사·수정 절차 (Codex 자체 완주, CEO 발화 단계는 최종 확인에서만)
1. **원인 조사**:
   - 이슈 1: guide route recovery/`GuideRouteRecovery.location`이 savedDetail에서 `/calendar?date=…`로 이동시키는 것 실측(guide_route_recovery.dart) + guide_host가 3/7 타깃을 `calendar.saved`로 잡는 로직(guide_host.dart `_targetId` savedDetail 분기). QA 앱 전용 경로인지 본앱 공통 코드인지 구분 후, 3/7을 **홈 탭의 저장 일정 항목**(`home.today`류 앵커가 이미 있으면 재사용, 없으면 홈 일정 카드에 GuidedAnchor 추가)로 이동. 캘린더 오버레이 앵커는 제거 또는 미사용.
   - 이슈 2: SyncChoicePresented/SyncChoiceClosed 시퀀스와 completed 전환 순서 확인(guide_coordinator.dart dispatch의 updatedDetail→syncChoice→completed 흐름). **completed(마무리/완료 모달)가 syncChoice보다 먼저 오도록 순서 교체** — 동기화 선택은 완료 모달 확인 이후에만 뜨게.
2. **수정**: 위 원인에 맞게 lib 수정(가이드 안전 가드·소유권·revision 검증 유지, LocalGuideBackend 포함). 이동 경로 변경은 route recovery와 targetId 양쪽을 함께 고쳐야 함.
3. **테스트**: ① savedDetail→홈 탭 이동·홈 앵커 검증 테스트 ② completed가 syncChoice 이전에 발생하는 순서 테스트 ③ 기존 guide 스위트 통과 유지. 전체 스위트는 기준선 부분집합 확인.
4. **커밋·push**: 브랜치 fix/tutorial-final-ux-20261121 생성 → 커밋 → push → **main 머지**(v9-r8 이후 본앱 통합 절차: 임시 머지 워크트리 → merge --no-ff → analyze 오류 0 → push origin HEAD:main → 워크트리 정리). 본앱에 반영돼야 최종 확인이 의미 있음.
5. **재빌드·설치**: 머지된 main 기준 guideqa 서픽스 debug 빌드(또는 CEO 요청 시 본앱 debug) → install -r → dumpsys 확인.
6. **자체 검증(Codex 완주)**: 튜토리얼 이어서 — 1/7 음성 완료 → 중간 화면 없이 2/7 → 저장 → **3/7이 홈 탭의 저장 일정을 가리키는지**(스크린샷+dump) → 4/7 조회 → 5/7 변경 → 6/7 저장 → 7/7 확인 → **완료 모달 먼저** → 확인 → 동기화 선택 → 마무리. 각 단계 스크린샷+dump.
7. 보고: 결과 한 줄 / 2건 원인·수정 diff / 테스트 증거 / 기기 증거 경로 / 잔여 경로. 성공 시 CEO 최종 실기기 확인(음성 발화 포함) 요청 단계로.

## 불변
본앱 수정은 위 2이슈 범위 한정. 가이드 안전 가드(소유권·revision·중복 방지) 약화 금지. 기존 음성 흐름·가이드 FSM 회귀 금지. 프로덕션 앱(com.fluxstudio.planflow) 설치·실행 금지. 건너뛰기 버튼 탭 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호 출력 금지. 완료 판정은 화면 증거로. 호스트 파일 막히면 경로 보고(Claude 정리).
