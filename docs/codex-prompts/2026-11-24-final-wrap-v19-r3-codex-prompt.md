# v19-r3 지시 — 파일 충돌 해소 후 재개 (2026-11-24, Claude 작성)

**충돌 원인: origin/main에 push된 v19-r2 프롬프트 문서와 Codex 워크트리의 미추적 동명 파일이 충돌. 내용이 동일하므로 미추적 파일을 삭제하면 safe.**

## 절차
1. **충돌 해소**: 워크트리에서 `rm docs/codex-prompts/2026-11-24-final-wrap-v19-r2-codex-prompt.md` (미추적 파일 삭제 — origin/main에 동일 내용이 push돼 있으므로 안전) → `git merge --ff-only origin/main` → 최신 main 동기화 완료.
2. **version bump**: pubspec.yaml `version: 1.1.11+203` → `1.1.11+205` (1줄 수정). 기기에 204가 설치돼 있으므로 205여야 install -r 가능.
3. `flutter build apk --release` (서명: android/key.properties + planflow-release.jks — main 워크트리 실측 존재) → SHA-256 기록 → aapt2로 versionCode 205·com.fluxstudio.planflow 검증.
4. S23 연결 확인(공용 큐 경유) → `adb install -r` → dumpsys로 205 설치 확인 → 기존 데이터 보존 확인(CEO 일정 목록 스크린샷).
5. 앱 기동(resolve-activity → am start -W) → CEO 최종 테스트 체크리스트 전달:
   ① 튜토리얼 1~7 전체(음성 발화 포함) ② 3/7이 홈 탭에서 진행 ③ 완료 모달 → 동기화 순서 ④ 뒤로가기 나가기 ⑤ 광고 미표시 ⑥ 저장 일정 1박2일 아님(단일 일정) ⑦ "아래로 스크롤 해 주세요"만 굵게 ⑧ 중간 화면 플래시 없음.
6. 커밋: pubspec bump 포함(1파일) → origin/main push (-f 금지).
7. 보고: 결과 한 줄 / versionCode 205 빌드 SHA256 / 설치·기동 결과 / 커밋 해시·push 확인 / 잔여 경로. CEO 테스트 대기 상태로 마무리.

## 불변
본앱 코드 수정 금지(pubspec version bump 1줄만). 프로덕션 앱 uninstall 금지(install -r만 — CEO 데이터 보존). 다운그레이드 금지. 외부 백업 E:\FluxStudio\_planflow_backup_20261120 삭제 금지. 보호 파일 7종 삭제 금지. 사전 존재 dirty 4건 건드림 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호 출력 금지. 호스트 파일 막히면 경로 보고(Claude 정리).
