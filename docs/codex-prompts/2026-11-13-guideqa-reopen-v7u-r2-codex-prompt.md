# v7u-r2 델타 지시 — 서명 자산 복사 후 빌드·설치·기동 확인 (2026-11-14, Claude 작성)

**정본**: v7u 델타. **서명 키는 사라진 게 아니다 — 본앱 워크트리에 있다(Claude 실측). 복사하면 끝.**

## Claude 실측 (r17-r2 원인)
- `E:\FluxStudio\PlanFlow\android\key.properties` 존재(storeFile=planflow-release.jks)
- `E:\FluxStudio\PlanFlow\android\app\planflow-release.jks` 존재
- QA 워크트리는 재생성돼 gitignore된 이 2파일이 없을 뿐. 기존 설치 v198도 동일 release 키 서명 → install -r 호환.

## v7u-r2 실행 절차
1. QA 워크트리(E:\FluxStudio\PlanFlow\.tmp\voice-first-tour-20261017)에 서명 자산 복사:
   - `cp E:\FluxStudio\PlanFlow\android\key.properties E:\FluxStudio\PlanFlow\.tmp\voice-first-tour-20261017\android\key.properties`
   - `cp E:\FluxStudio\PlanFlow\android\app\planflow-release.jks E:\FluxStudio\PlanFlow\.tmp\voice-first-tour-20261017\android\app\planflow-release.jks`
   - 값 출력 금지(경로만 기록).
2. QA debug APK 빌드(r17에서 통과한 v7u 수정분 포함, versionCode 198, SHA256 기록).
3. install -r 설치 → dumpsys versionCode 확인.
4. 앱 기동(resolve-activity → am start) → **만료 화면 부재 + 인트로 또는 1/7 홈 마이크 코치마크 표시** → 스크린샷+dump.
5. 튜토리얼이 떴으면 CEO가 자연스럽게 진행(연습 발화 3회 → 2/7 저장 → 3/7 → 준비·출발 안내 확인 탭 → 4/7 조회 → 5/7 → 변경 시도는 6회째 ai_cap_exceeded 예상 → 5/7까지가 성공 기준; 진행되면 더).
   - 단계 간 공백 금지. 모달 루틴(외부 캘린더→동기화 안 함). 건너뛰기 절대 금지. 각 단계 스크린샷+dump.
6. 종료 후 files/ 진단 전문(발췌 금지) + aiRequests 최종값 + 새 일정 저장 확인값. lease 반납, 회전값 0→0, 상태 JSON. 잔여 경로만 보고.
7. 만료 화면이 재현되면 dump+빌드 로그 수집 후 중단 보고(Claude 판정).

## 불변
v7u 불변 전부 유효: 수정은 v7u 1파일(+테스트) 완료 상태 유지, 메인 앱 lib 터치 금지, AI 하드캡 5회(2 사용·3 잔여), 건너뛰기 절대 금지, monkey/kill-server/래퍼 우회/큐 state 편집 금지, OS 설정 변경 금지, 토큰·키 값 출력 금지(key.properties 값·keystore 절대 출력 금지), 완료 판정은 화면 증거로, .tmp/guide-step3-cta-fix-20261113 건드림 금지. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 서명 자산 복사 확인 / 빌드·설치 결과(SHA256) / 튜토리얼 표시 증거 경로 / 도달 단계·AI 소비(최종 aiRequests) / 잔여 경로.
