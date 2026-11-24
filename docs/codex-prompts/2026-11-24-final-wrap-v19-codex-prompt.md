# v19 지시 — 최종 마무리: main 통합 확인 → release 빌드 → CEO 폰 설치 (2026-11-24, Claude 작성)

**CEO 결정: 에뮬레이터 검증 중단. main에 전부 통합돼 있으므로 release 빌드 만들어 폰에 설치하고 CEO가 직접 최종 테스트.**

## 절차
1. **main 상태 확인**: origin/main HEAD가 v17 UX 수정(ea8a1ab8) 이후 최신인지 확인. QA 브랜치 미통합 커밋 있으면 머지, 없으면 통과.
2. **release APK 빌드**: main HEAD에서 `flutter build apk --release` (서명: android/key.properties + planflow-release.jks — main 워크트리에 있음 실측 완료). versionCode는 203 유지(스토어 배포 시 별도 bump).
3. **S23 설치**(공용 큐 경유, SM-S918N 연결 시): `adb uninstall com.fluxstudio.planflow.guideqa`(QA 앱 제거) → `adb install -r` release APK(본앱 데이터 보존 — uninstall 금지) → dumpsys 확인 → 앱 기동.
   - 기기 연결 안 되면 APK 경로만 보고하고 대기(CEO가 직접 폰 연결 후 재시도).
4. **CEO 최종 테스트 안내**: 아래 체크리스트를 CEO에게 전달 — ① 튜토리얼 1~7 전체(음성 발화 포함) ② 3/7이 홈 탭에서 진행 ③ 완료 모달 → 동기화 순서 ④ 뒤로가기 나가기 ⑤ 광고 미표시 ⑥ 저장 일정 1박2일 아님(단일 일정) ⑦ "아래로 스크롤 해 주세요"만 굵게 ⑧ 중간 화면 플래시 없음.
5. 보고: 결과 한 줄 / main HEAD / release APK 경로·SHA256 / 설치 결과 / 잔여 경로. CEO 테스트 결과를 기다리는 상태로 마무리.

## 불변
main lib 코드 수정 금지(이번은 빌드·설치만). 프로덕션 앱 uninstall 금지(install -r만 — CEO 데이터 보존). 외부 백업 E:\FluxStudio\_planflow_backup_20261120 삭제 금지. 보호 파일 7종 삭제 금지. 사전 존재 dirty 4건 건드림 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. OS 설정 변경 금지. 토큰·비밀번호 출력 금지. 호스트 파일 막히면 경로 보고(Claude 정리).
