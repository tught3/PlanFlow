# v9-r2 델타 지시 — 서픽스 빌드로 본앱 검증 설치 + 매직링크 토큰 처리 규칙 (2026-11-14, Claude 작성)

**정본**: v9 지시서. **v9 BLOCKED 2건 판정: ① 프로덕션 앱 보호 중단 = 정상(올바른 판단). ② 토큰 로그 우려 = 타당하나 QA 계정(폐기 가능 계정)에서는 관리 규칙으로 해소 가능. 둘 다 설계로 해소한다.**

## 해소 설계 (Claude 확정)
1. **프로덕션 앱 보호**: 본앱 빌드에 **guideqa opt-in 서픽스**를 적용한다 — main에 통합된 `applyIsolatedGuideQaDebug` 옵션(build.gradle.kts 실측: debug 빌드에 applicationIdSuffix ".guideqa" 부여, 기존 QA 앱과 동일 패키지). 방금 guideqa를 uninstall해 슬롯이 비었으므로 **프로덕션 앱과 완전 별도 설치**된다. 버전 203 > 기존 198이라 설치도 문제없다.
2. **매직링크 토큰**: QA 계정은 폐기 가능한 검증 전용 계정이다. 규칙: 토큰 값은 **기기로 deeplink를 여는 용도로만** 사용, 공용 보고·문서·공유 출력에 절대 기록 금지, adb 명령 이력에 남는 것은 QA 기기·QA 계정 한정 위험으로 수용(CEO 승인 범위). verify 후 앱 세션 확보 확인(sub==QA UID)까지만 기록.

## v9-r2 실행 절차
1. 큐 lease(SM-S918N, 회전값 기록).
2. **본앱 debug 빌드(서픽스 적용)**: main 워크트리에서 guideqa opt-in 플래그 활성화 빌드(기존 v7s-r3 빌드와 동일 옵션 — Codex가 이미 수행 경험 있음) → **결과 applicationId가 com.fluxstudio.planflow.guideqa인지 aapt/dumpsys badging으로 검증** → SHA256 기록 → install -r(스틸 슬롯) → dumpsys versionCode 확인.
   - 프로덕션 앱(com.fluxstudio.planflow)은 건드리지 않는다 — 설치 후에도 존재 유지 확인.
3. **로그인(QA 계정, 매직링크)**: 기존 v6/v7e 런북으로 admin generate_link 1회 → 토큰화 링크를 기기 deeplink(am start VIEW)로 열어 앱에서 verify → 로그인 성공(sub==QA UID) 확인. 토큰 값 공용 출력 금지(기기 deeplink 용도만). 실패 시 재시도 1회 한도.
4. **튜토리얼 실행(실사용 UX 그대로)**: 앱 재시작 → 인트로 → **1/7 홈 마이크 코치마크**(스크린샷+dump) → 마이크 탭 → CEO 발화 "내일 오후 3시 서울역에서 회의"(화면이 연습 문구를 요구하면 그것 우선) → 확인 화면 → **2/7 저장**(중요→강한 알람→저장, 각 스크린샷) → 저장 → **3/7 savedDetail** → 준비·출발 안내 확인 탭 → **4/7** → CEO 발화 조회(생성 일정 날짜 맞춰 "내일/오늘 일정 보여줘") → **5/7**(첫 번째=새 일정) → CEO 발화 "첫 번째 일정 오후 5시로 변경해줘" → **6/7**(오후 5시 강조) → 실제 저장 탭 → **7/7**(실제 변경) → 확인 탭 → 동기화 선택 → 마무리 코치마크.
   - 각 단계 스크린샷+dump(번호 계속). AI 호출은 앱 자연 동작(≈3~4회 — 기존 승인 범위). 중단 화면 시 dump+logcat 수집 후 보고(탭 금지).
5. 성공 기준: **7/7 도달 + 마무리 코치마크 + 새 일정 실제 저장·변경 화면 증거**.
6. lease 반납, 회전값 0→0, 상태 JSON(guideqa-v9-r2-main-app-20261114.json). 잔여 파일 경로만 보고. 배포는 별도 지시 대기.

## 불변
본앱 lib 코드 수정 금지(검증만). 프로덕션 앱(com.fluxstudio.planflow) 설치·데이터 보호 — 절대 덮어쓰지 않는다. 새 일정 1건(CEO 승인). 건너뛰기 버튼 탭 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·키·링크 값의 공용 출력 금지(기기 deeplink 용도만 허용). 완료 판정은 폰 화면 증거로만. CEO 발화 3~4회 대기 정상. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / applicationId 검증 결과 / 도달 단계 / 새 일정 저장·변경 확인값 / 각 단계 screen_evidence 경로 / AI 호출 수 / 진단 요약 / 잔여 경로.
