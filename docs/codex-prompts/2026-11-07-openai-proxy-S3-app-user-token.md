# [지시서] PlanFlow S3 — 앱이 openai-proxy에 사용자 access token 전송

작성: ZCode 리뷰 세션 2026-11-07. 선행: S2(c5018593)·S2.1(fff33773) 배포·운영 검증 완료(익명 200·모델 강제 400·무효 401).

## 배경
- 운영 프록시는 이제 `verifyUser`(로그인 사용자) 또는 익명 브리지(`OPENAI_PROXY_ANON_TOKEN`)로 인증. 익명은 IP별 5/분·60/일, 전역 30/분·600/일 쿼터와 허용 모델(gpt-4o-mini) 강제를 받는다.
- 로그인 사용자가 사용자 토큰을 보내면 **사용자 쿼터(20/분·300/일)**로 올라가고 익명 전역 한도를 안 쓴다. 현재 앱은 그러지 못함:
  - `lib/services/voice_command_analysis_service.dart` `_requestCompletion`(~1161행): **항상 anon 키**(`AppEnv.supabaseAnonKey`)로 호출.
  - `lib/services/gpt_service.dart`(~353-364행): 세션 있으면 accessToken 사용하나 **`apikey` 헤더는 항상 anon**. (`Authorization`만 프록시가 보므로 동작상 문제 없음)

## 작업
1. `voice_command_analysis_service.dart` `_requestCompletion`: 로그인 세션이 있으면 `Supabase.instance.client.auth.currentSession?.accessToken`을 `Authorization: Bearer`에 사용, 없으면 기존대로 `AppEnv.supabaseAnonKey` 폴백(비로그인 음성 분석 유지 — 운영 브리지가 살아 있음). `gpt_service.dart`의 기존 패턴을 그대로 따를 것.
2. 두 서비스 모두: 토큰 획득 실패/빈 값 시 anon 폴백 + 기존 debugPrint 스타일로 stage 로그 1줄(예: `stage=anon_fallback`). 토큰 값 자체는 로그에 절대 출력 금지.
3. `apikey` 헤더는 기존 유지(프록시가 검사하지 않음, 변경 범위 최소화).
4. 테스트: 두 서비스의 헤더 검증 유닛 테스트 추가 — (a) 세션 있으면 Authorization=사용자 토큰, (b) 세션 없으면 Authorization=anon 키, (c) 토큰 빈 문자열 → anon 폴백. 기존 mock http client 패턴 활용.
5. `flutter analyze` 0건, `flutter test` 기존 전부 통과 + 신규 통과.
6. 커밋은 PlanFlow 저장소 새 브랜치 `feat/voice-user-token-20261107`에서, 일반 push만, **병합·배포·출시 금지**(검토 후 ZCode가 판정).

## 금지
- Remote Config/프록시 쪽 코드 수정 금지. anon 키 값 자체 교체 금지(신형 키 전환은 별도 S4). NexusFlow는 보류 중이라 건드리지 말 것.

## 시간 예상: N=40분 (20·40·80분 점검)
