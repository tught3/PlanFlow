# v7s-r4 델타 지시 — 4~7단계 라운드 실행 (2026-11-11, Claude 작성)

**정본**: v7s-r3 델타. **새 메커니즘(보류·permit·하드캡)이 설치된 APK v198(18064738…)로 라운드를 실행한다. CEO 실제 발화 2회가 필요하다.**

## 절차
1. 큐 lease(SM-S918N, versionCode 198 매칭 — 설치 APK는 v7s-r3 것, SHA256 18064738…) → refresh 1회(보존분, 원자적 교체) → 영수증 7키 → 5분 내 러너 실행, logcat -c 후 post-run 버퍼 덤프.
2. 라운드(탭 총 15회 이내, min(30분, 세션 잔여기간)):
   - 안내 계속 1회 → 저장 행 탭 1회 → 상세 진입 **3/7 확인** → 준비·출발 안내 확인 버튼 1회 탭 → **4/7(쿼리 마이크 하이라이트) 확인**.
   - 4/7: 쿼리 마이크 탭 → **CEO 발화 "11월 5일 일정 보여줘"** → STT 완료 후 전사가 화면에 남아 있고 **자동 제출되지 않음(hold 동작)을 dump로 확인** → 전사 텍스트가 발화와 일치하는지 확인 → **permit 파일 작성(native-guide-ai-submit-permit, 내용 CONTINUE)** → 제출 1회 진행(AI 파싱 1회) → 결과(5/7 조회 결과, 첫 번째=타깃 일정) 확인.
   - 5/7: CEO 발화 "첫 번째 일정 오후 3시로 변경해줘" → 전사 hold 확인 → permit 작성 → 제출(AI 파싱 2회) → **6/7(수정 확인, 시간 오후 3시 강조) 확인** → 실제 저장 버튼 1회 탭 → **7/7(변경 완료, 시간이 실제로 바뀜) 확인** → 확인 탭 → 동기화 선택 화면 → 선택 → 마무리 코치마크 확인.
   - permit은 전사 확인이 끝난 직후에만 쓸 것(다음 제출 1회만 통과). 부분 전사 자동 분석은 hold로 시작되지 않아야 함 — 시작되면 dump+run-as 전문 수집 후 중단 보고.
   - 중단 화면(멈춤·대기·ai_cap_exceeded) 시 dump+run-as 전문(journal 포함) 수집 후 보고(탭 금지).
3. 각 단계 스크린샷+uiautomator dump(07~13번 계속 번호), screen_evidence 절대경로 기록.
4. 종료 후 files/ 진단 전문 수집(journal·anchor diagnostics·readback — 발췌 금지), **aiRequests 증가분 기록**(기대 ≤4, 하드캡 5).
5. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고.

## 불변
refresh 1회(보존분) — 추가 refresh·generate_link·verify·직접 begin/events 금지. 새 일정 생성 금지(변경은 6→7 검증에 필요하므로 승인 범위). AI 파싱 하드캡 5회(fence 강제). permit 파일은 전사 확인 후 1회씩만. monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 완료 판정은 폰 화면 증거로만. CEO 발화 대기는 정상 대기. 호스트 파일 작업 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 도달 단계 / 전사·permit·AI 소비 기록 / 각 단계 screen_evidence 경로 / 진단 요약(aiRequests 증가분) / 잔여 경로.
