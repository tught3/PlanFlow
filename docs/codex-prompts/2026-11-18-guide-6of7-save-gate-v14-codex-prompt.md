# v14 지시 — 6/7 저장 게이트 원인 계측(수집 우선) + 판정 기준 (2026-11-18, Claude 작성)

**정본**: v13 델타. **수정 전에 "두 분기 중 어느 것이 막았는지"를 계측으로 확정한다. 가드는 약화하지 않는다.**

## Claude 가설 (코드 구조 기반, 미확정)
- 분기 1(약 1197-1215, 저장 진입 시 GuideScope/snapshot 검사): 탭 순간의 snapshot이 active/editPreview가 아니면 발동. 단, 탭 직후 readback이 active/editPreview(renum 42)라면 **탭 시점과 읽기 시점의 상태가 달랐거나**, 분기 1이 검사하는 조건이 run/step 외 항목(revision·createdEventId·uid 등)일 가능성.
- 분기 2(약 1792-1808, EditConfirmed 후 owner/session/event/step/revision 검사): dispatch가 `before`를 그대로 반환(예: expectedRevision 불일치로 no-op)하면 step이 editPreview에 머물어 발동. **revision 42는 비정상적으로 높음 — lifecycle suspend/resume이 revision을 계속 올리고 있으며, 편집 화면이 열릴 때 캡처한 낡은 revision으로 dispatch하면 no-op이 된다(경합 가설 유력).**
- 어느 쪽이든 근본 수정 방향은 동일 계열: **행동 시점(탭·dispatch)에 coordinator의 최신 상태를 읽어 사용**하는 것(캡처된 낡은 snapshot 사용 금지). 가드 조건 자체는 유지.

## v14 실행 절차 (계측 빌드 → 재현 → 판정)
1. **계측 로그 추가(QA 빌드 한정)**: event_edit_screen.dart의 두 분기 각각 직전에 구조화 로그 1줄 추가 — `{branch: 'entry'|'postDispatch', run, step, revision, errorCode, createdEventId 존재 여부, event.id 존재 여부, guideSessionId 존재 여부}`(식별자 값은 존재 여부만, 값 자체 금지). dispatch 직후 반환 snapshot의 run/step/revision도 로그. 로그는 flutter debugPrint(기존 로거) 사용, 토큰·식별자 값 금지.
2. **빌드·설치**: guideqa 서픽스 debug 빌드(계측 포함) → install -r → dumpsys·SHA256 기록(설치본=빌드본 일치).
3. **재현**: 앱 기동 → 가이드 이어서 6/7 진입 → **저장 탭 직전·직후 저널/로그 캡처**(계측 로그 포함) → 토스트 발생 확인 → 스크린샷+dump. 가능하면 탭 전 5초간 대기 상태로 두고 lifecycle 이벤트(화면 전환 없이) 관찰.
4. **판정 규칙(로그 기반)**:
   - `branch=entry` 발동 + 로그상 run=paused 또는 step 불일치 → **낡은/멈춘 snapshot 사용 문제(가설 2형)**. 수정: 저장 진입 시 캡처값 대신 coordinator.state.value 최신값으로 가드 평가 + run=paused면 ResumeRequested 1회 후 재평가(사용자 안내 문구도 실제 상태 반영).
   - `branch=postDispatch` 발동 + dispatch 반환 snapshot이 `before`와 동일(revision 불일치 no-op) → **stale expectedRevision 문제(가설 1형, 유력)**. 수정: dispatch 직전 최신 revision으로 expectedRevision 갱신 후 재 dispatch 1회(1회만, 무한 재시도 금지).
   - 두 분기 모두 아님 + repository 쓰기 자체 실패 → 쓰기 실패 로그 수집 후 보고.
5. **수정 적용(판정 규칙에 해당하는 것만, 1가지)** → 단위 테스트 1건(해당 시나리오) + 기존 가이드 스위트 통과 → 커밋·push(브랜치).
6. **재빌드·설치 → 재검증**: 동일 절차로 6/7 저장 → **저장 성공 + 7/7 도달 + 일정 실제 변경** 확인(스크린샷+dump). 성공 시 CEO 최종 확인 요청 단계로.
7. 보고: 결과 한 줄 / 계측 로그 요약(발동 분기·상태값) / 판정(가설 1형·2형·기타) / 수정 diff 요약 / 재검증 증거 경로 / 잔여 경로.

## 불변
가드 조건(소유권·세션·revision·중복 방지) 약화 금지 — 다만 **행동 시점에 최신 상태를 읽도록 하는 것은 약화가 아니라 정합 수정**이다. 수정은 판정 규칙에 해당하는 1가지+테스트 한정. 프로덕션 앱 보호. 건너뛰기 탭 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호·식별자 값 출력 금지. 완료 판정은 화면 증거로. 호스트 파일 막히면 경로 보고(Claude 정리).
