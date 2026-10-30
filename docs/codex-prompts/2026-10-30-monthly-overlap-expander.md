# PlanFlow 월간 반복 — 세 번째 전개기(겹침 검사) 수정 지시서

이 문서는 대화를 못 보는 Codex가 혼자 읽고 작업할 수 있게 쓴 자기완결 지시서다. 끝나면 Claude가 독립 리뷰한다.

## 1. 목표
"새 일정을 잡을 때 기존 일정과 겹치는지" 판정하는 함수 `expandEventOccurrencesForOverlap`(lib/data/repositories/event_repository.dart)이 월간 반복을 아직 옛 방식으로 펼친다. 이미 머지된 공유 함수 `monthlyRecurrenceCandidates`를 쓰게 고쳐서, 달력 화면·홈 위젯과 같은 날짜를 내게 한다.

## 2. 배경 (이미 끝난 일)
- 월간 반복 결함("매월 마지막 금요일", "매월 31일"이 틀린 날짜로 펼쳐지는 버그)을 `origin/main`에서 고쳤다. 기준 커밋 **`560a7f944314193bbca9bc183bc0b96e9580c306`** (1차 `b5235ed4` + 후속 `560a7f94`). 참고 문서: `E:\FluxStudio\PlanFlow\docs\codex-prompts\2026-10-29-monthly-recurrence-fix.md`, `2026-10-30-monthly-recurrence-followup.md` (정책 A 등 결정 사항 확인용).
- 공유 함수: `lib/core/recurrence_expansion.dart`의 `List<DateTime>? monthlyRecurrenceCandidates({required String rule, required DateTime localStartAt, required DateTime hardEnd, required int interval})`. 시작 회차를 포함해 후보를 정렬해 반환하고, 서수 없는 BYDAY나 해석 불가 BYMONTHDAY면 `null`을 반환해 호출부가 기존 반복문 경로를 쓰게 한다. `hardEnd`는 배타 경계다.
- 정책 A(확정): 그 달에 없는 날짜(예: 2월 31일)는 건너뛴다. 바꾸지 않는다.
- 같은 결함이 남은 곳이 세 군데였고 둘은 고쳤다. 마지막이 이번 작업이다. 위젯에서 이미 한 방식이 모범 답안이다: `lib/services/home_widget_service.dart`의 `if (freq == 'MONTHLY') { final dates = monthlyRecurrenceCandidates(...); if (dates != null) { ...; return occurrences.isEmpty ? <EventModel>[event] : occurrences; } }` 블록(WEEKLY 분기 뒤, 일반 반복문 앞).

## 3. 이번에 고칠 곳 (기준 커밋 기준)
`lib/data/repositories/event_repository.dart` (줄 번호는 **`origin/main` 기준**이며 함수명·문자열 앵커가 같으면 진행한다):
- 파일 맨 위 import는 1~4행(`supabase_flutter`, `../../core/local_time.dart`, `../models/event_model.dart`).
- `List<EventModel> expandEventOccurrencesForOverlap(` 335행 ~ 441행.
- WEEKLY 특수 분기 364~404행, 그 뒤 일반 반복문 `var current = localStartAt;` 406행~.
- 결함 위치: 반복문 안 `'MONTHLY' => DateTime(current.year, current.month + interval, current.day, ...)` 421~428행. 직전 회차의 일(day)에서 한 달을 더해 월말에 날짜가 밀리고(1월 31일 → 3월 3일), 서수 BYDAY·BYMONTHDAY를 완전히 무시한다.
- 같은 파일의 보조 함수: `_copyEventWithTime`(443행~), `_eventIntersectsOverlapRange`(460행), `_parseRRuleUntilForOverlap`(478행, UNTIL을 해당 일 23:59:59로 만든다), `_parseRRuleByDaysForOverlap`(495행).
- 호출처: 같은 파일 639행 부근(`expandEventOccurrencesForOverlap(event, rangeStart:, rangeEnd:)` 후 `occurrences.any(...)`로 겹침 판정). 호출부는 바꾸지 않는다.

**중요 — 작업 기준:** `E:\FluxStudio\PlanFlow` 공유 체크아웃의 `event_repository.dart`에는 다른 세션의 **미커밋 변경(+75/-3)**이 있고 이 파일의 줄 번호가 1줄 어긋나 있다. 그 체크아웃에서 작업하지 말고, **`origin/main`(560a7f94)에서 E:\FluxStudio 바깥에 격리 worktree를 새로 만들어** 작업한다. 반드시 먼저 `git fetch origin main` 후 `git rev-parse origin/main`이 `560a7f94…`인지 확인한다. 더 새 커밋이 있으면 그 위에서 하되 보고에 적는다.

