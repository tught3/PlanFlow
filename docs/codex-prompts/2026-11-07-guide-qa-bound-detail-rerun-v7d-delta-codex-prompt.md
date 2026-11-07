# Guide QA bound detail — v7d 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7c 델타. 충돌 시 이 문서가 이긴다.

## v7c 리뷰 판정 (Claude)
BLOCKED 인정 + **v7c 순서 설계 오류 인정**: 승인 B(소유 조회·begin)는 QA 세션 토큰이 필요한데 만료 세션으로는 불가하므로, 세션 확보가 반드시 선행이어야 한다. v7c에서 B를 먼저 배치한 것은 Claude의 오류. v7d에서 순서를 정정한다.

## 승인 상태 (재확인)
- generate_link 재발급 최종 1회: **미소비·유효** (v7c에서 0회). 발급→verify 시작 **5분 이내** 강제는 유지.
- verify 1회, events 읽기 1회, begin 1회 상한. 승인 A 금지.

## v7d 실행 순서 (v7c에서 순서만 정정)
1. 공용 ADB 큐 새 FIFO 티켓 → lease 대기(최대 30분). SM-S918N + versionCode 198로 1대 매칭(0 또는 2대 이상이면 BLOCKED). lease 직후 serial 지정 회전값 기록.
2. **세션 먼저**: 키 조회(v6b 방식, 네트워크 오류 3회 백오프) → generate_link 1회 호출 → 원문 즉시 파일 write → 최상위 id == QA UID 2cc42b8e-fe6c-4812-894a-ab81605275d3 검증(불일치 즉시 BLOCKED) → **5분 내** /auth/v1/verify 1회 → 토큰 수신 즉시 파일 write → 검증 → 원자적 교체 → session_remaining_seconds > 0 기록. 값 출력 금지(길이·해시만). 평탄화 스키마(식별자 = 최상위 id).
3. 세션 확보 후 **승인 B**: 일정 3389cdce-c632-42e2-a510-87bccf57711c 소유 조회 1회 → begin_real_ui_guide 1회 → 영수증 발급(5분 유효).
4. 영수증 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지).
5. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump, saved.summary/saved.departure 앵커·코치마크 확인, screen_evidence에 경로 기록.
6. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리).

## 리스크 노트
2단계에서 세션 교체가 성공하면 서버 호출이 몰린다 — lease 획득 후 기기 문제가 확인되면 generate_link을 호출하기 전에 중단할 것(발급을 기기 문제로 날리지 않기 위함, v7c 조항 유지).
영수증 5분·OTP 5분 두 타이머가 겹치지 않게, 세션 교체 직후 B→라운드를 지연 없이 이어갈 것.

## 불변
generate_link 1회(이것이 진짜 마지막). verify 1회, events 읽기 1회, begin 1회. 승인 A 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 하고 보고. 완료 판정은 폰 화면 증거로만. 실측값(is_multi_day, start_at, saved_local_date, 실패 코드) 상태 JSON 기록.
