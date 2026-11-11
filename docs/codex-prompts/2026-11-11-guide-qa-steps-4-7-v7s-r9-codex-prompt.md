# v7s-r9 델타 지시 (2026-11-11, Claude 작성)

**정본**: v7s-r8 델타. **BLOCKED 원인 확정 — 화면 전체가 타 앱(com.aiexpense.tracker)이었다.**

## Claude 진단 (dump package 실측)
- screen-01.xml의 17개 노드가 전부 `package="com.aiexpense.tracker"` — PlanFlow QA 앱이 아닌 **타 앱이 포그라운드**였던 것(정기결제 알림 화면). 오버레이가 아니라 앱 자체가 앞에 떠 있었음.
- 반면 QA 앱 저널(step=intro, paused, backend_unavailable, FAIL_CLOSED_NO_RETRY)은 QA 앱이 잠깐 기동됐다가 begin 1회 실패 후 타 앱이 앞을 가린 패턴. 초기화 자체는 성공(가이드 키 제거·intro 리셋·원장 2 유지 확인) — r8의 초기화 성과는 유효.
- backend_unavailable 상태는 **"안내 계속" 탭으로 ResumeRequested → begin 재시도**가 설계된 복구 경로다(guide_coordinator resume 분기).

## v7s-r9 실행 절차 (v7s-r8 + 포그라운드 검증 추가)
1. 큐 lease → **refresh 1회 재갱신 필요**(r8에서 소비됨) → 영수증 7키 → 러너 실행 준비.
2. **포그라운드 보장(신규 필수 단계)**: 러너 시작 전/직후 `adb shell dumpsys window`에서 mCurrentFocus가 `com.fluxstudio.planflow.guideqa`인지 확인. 타 앱이면: back 1~2회(타 앱 팝업 닫기 — 타 앱 버튼 탭 금지) 후 `adb shell cmd package resolve-activity --brief com.fluxstudio.planflow.guideqa` → `am start -n <런처 액티비티>`로 QA 앱 기동(monkey 금지 규칙 준수). 재확인까지 반복(최대 3회).
3. QA 앱 포그라운드 확인 후: "안내 계속" 1회 탭(backend_unavailable 복구 — begin 재시도) → **1/7 홈 마이크 코치마크 확인** → 이하 v7s-r8 라운드 절차 그대로:
   - 마이크 탭 → CEO 발화 "내일 오후 3시 서울역에서 회의" → 전사 hold 확인 → permit → 제출(AI 1회) → 2/7(중요→강한 알람→저장, 각 스크린샷) → 3/7 → 준비·출발 안내 확인 탭 → 4/7 → "내일 일정 보여줘" → permit → 제출(AI 2회) → 5/7 → "첫 번째 일정 오후 5시로 변경해줘" → permit → 제출(AI 3회) → 6/7 → 실제 저장 탭 → 7/7 → 확인 탭 → 동기화 선택 "동기화 안 함" → 마무리.
   - 모달 루틴 유지("외부 캘린더 동기화 안내"→동기화 안 함). **기타 타 앱 팝업은 버튼 탭 없이 back으로만 처리.**
4. 안내 계속 후에도 begin 재실패(backend_unavailable 유지)면 → dump+run-as 전문(journal·ledger) 수집 후 중단 보고 — 이때는 네트워크/토큰 문제로 Claude 판정.
5. 각 단계 스크린샷+dump. 종료 후 files/ 진단 전문(발췌 금지) + aiRequests 증가분(기대 3, 하드캡 5) + 새 일정 저장 확인값.
6. lease 반납, 회전값 0→0(시작 0이었으므로 연결 복구 후 확인), 상태 JSON. 잔여 파일 경로만 보고(r8 원본 설정 사본 등 기존분 유지).

## 불변
v7s-r8 불변 전부 유효(shared_prefs 가이드 키는 이미 제거됨 — 재수정 불요, 원본 사본 보존). refresh 1회(이번 몫). generate_link·verify·직접 begin/events 금지. 새 일정 1건(CEO 승인분). AI 하드캡 5회. permit 1회씩. 타 앱 버튼 탭 금지·OS 설정 변경·monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 완료 판정은 폰 화면 증거로만. CEO 발화 3회 대기 정상. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 포그라운드 검증 결과 / 도달 단계 / 새 일정 저장 확인값 / 전사·permit·AI 소비 / screen_evidence 경로 / 진단 요약(aiRequests) / 잔여 경로.
