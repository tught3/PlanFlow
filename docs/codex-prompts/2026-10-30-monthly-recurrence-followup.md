# PlanFlow 월간 반복 수정 — 후속 수정 2건 (Codex 지시서)

대상 브랜치: `fix/planflow-monthly-byday-20261030b` (커밋 `b5235ed4`, 기준 `d7c8bb67`). 이 브랜치 위에 **새 커밋 1개**를 추가한다. 1차 작업의 worktree(`E:\worktrees\planflow-monthly-20261030b`)를 재사용해도 되고, 새 격리 worktree(E:\FluxStudio 바깥)를 만들어도 된다. 1차 계획서 `2026-10-29-monthly-recurrence-fix.md`의 실행 규칙(pathspec 커밋, `git add -A` 금지, main 머지 금지, 작업 브랜치만 push)을 그대로 따른다. 끝나면 Claude가 다시 독립 리뷰한다.

수정 허용 파일: `lib/core/recurrence_expansion.dart`, `lib/services/gpt_service.dart`, `test/core/recurrence_expansion_test.dart`, `test/services/gpt_service_test.dart`. 그 외는 수정하지 말고 보고만 한다. (`home_widget_service.dart`는 공유 함수를 쓰므로 이번엔 수정 불필요. 위젯 테스트는 회귀 확인용으로 실행만 한다.)

## 항목 1. BYMONTHDAY 해석 불가 값은 기존 경로로 넘긴다 (중간 등급 회귀)

문제: `monthlyRecurrenceCandidates`(recurrence_expansion.dart, `final requestedDay = byMonthDay == null ? localStartAt.day : int.tryParse(byMonthDay);` 부근)에서 BYMONTHDAY가 `1,15`(콤마), `-1`(음수), `0`, `32` 등이면 후보가 하나도 만들어지지 않고, 함수가 null이 아닌 리스트를 반환해 시작 회차만 남는다. 수정 전에는 시작일의 일(day)로 반복했으므로 회귀다. 앱이 직접 만드는 값은 아니지만(`recurrence_selector.dart:710`은 1~31 정수만 생성) Naver/Google에서 가져온 `recurrenceRule` 문자열에는 올 수 있다.

수정:
- `byMonthDay != null`일 때 값이 `int.tryParse`로 정수가 되고 **1 이상 31 이하**가 아니면, 함수가 `null`을 반환해 호출부가 기존 반복문 경로로 가게 한다. (기존 경로는 BYMONTHDAY를 무시하고 시작일 기준으로 반복하는 이전 동작이다. 이전 동작 보존이 목적이며 음수·콤마 BYMONTHDAY 정식 지원은 이번 범위가 아니다.)
- 1~31 범위 안의 값(예: 31)은 지금처럼 정책 A(그 달에 없으면 건너뜀)로 처리한다. 범위 안 값의 동작을 바꾸지 않는다.
- BYMONTHDAY와 서수 BYDAY가 함께 있을 때 BYMONTHDAY 우선 규칙은 유지한다. 단 BYMONTHDAY가 해석 불가이면 위 규칙대로 null을 반환한다(서수 BYDAY로 폴백하지 않는다. 단순함 우선).
- 위젯 쪽 호출부는 이미 `dates != null` 검사를 하므로 null이 오면 기존 경로로 간다. 코드 변경 불필요함을 확인만 한다.

테스트(먼저 작성하고 수정 전 실패를 확인):
- `FREQ=MONTHLY;BYMONTHDAY=1,15`, `BYMONTHDAY=-1`, `BYMONTHDAY=0`, `BYMONTHDAY=32` 각각: 2026-01-20 10:00 시작, 범위 2026-01-01~2026-04-30이면 **기존 동작과 같은 결과**를 기대한다. 기존 동작 기대값은 구현을 베끼지 말고, 수정 전 코드(기준 커밋 `d7c8bb67`)에서 같은 입력의 결과를 먼저 실측해 그 값으로 고정한다(예: 20일 반복이면 01-20, 02-20, 03-20, 04-20). 실측 결과와 근거를 보고에 적는다.
- `BYMONTHDAY=31`(범위 안)은 기존 정책 A 테스트가 그대로 통과해야 한다.

