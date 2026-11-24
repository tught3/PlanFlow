# v19-r4 지시 — docs/codex-prompts 미추적 충돌 전부 해소 후 재개 (2026-11-25, Claude 작성)

**충돌 패턴 원인 확정: 내가 매 라운드 지시서를 origin/main에 push하면, Codex 워크트리에 동일 경로의 미추적 파일이 남아 ff-only merge가 거부된다. 이번엔 하나씩이 아니라 전부 한 번에 정리한다.**

## 절차
1. **미추적 충돌 전부 해소(한 번에)**:
   ```
   git fetch origin main
   git clean -f docs/codex-prompts/
   git merge --ff-only origin/main
   ```
   `git clean -f docs/codex-prompts/`는 해당 디렉터리의 미추적 파일만 제거한다(추적 중 파일은 무영향). 이 파일들은 전부 내가 origin/main에 push한 지시서들의 복제본이므로 삭제 안전. clean 전 `git clean -n docs/codex-prompts/`으로 목록 확인·기록.
2. **version bump**: pubspec.yaml `1.1.11+203` → `1.1.11+205` (1줄).
3. `flutter build apk --release` (서명: android/key.properties + planflow-release.jks) → SHA-256 → aapt2로 versionCode 205·com.fluxstudio.planflow 검증.
4. S23 연결 확인(공용 큐) → `adb install -r` → dumpsys로 205 확인 → 데이터 보존 확인.
5. 앱 기동 → CEO 최종 테스트 체크리스트 전달:
   ① 튜토리얼 1~7 전체(음성 포함) ② 3/7 홈 탭 진행 ③ 완료 모달 → 동기화 순서 ④ 뒤로가기 나가기 ⑤ 광고 미표시 ⑥ 1박2일 아님 ⑦ 스크롤 문구만 굵게 ⑧ 플래시 없음.
6. 커밋: pubspec bump(1파일) → origin/main push (-f 금지).
7. 보고: 결과 한 줄 / versionCode 205 빌드 SHA256 / 설치·기동 결과 / 커밋 해시·push 확인 / 잔여 경로. CEO 테스트 대기 상태로 마무리.

## 불변
본앱 코드 수정 금지(pubspec bump 1줄만). 프로덕션 앱 uninstall 금지(install -r만 — CEO 데이터 보존). 다운그레이드 금지. git clean은 docs/codex-prompts/ 경로 한정(다른 디렉터리 clean 금지). 외부 백업 E:\FluxStudio\_planflow_backup_20261120 삭제 금지. 보호 파일 7종 삭제 금지. 사전 존재 dirty 4건 건드림 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호 출력 금지. 호스트 파일 막히면 경로 보고(Claude 정리).
