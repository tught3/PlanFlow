# Guide QA bound detail — v7j 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7i 델타. 충돌 시 이 문서가 이긴다.

## v7i 리뷰 판정 (Claude, 코드 근거)
- "안내가 잠시 멈췄어요"(guide_host.dart:236, 비치명)는 GuideSnapshot이 `run != active` 또는 `errorCode != null`일 때 표시된다(build 내 recovery 분기). 즉 라운드·홈 진입은 성공했고 **가이드 상태머신이 첫 코치마크(홈 음성버튼 1/2) 전에 정지/에러 스냅샷으로 전환된 것**이 원인.
- 유력 가설: 서버 세션은 리셋됐지만 앱 로컬 진행상황(11-05 라운드의 step=savedDetail, revision=12 — readback 파일로 확인)이 남아 있어, 새 세션(create)과 로컬 상태의 불일치가 가드·복구 로직을 탔다(H3/H5 계열).
- **판정에 필요한 것은 이번(v7i) 라운드의 앱 내부 진단 파일** — 서버 호출 없이 수집 가능.

## v7j 실행 절차 (서버 호출 0)
1. 큐 lease(SM-S918N 1대 매칭, 회전값 기록).
2. **앱을 실행하지 말 것** — v7i 라운드가 남긴 앱 내부 파일을 run-as로 수집: `com.fluxstudio.planflow.guideqa`의 files/ 아래 guide 관련 파일(real_ui_guide 저널·readback·progress store/shared_prefs의 guide 진행 상태) 전부Pull → qa-live에 저장.
   - 특히: v7i 라운드 시각(2026-11-07T19:50 KST) 이후 수정된 guide 파일이 대상. 목록만 먼저 덤프해 보고해도 좋음.
3. 수집 파일의 구조적 요약(값 중 토큰·키는 제외, step/errorCode/revision/timestamps는 그대로)을 보고. Claude가 그 결과로 H3~H6 판정 후 코드 수정 지시서를 만든다.
4. lease 반납, 회전값 0→0, 티켓 파일은 삭제 시도 없이 경로 보고(Claude 정리).

## 불변
서버 호출 0(세션 만료여도 무관 — 진단 수집만). 앱 UI 조작·탭 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰 값 출력 금지. 호스트 파일 작업 막히면 경로만 보고(Claude가 정리·수행).
