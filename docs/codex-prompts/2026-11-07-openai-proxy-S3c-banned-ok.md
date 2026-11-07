# [지시서] S3c — banned-ok 인라인 주석으로 커밋 게이트 통과 (ZCode 판정: 훅 수정 아님)

작성: ZCode 리뷰 세션 2026-11-07. 선행: S3b 재검증 완료.

## ZCode 판정 (지시 근거)
- 옵션 (a) "훅 규칙에 맞게 코드 수정"을 택함. **AI_WIKI 공용 훅·banned_pattern_gate는 절대 수정 금지**(전 프로젝트 공유 도구, 이번 범위 밖).
- 선례: HealthFlow hf-partnerize-probe(헤더 이름 오탐 → `// banned-ok: reads caller-supplied header value, not a hardcoded secret` 1줄 해소), Velvet adult-verification(env 이름 오탐 → `// banned-ok: env var name, not a secret value`) — 둘 다 인라인 주석만으로 해소된 확인된 사례.
- 오타입 본질: 스테이지 diff의 `AppEnv.supabaseAnonKey` 참조(변수/환경 접근)와 테스트 fixture 문자열이 시크릿 값으로 오인 — 실제 값 리터럴은 없음(ZCode가 스테이지 diff 전수 확인: 토큰·키 값 리터럴 0건).

## 작업 (공유 체크아웃, 브랜치 feat/voice-user-token-20261107 그대로)
1. 현재 스테이지 상태 유지(픽스처 제외 상태, 인덱스 트리 e8a8b1bc에서 출발). 픽스처·다른 dirty 파일 건드리지 말 것.
2. AI_WIKI 스캐너가 플래그한 6곳("두 Dart 파일의 변수·환경설정 참조")의 정확한 줄을 스캐너 실행 또는 훅 로그로 특정 → 각 줄에 같은 줄 또는 바로 윗줄에 `// banned-ok: <사유>` 주석 추가. 사유 예: `variable reference to AppEnv accessor, not a hardcoded secret`(테스트 fixture 문자열이면 `test fixture value, not a credential`). 주석은 diff에 새 줄로 추가되어도 무방하나 코드·로직 변경은 1자도 없이.
3. 재커밋 시도 → 게이트 통과 확인 → 커밋(`feat(voice): send user access token to openai-proxy with anon fallback`) → 브랜치 push(게시 승인은 S3b 지시서대로 유효).
4. 최종 보고: 플래그 6곳의 파일:줄 + 주석 사유 목록, 커밋 SHA, 원격 SHA, `git diff --cached` 픽스처 grep 0건 재확인.
5. 커밋 후 `dart analyze` 4파일 0건 재확인(주석 추가가 진단에 영향 없음을 증명).

## 시간 예상: N=15분, 단일 보고.
