# [지시서] S3b — S3 커밋 분리·푸시 완료 (ZCode 재검증 판정 반영)

작성: ZCode 리뷰 세션 2026-11-07. 선행: S3 재검증 완료 — 아래 사실 확인됨.

## ZCode 재검증 결과 (재확인 불필요, 그대로 근거로 사용)
- 스테이징된 S3 4파일(gpt_service, voice_command_analysis_service, 양쪽 test)은 지시서 부합. `dart analyze` 4파일 **0건**, S3 헤더 테스트 통과 확인.
- 실패 테스트 "one utterance preserves weekly time, title, and important flag"(voice_command_analysis_service_test.dart:835)는 **클린 origin/main 워크트리에서도 동일 실패** = 기존 결함, S3와 무관. 전체 analyze/test 비성공도 S3 게이트에서 제외.
- 문제는 딱 2가지: ① 스테이지에 무관한 날짜 픽스처 변경이 섞임, ② 브랜치의 Guide QA 문서 커밋(8f08b24d) 게시 우려.

## 작업 (공유 체크아웃 E:\FluxStudio\PlanFlow, 브랜치 feat/voice-user-token-20261107 그대로)
1. `test/services/voice_command_analysis_service_test.dart`에서 날짜 픽스처 훅(`DateTime.now().year + 1` → 연도 2026 고정 날짜로 바꾼 부분, 스테이지 기준 ~259-269행 부근)만 **인덱스에서 제외**(working tree에는 남길 것 — 폐기 금지, 다른 세션 소유 가능). `git apply --cached -R` 또는 부분 스테이징으로 정밀 분리. # banned-ok: 기존 커밋 금지 패턴 인용(변경 지시 목적)
2. 스테이지 상태 확인: S3 4파일 중 픽스처 훅이 빠진 상태(voice test 파일은 S3 헤더 테스트 훅만 남음) → `git diff --cached`에 날짜 픽스처 문자열이 없는지 grep으로 검증.
3. 커밋 1건: `feat(voice): send user access token to openai-proxy with anon fallback` (본문에 S3 지시서 경로·테스트 결과 명시).
4. **푸시 승인됨**: 이 브랜치의 Guide QA 문서 커밋 8f08b24d는 문서 1건뿐이고 게시해도 무해함이 ZCode가 판정했으므로, 브랜치 전체(8f08b24d + S3 커밋)를 origin에 일반 push. 강제 금지.
5. 최종 보고에 포함: 커밋 SHA, 푸시 후 원격 SHA, `git diff --cached` grep 결과(픽스처 부재 증명), 미스테이지 픽스처 변경의 파일:행 위치.

## 금지
- 워킹트리의 다른 dirty 20여 파일은 다른 세션 소유 — 건드리지 말 것. 픽스처 변경을 폐기하거나 별도 커밋에 넣지 말 것. 병합·출시 금지(ZCode가 리뷰 후 처리).

## 시간 예상: N=15분 (점검 불필요, 단일 보고)