## 항목 2. "매달" 뒤 조사 결합 표현 인식 (중간 등급 미탐)

문제: `gpt_service.dart` 정규식 세 곳이 `(?:매월|매달(?![가-힣]))`이다. `(?![가-힣])`가 "매달기"를 막는 대신 "매달마다", "매달에", "매달의"까지 막는다. `매월`은 같은 접미 형태도 인식하므로 비대칭이다.

수정: 세 곳(서수 요일, 일자 `\d{1,2}일`, 일반 `FREQ=MONTHLY`)의 `매달(?![가-힣])`를 동사 어간만 제외하는 `매달(?!기|아|려|리|렸|린|며)`로 바꾼다. 정규식 문자열 앵커로 찾는다(줄 번호는 1405~1436 부근, 기준 커밋과 브랜치가 같음).

테스트(먼저 작성하고 수정 전 실패를 확인):
- 인식해야 함: "매달마다 회의" → `FREQ=MONTHLY`, "매달에 한 번 점검" → `FREQ=MONTHLY`, "매달 마지막 금요일 회의" → `FREQ=MONTHLY;BYDAY=-1FR`(띄어쓰기 있는 기존 형태).
- **확정 결정(2차 개정, Codex 중단 보고 반영)**: "매달의 마지막 금요일"처럼 조사 `의`가 서수 앞에 끼는 표현은 서수 요일로 파싱하지 않는다. 서수 정규식은 `매달\s*서수`라 `의`가 매치를 막으며, `매월의 마지막 금요일`도 기존에 같은 상태이므로 `매월`과 동일하게 둔다. 이 입력은 **테스트에서 단정하지 않는다**. 정규식에 조사 처리를 추가하지 않는다.
- 붙여 쓴 "매달첫째 월요일"은 이번 수정으로 서수 요일로 인식되어도 무방하다(`매월첫째 월요일`이 이미 인식되는 것과 대칭). 단정하지 않고, 인식되면 보고에만 적는다.
- 인식하면 안 됨(기존 G6 계열 포함): "매달기", "매달아 두기", "매달려 있는 물건 정리", "매달리기 훈련"이 `FREQ=MONTHLY`로 시작하는 규칙을 만들지 않는다. 가능하면 `isNot(startsWith('FREQ=MONTHLY'))`보다 구체적인 기대(반복 규칙 없음)로 단정한다.
- 기존 G1~G7이 모두 그대로 통과해야 한다.
- 알려진 한계로 보고만(구현 금지): 띄어 쓴 동사 "매달 사람"류 오탐, "매달의/매월의 + 서수 요일" 미지원(조사 `의`).

## 검증 명령 (순차 실행, 각 종료 코드 기록)
1. `flutter test test/core/recurrence_expansion_test.dart`
2. `flutter test test/services/gpt_service_test.dart`
3. `flutter test test/services/home_widget_service_test.dart` (회귀 확인)
4. `flutter test test/services/voice_date_range_parser_test.dart`
5. `flutter test test/services/voice_schedule_structure_service_test.dart`
6. `flutter analyze` 로 위 변경 4개 파일

## 완료 조건
- 새 테스트가 수정 전 실패, 수정 후 통과. 기존 테스트 전부 통과. analyze 오류 0.
- diff는 허용 파일 4개 안. 커밋은 새 커밋 1개(pathspec), 작업 브랜치에 push, main 머지 금지.

## 보고 형식
1) 선행 확인: 항목 1의 기존 동작 실측값과 근거. 2) 변경 파일 3) 테스트 결과(명령별 종료 코드와 마지막 줄) 4) 알려진 한계 5) 커밋 해시와 push 확인.

## 이번 범위 밖 (건드리지 말 것, 보고만)
`lib/data/repositories/event_repository.dart:423`의 `expandEventOccurrencesForOverlap`에 같은 월 넘침 결함의 세 번째 전개기가 있다(겹침 판정에 사용). 후속 작업으로 Claude가 별도 지시서를 만든다.
