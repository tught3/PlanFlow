# v14-r2 델타 지시 — CEO 재현 정보 추가(첫 런 저장 성공, 재시작 런만 차단) (2026-11-14/18, Claude 작성)

**정본**: v14 지시서 그대로 실행. 아래 CEO 관찰이 진단을 더 좁혀준다.

## CEO 관찰 (신규, 진단에 반영)
- **첫 튜토리얼 런에서는 6/7 저장이 정상 동작**했다. **튜토리얼을 다시 시작한 두 번째 런에서만 같은 지점이 계속 막힌다.**
- 이는 v14 가설 2형(stale expectedRevision no-op)과 정합: 가이드 revision은 suspend/resume마다 계속 올라가는데, 두 번째 런은 앱이 배경/전환을 더 많이 겪어 편집 화면 캡처 revision과 dispatch 시점 revision 사이 간격이 벌어지기 쉽다. 첫 런은 간격이 1로 유지돼 통과.

## 진단·수정 보강 (v14 절차에 추가)
1. 계측 로그에 **캡처 시점 revision과 dispatch 시점 revision의 차이**를 반드시 기록(postDispatch 로그에 `snapshot.revision`, `confirmed.revision` 포함 — v14 지시대로).
2. 판정이 2형이면 수정은 v14 규칙( dispatch 직전 최신 revision으로 expectedRevision 갱신 후 재 dispatch 1회)에 더해: **EditConfirmed dispatch 전 상태를 coordinator.state.value에서 즉시 다시 읽어** snapshot을 재구성하는 방식으로 구현(화면이 열릴 때 캡처한 snapshot 재사용 금지).
3. 회귀 테스트에 **"앱 백그라운드 전환으로 revision이 +N 된 뒤 저장"** 시나리오(세션 유지, revision 차이 ≥2)를 추가 — 두 번째 런 차단 재발 방지.
4. 라운드 절차도 반영: 재현은 "첫 런 저장 성공 → 두 번째 런 6/7 차단" 시퀀스로 수행(단순 재접속이 아닌, 튜토리얼 재시작 시퀀스).

## 불변
v14 불변 전부 유효(가드 약화 금지 — 최신 상태 읽기는 정합 수정, 수정 1가지+테스트 한정, 프로덕션 보호, 건너뛰기 금지, 화면 증거 판정, 호스트 파일 막히면 경로 보고).
