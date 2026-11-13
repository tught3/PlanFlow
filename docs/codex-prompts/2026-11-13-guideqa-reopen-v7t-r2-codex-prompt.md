# v7t-r2 델타 지시 — FlutterSecureStorage 키 1개 제거 (2026-11-13, Claude 작성)

**정본**: v7t 델타. **Codex 진단 인정 — 남은 것은 보안 저장소 키 1개다. 같은 pull/편집/push 방식으로 제거한다.**

## 절차
1. 큐 lease(SM-S918N, v198 매칭, 회전값 기록). 앱 force-stop.
2. run-as로 `shared_prefs/FlutterSecureStorage.xml` cat → 원본 사본 백업(E:\FluxStudio\PlanFlow\.codex\tasks\guideqa-harness-archive-20261113\) → **`planflow_guide_qa_manual_resume_v1` 키(및 하위 string entry) 1개만 제거** → 다른 키·XML 구조 불변 검증 → push 복귀(run-as cp) → 권한·소유자 확인.
   - 값이 암호화돼 있어도 **삭제만 하면 된다**(복호화 불요). Keystore는 건드리지 않는다.
3. 앱 재기동 → 화면 확인: "deadline passed" 부재 + 인트로 또는 1/7 홈 마이크 코치마크 표시 → 스크린샷+dump.
4. 성공 시: 튜토리얼이 떴으면 CEO가 자연스럽게 진행(발화·탭 — 이번 라운드부터 진행 가능, AI는 잔여 3회).
5. 그래도 만료 화면이면 → 증거 수집 후 중단 보고. 다음 수단은 **튜토리얼 통합 본앱 빌드 설치**(별도 지시)다.
6. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고.

## 불변
v7t 불변 전부 유효: 본앱 lib 터치 금지, AI 하드캡 5회(2 사용·3 잔여), monkey/kill-server/래퍼 우회/큐 state 편집 금지, 토큰 출력 금지, 앱 데이터 전체 삭제 금지(이 키 1개만), 완료 판정은 화면 증거로. 호스트 파일 작업 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 키 제거 검증 / 튜토리얼 표시 여부·증거 경로 / 잔여 경로.
