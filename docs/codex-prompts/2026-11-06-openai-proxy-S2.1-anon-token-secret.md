# [지시서] openai-proxy S2.1 — 익명 토큰 시크릿 폴백 (SUPABASE_ 접두 우회)

작성: ZCode 리뷰 세션 2026-11-06. 상위 문맥: `2026-11-06-openai-proxy-S2-anon-bridge-and-followups.md`, 인수인계 문서 1절.

## 배경 (왜 필요한가 — 조사 결과, 재검증됨)
- S2(c5018593)는 운영에 배포됨(v19+, `--no-verify-jwt`), 그러나 **익명 호출이 전부 401**.
- 원인: 앱(`env/local.json`의 `SUPABASE_ANON_KEY`, 출시 APK에도 동일 값 각인)의 anon 키가 **프로젝트 현재 키 4개(legacy anon/service_role, publishable, secret)와 전부 불일치**(`GET /v1/projects/xqvvfnvmytjlblcngipn/api-keys?reveal=true`로 대조, match NONE). 구키가 로테이션되어 사라짐.
- 핸들러는 `SUPABASE_ANON_KEY`와 정확 일치만 인정하는데, 이 이름은 Edge 런타임 **내장 주입값**(관리 API로 설정 불가 — `Secret name must not start with the SUPABASE_ prefix`)이며, 그 값은 현재 키라 앱 구키와 절대 일치하지 않음.
- 즉 지시서 S2의 "SUPABASE_ANON_KEY와 정확히 일치" 설계는 운영 제약과 충돌. 앱 키 교체는 S3(앱 릴리스) 몫이므로 그때까지 프록시 쪽 브리지가 필요.

## 작업 (동일 워크트리 `E:\.codex\worktrees\planflow-openai-proxy-S1-20261105`, 동일 브랜치에서 이어서)
1. `handler.ts`의 익명 키 소스를 변경: **`OPENAI_PROXY_ANON_TOKEN`** 시크릿이 설정되어 있으면 그 값을 익명 비교 대상으로 사용, 없으면 기존대로 `SUPABASE_ANON_KEY` 폴백. (`configuredAnonKey` 산출 부분만; 로직·우선순위·상수시간 비교는 그대로 유지)
2. 스위치 조건 유지: `OPENAI_PROXY_ALLOW_ANON === "true"`일 때만 활성. `OPENAI_PROXY_ANON_TOKEN`이 빈 문자열이면 undefined 취급(401).
3. 테스트 추가(handler.test.ts): (a) ANON_TOKEN 설정 + 그 토큰으로 200, (b) ANON_TOKEN 설정 + 구 SUPABASE_ANON_KEY 토큰으로 401, (c) ANON_TOKEN 빈 문자열 → 401, (d) ANON_TOKEN 미설정 시 기존 폴백 동작 유지, (e) ANON_TOKEN이 임의 길이/동일 길이 오답일 때 401(타이밍 세이프 경로 유지).
4. README에 환경변수 1줄 추가.
5. 리베이스: origin/main(6692d6bc, S1+S2 머지 완료) 위로. `_shared/auth.ts` 수정 금지. 기존 94 테스트 전부 통과 유지 + 신규 5건.
6. 검증 후: 브랜치에 일반 push만(강제 금지), **배포·시크릿 금지**(배포는 ZCode 리뷰 세션이 수행).
7. `deno fmt --check`·`deno lint` 0건.

## 시간 예상: N=30분 (15·30·60분 점검)

## 운영 컨텍스트 (배포 시 ZCode가 사용)
- 배포 직후 `OPENAI_PROXY_ANON_TOKEN` 시크릿(값 = 앱 구 anon 키, 공개 키이므로 무결성 문제 없음)을 관리 API로 upsert 예정.
- 현재 배포 상태: 익명 전면 401(로그인 사용자는 정상). 롤백(v17 원문, `E:\FluxStudio\backup\openai-proxy-v17-20261106\index.ts` eszip)은 보존 완료.
