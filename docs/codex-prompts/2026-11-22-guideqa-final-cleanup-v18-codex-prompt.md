# v18 지시 — 튜토리얼 검증 확정·QA 자산 정리·main 최종 통합 (2026-11-22, Claude 작성)

**CEO 결정(2026-11-22): 튜토리얼 검증 확정 → QA 앱·하니스·산출물 정리 → main 최종 통합 → 배포 단계 진입.**

## 배경
- v17로 튜토리얼 UX 후속 3건 수정 완료 — CEO가 전체 흐름 정상 확인.
- main에는 가이드 기능이 통합돼 있고(1c225edd 계열 + 이후 머지), QA 앱(com.fluxstudio.planflow.guideqa)은 폐기 결정돼 있음(2026-11-13).
- QA 트리(.tmp/voice-first-tour-20261017 → guide-progress-save-race-20261114 워크트리)는 main에 기능이 통합됐으므로 더 이상 필요 없음. 단, main에 아직 미통합 수정이 남아 있다면 그것부터 main으로 넣어야 함.

## v18 실행 절차
1. **main 미통합 수정 확인**: QA 워크트리(guide-progress-save-race-20261114, 브랜치 fix/guide-progress-save-race-20261114)의 커밋 중 origin/main에 없는 것이 있는지 확인(`git log origin/main..fix/guide-progress-save-race-20261114 --oneline`). 있으면 v9-r8 이후 절차로 main 머지(임시 머지 워크트리→merge --no-ff→analyze 오류 0→push origin HEAD:main→정리). 없으면 생략.
2. **QA 워크트리 제거**: `git worktree remove --force E:\FluxStudio\PlanFlow\.tmp\guide-progress-save-race-20261114` → prune. 브랜치 자체는 origin에 남아 있으므로 삭제 불요(보존). `.tmp/guide-step3-cta-fix-20261113`도 guide 계열 잔여면 소유 확인 후 제거(타 세션 소유면 보고만).
3. **QA 앱 제거(기기)**: 공용 큐 경유 → `adb uninstall com.fluxstudio.planflow.guideqa` → uninstall Success 확인. (Secure Folder 등 다른 프로필 잔존은 보고만.)
4. **산출물 정리(보존 후 삭제)**: QA 증거·상태 파일은 **삭제 전** `E:\FluxStudio\PlanFlow\.codex\tasks\guideqa-final-archive-20261122\`로 이동·보존: v13~v17 기기 증거(스크린샷+dump), 작업 상태 JSON들, 최종 APK 1개(최신 guideqa 빌드 — 참고용 1개만, 나머지 APK 삭제), 자격 증명 파일(guideqa-v9-r5-qa-login.private.json)은 **보존**(계정 삭제 시까지). 이후 임시 폴더(구 세션 tmp 잔여·work-state 하위 스크립트 등) 삭제.
5. **본앱 재검증 빌드**: main HEAD 기준 본앱 debug APK 재빌드 → SHA256 기록 → S23에 설치(기존 스토어/이전 설치본과 동일 패키지 — 데이터 보존 주의: uninstall 금지, install -r만) → 기동 확인.
6. **CEO 최종 실기기 확인 요청**: 아래 체크리스트 전달 — ① 튜토리얼 전체 1~7 흐름(음성 발화 포함) ② 3/7이 홈 탭에서 진행되는지 ③ 완료 모달 → 동기화 순서 ④ 뒤로가기 나가기 동작 ⑤ 광고 미표시 ⑥ 저장 일정 1박2일 아닌지.
7. 보고: 결과 한 줄 / main 미통합 머지 여부·커밋 / QA 워크트리·기기 앱 제거 확인 / 아카이브 경로·보존 파일 수 / 본앱 재검증 빌드 SHA256 / 잔여 경로. **이후 배포는 별도 지시(스토어 제출 절차)로 진행한다 — 이번 범위 아님.**

## 불변
main lib 코드 수정 금지(이번은 통합·정리만 — 버그 발견 시 별도 지시). 외부 백업 `E:\FluxStudio\_planflow_backup_20261120` 절대 삭제 금지. 보호 파일(env/local.json, android/key.properties, planflow-release.jks, google-services.json, guided_coachmark_overlay.dart, app_feedback_service.dart, guide_contract.dart) 절대 삭제 금지. 사전 존재 dirty 4건(AGENTS.md·CLAUDE.md·GeneratedPluginRegistrant.java·작업 JSON) 건드림 금지. 프로덕션 앱 uninstall 금지(install -r만). monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰·비밀번호·자격 증명 출력 금지. 완료 판정은 화면·명령 증거로. 타 세션 워크트리 소유 확인 전 제거 금지. 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 각 단계 증거 / 아카이브·보존 목록 / 잔여 경로.