## 4. 선행 확인 (작업 전, 결과를 기록)
1. `git status`/`git diff`로 worktree가 clean이고 `event_repository.dart`가 기준 커밋과 같은지.
2. `expandEventOccurrencesForOverlap`의 MONTHLY 처리가 위 설명과 동작상 같은지(서수·BYMONTHDAY 무시, 직전 일 기준 +interval개월).
3. `lib/core/recurrence_expansion.dart`에 `monthlyRecurrenceCandidates`가 공개로 있는지, 그리고 `recurrence_expansion.dart`가 `event_repository.dart`를 import하는지(순환 import 여부). `rg "event_repository" lib/core/recurrence_expansion.dart`. 순환이면 **멈추고 보고**한다.
4. `event_repository.dart`가 `recurrence_expansion.dart`와 이름이 겹치는 공개 심볼을 선언하는지(가능성은 낮지만 확인). 충돌을 피하려고 import는 `show monthlyRecurrenceCandidates`로 한정한다.
5. `rg "month \+ interval" lib` 로 같은 결함 공식이 더 남았는지. 지금까지 확인으로는 core(고침)·위젯(고침)·이 파일 세 곳뿐이지만, 직접 확인하고 더 있으면 보고한다(이번 범위에서는 고치지 않는다).
6. 기존 테스트 `test/data/repositories/event_repository_overlap_test.dart`의 구조(헬퍼, 공개 함수 직접 호출, `planflowLocal` 사용)를 읽고 같은 스타일로 쓴다.

## 5. 수정 방법
1. `event_repository.dart` 상단에 `import '../../core/recurrence_expansion.dart' show monthlyRecurrenceCandidates;` 추가(기존 import 정렬 규칙을 따른다).
2. WEEKLY 분기 뒤, 일반 반복문(`var current = localStartAt;`) 앞에 위젯과 같은 모양의 MONTHLY 분기를 넣는다:
   - `monthlyRecurrenceCandidates(rule: rule, localStartAt: localStartAt, hardEnd: hardEnd, interval: interval)` 호출(이 함수 안의 `rule`은 이미 대문자 변환된 문자열이다).
   - `dates != null`이면 각 `current`에 대해 `_copyEventWithTime(event, startAt: current, endAt: current.add(duration))`로 후보를 만들고 `_eventIntersectsOverlapRange(candidate, rangeStart, rangeEnd)`이면 `occurrences`에 추가, 그리고 `return occurrences.isEmpty ? <EventModel>[event] : occurrences;`
   - `dates == null`이면 아래로 떨어져 기존 반복문을 그대로 쓴다.
3. 일반 반복문 안의 `'MONTHLY' => DateTime(...)` 줄은 **지우지 말고 그대로 둔다**(서수 없는 BYDAY MONTHLY 등 `null` 폴백 경로가 여전히 거기로 오기 때문). 위젯 쪽도 같은 방침이었다.
4. 이 함수는 삭제된 회차(deletedOccurrenceDates) 처리를 원래 하지 않는다. **추가하지 않는다**(범위 밖).
5. UNTIL: 이 파일의 `_parseRRuleUntilForOverlap`은 그대로 쓴다. 파서를 바꾸거나 core의 것으로 교체하지 않는다.

## 6. 건드리면 안 되는 것
- 수정 허용 파일은 **둘뿐**: `lib/data/repositories/event_repository.dart`, `test/data/repositories/event_repository_overlap_test.dart`. 그 외는 수정하지 말고 보고만 한다.
- WEEKLY·DAILY·YEARLY 처리, 호출부(639행 부근), `_copyEventWithTime`·`_eventIntersectsOverlapRange`·UNTIL 파서, core·위젯의 공유 함수는 건드리지 않는다.
- 정책 A, `monthlyRecurrenceCandidates` 동작은 바꾸지 않는다.

## 7. 테스트 (먼저 작성하고, 수정 전 실패를 확인)
`test/data/repositories/event_repository_overlap_test.dart`에 추가. 기대값은 **구현을 베끼지 말고 달력으로 독립 계산**한다. 날짜 리터럴은 이 저장소의 커밋 훅이 고정 달력 날짜를 막으므로 기존 테스트가 쓰는 규칙대로 줄 끝에 `// banned-ok: Fixed calendar regression fixture; independent of current clock.` 주석을 단다(이전 커밋들에서 그렇게 했다). 아래 날짜는 달력 확인 값이다.

달력 사실: 2026-10-30은 금요일. 마지막 금요일은 2026-11-27, 12-25, 2027-01-29, 02-26. 2026-01-31은 토요일.

