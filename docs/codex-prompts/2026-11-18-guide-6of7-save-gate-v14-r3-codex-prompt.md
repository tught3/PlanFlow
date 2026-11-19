# v14-r3 델타 지시 — 결정적 수정: coordinator를 context 독립으로 해석 (2026-11-18, Claude 작성)

**CEO 지시: 이번 라운드는 반드시 끝낸다. 계측 재확인과 결정적 수정을 한 빌드에 함께 넣는다.**

## Claude 진단 (QA 워크트리 소스 직접 확인 — 결정적)
- `EventEditScreen extends StatefulWidget`(L105)이고 저장 진입 가드는 `GuideScope.maybeOf(context)`로 coordinator를 찾는다(L1251 부근).
- **가정한 원인(유력, 확정 계측으로 검증)**: 6/7 편집 화면이 가이드 스코프 서브트리 **바깥 네비게이터**로 push되면 `GuideScope.maybeOf(context) == null` → `_guideEditPreviewState()`가 null → 토스트. coordinator 자체는 정상(active/editPreview) — 탭 직후 readback이 active/editPreview였던 것과 정확히 일치.
- 첫 런과 재시작 런의 차이는 이 네스팅 경로 차이로 설명된다(재시작 런 진입 경로가 스코프 밖이었을 가능성).
- **결정적 수정**: coordinator 해석을 context 의존에서 **`realUiGuideCoordinatorProvider`(guide_providers.dart L30, 존재 실측) 경유로 교체** — 스코프 네스팅과 무관하게 항상同一 coordinator를 읽는다. 가드 조건(uid·sessionId·run·step 검사)은 전부 유지.

## v14-r3 실행 절차
1. **수정**: EventEditScreen을 ConsumerStatefulWidget으로 전환(또는 저장 시점에 WidgetRef/container로 provider read) → 저장 진입 가드와 dispatch 경로 모두 `GuideScope.maybeOf(context)` 대신 `ref.read(realUiGuideCoordinatorProvider).state.value` 사용. `_guideEditPreviewState()` 로직(uid·sessionId·run·step 검사)은 동일하게 유지하되 coordinator 취득원만 교체. 기존 GuideScope 위젯 연동(2/7 등 다른 화면)은 건드리지 않는다.
2. **계측 유지**: v14의 두 분기 로그(entry/postDispatch) 유지 — 이번 빌드에서 어느 경로로 통과/차단됐는지 기록.
3. **테스트**: ① 스코프 밖에서 저장 진입 시 가이드 저장 성공하는 위젯 테스트 1건(GuideScope 없이 provider로 coordinator 주입) ② 기존 guide 스위트 통과 유지.
4. **빌드·설치·재현**: guideqa 서픽스 debug 빌드 → install -r → **재시작 런 시퀀스로 재현**(튜토리얼 재시작 → 6/7 진입 → 저장 탭) → 토스트 부재 + 저장 성공 확인(스크린샷+dump). 계측 로그로 entry/postDispatch 통과 경로 기록.
5. **5→7 완주**: 4/7 → 5/7(타이핑 "첫 번째 일정을 오후 5시로 변경해줘") → 6/7 저장 성공 → 7/7(실제 변경) → 동기화 선택 → 마무리. 각 단계 스크린샷+dump.
6. **커밋·push**: 브랜치 fix/guide-progress-save-race-20261114에 커밋(v7u의 deadlineExpired 수정분 위에) → push.
7. 성공 시: CEO 최종 실기기 확인 요청 단계로. 실패 시(스코프 교체 후에도 토스트) → 계측 로그 전문 수집 후 중단 보고(Claude 판정).
8. 보고: 결과 한 줄 / 수정 diff 요약 / 계측 로그 요약 / 테스트 증거 / 기기 증거 경로 / 잔여 경로.

## 불변
v14·v14-r2 불변 전부 유효(가드 약화 금지 — coordinator 취득원 교체는 약화가 아니라 정합 수정, 수정 1가지+테스트 한정, 프로덕션 보호, 건너뛰기 금지, 화면 증거 판정, 호스트 파일 막히면 경로 보고).
