# v7s-r8 델타 지시 — 로컬 가이드 진행 상태 정밀 초기화 + 전체 1~7 라운드 (2026-11-11, Claude 작성)

**정본**: v7s-r7 델타. **r7 BLOCKED 인정 — 로컬 terminal 진행이 begin 전에 반환되는 것 맞음(coordinator L44). 서버 행은 이미 삭제돼 있음(재확인 불요). 이번엔 로컬 키 1개만 정밀 제거하고 라운드까지 이어간다. CEO 승인은 v7s-r7 질문에 포함돼 소진됐다(전체 1~7 재검증).**

## 정밀 초기화 설계 (Claude 확정 — 앱 데이터 전체 삭제 금지, AI 원장 보존)
- 대상 키는 **정확히 1개**: SharedPreferences의 `guide_progress:real_ui_v1:2cc42b8e-fe6c-4812-894a-ab81605275d3`(guide_providers.dart L22 `key(uid, version)`). AI 원장은 files/의 별도 ledger 파일이라 shared_prefs와 무관 — 자동 보존.
- 절차:
  1. 앱 강제 종료: `adb -s <serial> shell am force-stop com.fluxstudio.planflow.guideqa`(monkey 아님, 안전).
  2. run-as로 shared_prefs XML pull: `adb shell run-as com.fluxstudio.planflow.guideqa cat shared_prefs/FlutterSharedPreferences.xml > 로컬사본`(qa-live에 저장).
  3. 로컬 사본에서 `guide_progress:` 로 시작하는 entry **1개만** 제거(다른 키 절대 건드리지 않음) → 수정본 검증(가이드 키 부재·타 키 동일·XML 파싱 가능).
  4. `adb push` → `adb shell run-as com.fluxstudio.planflow.guideqa cp` 방식으로 되쓰기 → 권한/소유자 확인.
  5. 검증: run-as cat으로 가이드 키 부재 + AI ledger 파일(files/) 존재·aiRequests=2 유지 확인.
- 위가 정책에 막히면 경로 보고(Claude가 대안 수행).

## 라운드 절차 (v7s-r7 그대로)
초기화 검증 통과 후 v7s-r7의 1~7단 전체 라운드 절차를 그대로 실행: refresh 1회 → 영수증 → 러너 → 1/7 마이크 → CEO 발화 "내일 오후 3시 서울역에서 회의" → permit → AI 1회 → 2/7(중요→알람→저장) → 3/7 → 준비·출발 안내 확인 → 4/7 → "내일 일정 보여줘" → permit → AI 2회 → 5/7 → "첫 번째 일정 오후 5시로 변경해줘" → permit → AI 3회 → 6/7 → 실제 저장 → 7/7 → 확인 → 동기화 선택 "동기화 안 함" → 마무리. 모달 루틴("동기화 안 함") 유지. 각 단계 스크린샷+dump. 종료 후 files/ 전문 + aiRequests 증가분 + 새 일정 저장 확인값.

## 불변
v7s-r7 불변 전부 유효. 추가: shared_prefs 수정은 가이드 키 1개만(전체 데이터 삭제 금지), 수정 전 원본 사본 보존. AI 하드캡 5회. OS 설정 변경·monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 폰 라운드 판정은 화면 증거로만. CEO 발화 3회 대기 정상. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 초기화 검증(가이드 키 부재·ledger 2 유지) / 도달 단계 / 새 일정 저장 확인값 / 전사·permit·AI 소비 / screen_evidence 경로 / 진단 요약 / 잔여 경로.
