# Guide QA bound detail — v7e 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7d 델타. 충돌 시 이 문서가 이긴다.

## v7d 리뷰 판정 (Claude)
BLOCKED 인정 + **사전 점검(선검증)은 Claude가 대신 완료했다**:
- qa-live, qa-account-approved-20261030232231924 두 디렉터리 모두 쓰기/읽기/삭제 전부 성공(2026-11-07, 임시 파일 잔존 0).
- 따라서 v7d의 "응답 저장 및 세션 원자 교체 사전 점검"은 **재수행 금지 — 완료된 것으로 간주하고 바로 본 절차로 진행**.
- 응답 원문 1,635바이트 무결, 잔여 티켓 파일 0건(Claude 정리 완료).

## v7e 실행 절차 (v7d 순서 유지, 선검증만 제거)
1. 공용 ADB 큐 새 FIFO 티켓 → lease 대기(최대 30분). SM-S918N + versionCode 198로 1대 매칭(0 또는 2대 이상이면 BLOCKED).
2. lease 직후 serial 지정 회전값 기록 → **기기 온라인 재확인**(`adb -s <serial> get-state` == device). offline이면 여기서 중단(generate_link 발급 전이므로 손실 없음).
3. 세션 확보: 키 조회(v6b 방식, 백오프 3회) → generate_link 1회 → 원문 즉시 파일 write → 최상위 id == 2cc42b8e-fe6c-4812-894a-ab81605275d3 검증(불일치 즉시 BLOCKED) → 5분 내 /auth/v1/verify 1회 → 토큰 수신 즉시 write → 검증 → 원자적 교체 → session_remaining_seconds > 0 기록. 값 출력 금지(길이·해시만).
4. 승인 B: 일정 3389cdce-c632-42e2-a510-87bccf57711c 소유 조회 1회 → begin_real_ui_guide 1회 → 영수증 5분.
5. 영수증 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지).
6. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump, saved.summary/saved.departure 앵커·코치마크 확인, screen_evidence 기록.
7. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓·임시 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리).

## 불변
generate_link 1회(최종). verify 1회, events 1회, begin 1회. 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 하고 보고(우회 금지). 완료 판정은 폰 화면 증거로만. 실측값(is_multi_day, start_at, saved_local_date, 실패 코드) 상태 JSON 기록.
