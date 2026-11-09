# v8b-r7 델타 지시 (2026-11-09, Claude 작성)

**정본**: v8b-r6 델타. **1건 잔여는 환경 플레이크 판정 — 단일 재실행으로 닫는다.**

## Claude 판정 (r6 결과)
- 정상 환경 전체 스위트: **78 → 8 실패로 감소**(73건 기준선 공통 + 신규 1건). TZ 오염 문제는 r6에서 실제로 해소됐다.
- 신규 1건 `ios_release_contract_test: pipe-safe version capture preserves a multi-line producer`는 **Git Bash 하위 프로세스 30초 타임아웃 실패**다 — 이 테스트는 셸 아웃을 수행하고, r6 실행은 대형 full suite 직후 높은 부하 상태였다. 부하성 타임아웃 플레이크가 유력(기준선 r2 실행에서는 통과). 코드 결함 근거 없음.
- TZ probe 임시 파일은 Claude 정리 완료.

## v8b-r7 실행 절차
1. 머지 워크트리(cc47ebce, 수정·커밋 금지)에서 **해당 테스트 1개만 단독 재실행**(TZ unset 유지, 시스템 부하 없는 상태): `flutter test test/ios_release_contract_test.dart --plain-name "pipe-safe version capture preserves a multi-line producer"`. 필요시 테스트 파일 전체 1회 추가 실행.
2. 판정:
   - 통과 → 신규 실패 0 확정(부하 플레이크로 결론). 게이트 통과 → `git push origin HEAD:main` → 머지·베이스라인 워크트리 remove --force + prune → **본앱 적용 완료 보고**.
   - 단독 실행에서도 30초 타임아웃 재현 → 머지 귀속 가능성 남음. 푸시 보류 + 테스트 본문(타임아웃 상수·셸 아웃 대상)과 머지 diff 상관 분석 보고 후 정지(Claude 판정).
3. 상태 JSON에 재실행 증거 기록.
4. 보고: 결과 한 줄 / 단독 재실행 결과 / 게이트 판정 / push 확인 / 잔여 경로.

## 불변
v8b-r6 불변 전부 유효(수정·커밋 금지, 베이스라인 워크트리 접촉 금지, force push 금지, 폰·서버 0, 토큰 출력 금지). full suite 재실행 불요 — 단일 테스트 대조만.
