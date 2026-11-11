# v7s-r11 델타 지시 — 서버 행 삭제 완료(스프레드 수정) 후 라운드 재실행 (2026-11-11, Claude 작성)

**정본**: v7s-r10 델타 + r9·r9b. **승인 D(서버 행 삭제)는 Claude가 직접 수행 완료. 승인 E(refresh 1회)는 Codex 실행분.**

## Claude 수행 완료 (r10의 미해결 2건 중 1건)
- **서버 행 삭제 완료(원인 극복)**: `real_ui_guide_sessions`에서 user_id='2cc42b8e…' AND version='real_ui_v1' 행(62ffc392…, phase=terminal, terminal_reason=skip, 생성 2026-11-07)을 삭제 → **count 0 확인**. 이전 r7 시점 삭제가 `id` 컬럼 조건이라 실제로는 0건 삭제였다는 타 세션 진단이 정확했다 — 이번엔 user_id 조건으로 실제 삭제. **다음 begin은 새 세션(create)을 만든다.**
- 남은 r10 미해결: **기기 offline** — Codex가 재연결해야 한다.

## v7s-r11 실행 절차
1. **기기 재연결**: `adb devices`에서 SM-S918N이 offline/device 확인. offline이면 무선 디버깅 재활성(폰: 설정→개발자 옵션→무선 디버깅 끄고 다시 켜기) → `adb connect <새 IP:포트>`(포트는 재활성마다 바뀜 — 화면에 표시된 값 사용) → `adb devices`에서 device 확인. 연결이 계속 안 되면 BLOCKED 보고(폰 쪽 조치 필요).
2. 큐 lease(SM-S918N, v198 매칭) → **refresh 1회(승인 E, 미소비분)**: 키는 반드시 qa-build\phone-isolated-defines-v2.json에서 직접 읽기(r9b 방식) → 응답 검증(sub==QA UID, 잔여 ≥3500초) → 세션 파일 원자적 교체. 실패 시 재시도 금지 BLOCKED.
3. 영수증 7키 → 5분 내 러너 실행, logcat post-run 덤프.
4. **러너 직후 탭 전 journal 확인(필수)**: begin 결과 확인(rpcObserveFailed 유무, sessionPresent). 실패 시 replyReasonCode만 보고하고 중단 — 화면 backend_unavailable로 판정 금지(r10 교훈).
5. **포그라운드 보장**: mCurrentFocus/mFocusedWindow가 com.fluxstudio.planflow.guideqa인지 확인. 타 앱이면 back 후 am start(r9 방식).
6. **"안내 계속" 1회 탭**(backend_unavailable 복구 → begin 재시도 → 새 세션 create) → **1/7 홈 마이크 코치마크 확인** → 이하 v7s-r7/r8의 1~7 흐름 그대로:
   - 마이크 탭 → CEO 발화 "내일 오후 3시 서울역에서 회의" → 전사 hold 확인 → permit → 제출(AI 3회째) → 확인 화면(내일/오후 3시/서울역/회의) → 2/7(중요→강한 알람→저장, 각 스크린샷) → 3/7 savedDetail → 준비·출발 안내 확인 탭 → 4/7 → CEO 발화 "내일 일정 보여줘" → 전사 hold → permit → 제출(AI 4회) → 5/7(첫 번째=새 일정) → CEO 발화 "첫 번째 일정 오후 5시로 변경해줘" → 전사 hold → permit → 제출(AI 5회째 = 하드캡 최종) → 6/7(오후 5시 강조) → 실제 저장 탭 → 7/7(3시→5시 실제 변경) → 확인 탭 → 동기화 선택 "동기화 안 함" → 마무리 코치마크.
   - 모달 루틴("외부 캘린더 동기화 안내"→동기화 안 함) 유지. **"안내 건너뛰기" 등 모든 건너뛰기 버튼은 어떤 경우에도 탭 금지(r5~r6 원인).**
7. 각 단계 스크린샷+dump(번호 계속). 종료 후 files/ 진단 전문(발췌 금지) + aiRequests 증가분 기록(기대 +3 → 총 5 = 하드캡 도달; 6번째는 fence 차단). 새 일정 저장 확인값(제목·날짜·시간) 기록.
8. lease 반납, 회전값 0→0(연결 복구 후 측정), 상태 JSON. 잔여 파일 경로만 보고.

## 불변
refresh 1회(승인 E). begin은 앱 자동. generate_link·verify·직접 begin/events 금지. 새 일정 1건(CEO 승인분). AI 하드캡 5회(이번 라운드로 도달 예정 — 재시도 낭비 금지, 전사 불일치 시 permit 소비 없이 중단). 건너뛰기 버튼 절대 탭 금지. OS 설정 변경·monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 완료 판정은 폰 화면 증거로만. CEO 발화 3회 대기 정상. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 기기 연결 상태 / 도달 단계 / 새 일정 저장 확인값 / 전사·permit·AI 소비(aiRequests 최종값) / screen_evidence 경로 / 진단 요약 / 잔여 경로.