| ID | 입력 | 범위 | 기대 |
|---|---|---|---|
| O1 | 2026-10-30 10:00 시작, `FREQ=MONTHLY;BYDAY=-1FR` | 2026-11-27 00:00 ~ 2026-11-28 00:00 | 반환된 회차 중 `startAt`이 2026-11-27 10:00인 것이 정확히 1건 (수정 전: 옛 공식이 2026-11-30을 내므로 실패) |
| O2 | 동일 | 2026-11-30 00:00 ~ 2026-12-01 00:00 | 반환 목록에 `startAt`이 2026-11-30인 회차가 **없다** (원본 `[event]` 폴백은 허용: 그 `startAt`은 2026-10-30) |
| O3 | 동일 | 2027-01-29 ~ 2027-01-30, 2027-02-26 ~ 2027-02-27 | 각각 해당 날짜 10:00 회차 1건 |
| O4 | 2026-01-31 09:00 시작, `FREQ=MONTHLY` (BYDAY·BYMONTHDAY 없음) | 2026-02-28 ~ 2026-03-01 | 그 범위에 속한 회차 **없음**(정책 A: 2월은 건너뜀, 수정 전 옛 공식은 2026-03-03을 내서 별개로 실패 확인용) |
| O5 | 동일 | 2026-03-31 00:00 ~ 2026-04-01 00:00 | 2026-03-31 09:00 회차 1건 (수정 전 실패) |
| O6 | 동일 | 2026-04-03 00:00 ~ 2026-04-04 00:00 | `startAt`이 2026-04-03인 회차 없음 (옛 공식의 밀린 날짜) |
| O7 | 2026-01-20 10:00 시작, `FREQ=MONTHLY;BYMONTHDAY=32` | 2026-03-20 ~ 2026-03-21 | 2026-03-20 10:00 회차 1건 — 해석 불가 BYMONTHDAY는 기존 경로(시작일 기준 매월)로 폴백한다는 후속 수정 결과의 회귀 고정 |
| O8 | 앱 전개기와의 일치 | O1의 이벤트, 범위 2026-11-01 ~ 2027-03-01 | `expandRecurringEvent`(lib/core/recurrence_expansion.dart)가 같은 이벤트·범위에서 낸 `startAt` 목록과 `expandEventOccurrencesForOverlap`이 낸 `startAt` 목록이 같다 (서로 다른 전개기가 같은 날짜를 낸다는 이번 작업의 핵심 보장). `expandRecurringEvent`의 시그니처(`event`, `rangeStart`, `rangeEnd`, `includeOccurrence`)는 core 파일에서 확인해 맞춘다 |

수정 전 실패해야 하는 것: O1, O5, O6(경우에 따라 O4), O8. 실패 출력 요약을 보고에 적는다. 기존 테스트(주간, 메타데이터 보존)는 그대로 통과해야 한다.

## 8. 검증 명령 (순차 실행, 각 종료 코드 기록)
1. `flutter test test/data/repositories/event_repository_overlap_test.dart`
2. `flutter test test/core/recurrence_expansion_test.dart`
3. `flutter test test/services/home_widget_service_test.dart`
4. `flutter test test/services/event_prefetch_service_test.dart`
5. `flutter test test/data` (이 디렉터리 전체, 회귀 확인)
6. 변경 2개 파일에 대해 `flutter analyze lib/data/repositories/event_repository.dart test/data/repositories/event_repository_overlap_test.dart`

## 9. 완료 조건
- 새 테스트가 수정 전 실패 → 수정 후 통과. 기존 테스트 전부 통과. analyze 오류 0.
- diff는 허용 파일 2개 안. 새 커밋 1개(변경 파일을 pathspec으로 지정, `git add -A` 금지), 작업 브랜치(예: `fix/planflow-monthly-overlap-20261030`)에 push, **main에는 머지하지 않는다**.

## 10. 보고 형식
1) 선행 확인 결과 1~6번(특히 순환 import, `month + interval` 검색 결과) 2) 변경 파일과 각 변경 요약 3) 수정 전 실패한 테스트와 수정 후 결과(명령별 종료 코드와 마지막 줄) 4) 알려진 한계 5) 커밋 해시와 push 확인(원격 해시 일치) 6) 문서 전제와 실제가 달랐던 점.

## 11. 실행 규칙
- 격리 git worktree는 E:\FluxStudio 바깥(예: `E:\worktrees\planflow-monthly-overlap-20261030`). 공유 체크아웃에서 작업하지 않는다.
- 커밋은 본인이 바꾼 파일만 pathspec으로. stash·reset·clean 등 남의 미커밋 변경을 건드리는 명령 금지. 작업 브랜치까지만 push.
- 전제가 **동작 수준에서** 다르면 추측하지 말고 멈춰서 무엇이 다른지 보고한다. 줄 번호만 다르면 멈추지 말고 함수명·문자열 앵커로 진행한다.
- 테스트는 한 번에 하나씩 순차 실행한다(저장소의 ADB/프로젝트 작업 큐 규칙이 있으면 따른다).

## 12. 이번 범위 밖 (보고만)
- 삭제된 회차 처리, 음수·콤마 BYMONTHDAY 정식 지원, `COUNT`·`BYSETPOS`, 다른 음성 파서의 "매달" 지원, "매달의/매월의 + 서수" 미지원.
