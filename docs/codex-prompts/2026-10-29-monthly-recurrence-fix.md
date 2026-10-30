# [Codex 구현 지시] PlanFlow 월간 반복 일정(서수 요일·N일·"매달") 전개 버그 수정

> 사용법: 이 문서 전체를 Codex에 붙여넣는다. 구현이 끝나면 Claude가 독립 리뷰한다.
> **정책 결정 완료(2026-10-30, 사용자): 5.3절 선택지 A(그 달에 없는 날짜는 건너뜀)로 확정.** 결정을 기다리지 말고 A로 구현한다. 한 줄 전환 지점(private 함수)은 그대로 둔다.
>
> **개정 2판(2026-10-30) — 1차 착수에서 Codex가 낸 BLOCKED_PRECONDITION을 반영함.**
> - **기준 코드는 커밋 HEAD `d7c8bb67b4ddf256495df80626836ac5c5eb32df`(main)이다.** 공유 체크아웃의 `gpt_service.dart`에는 다른 세션의 미커밋 변경(테스트 주입 훅, 반복 규칙과 무관)이 있어 줄이 15줄 어긋났었다.
> - **`gpt_service.dart`의 줄 번호는 이 문서 전체에서 15를 빼서 읽어라.** 앵커 표: 서수 정규식 `매월\s*(첫\s*번째|첫째…` = HEAD 1405행(문서 1420), BYMONTHDAY `매월\s*(\d{1,2})일` = 1422행(문서 1437), `contains('매월')` = 1426행(문서 1441), `N달마다` = 1436행(문서 1451), 다른 파서 경로 1060·1079·1271 = 1045·1064·1256. 다른 파일의 줄 번호는 HEAD와 같다.
> - **줄 번호가 몇 줄 다르다는 이유로 멈추지 마라.** 앵커(함수명·정규식 문자열)의 내용이 같으면 그대로 진행한다. 내용(동작)이 다를 때만 멈추고 보고한다.
> - **범위 변경: 홈 위젯 서비스(`lib/services/home_widget_service.dart`의 `_expandSingleWidgetEvent`)에 별도 전개기가 있고 MONTHLY가 같은 결함 공식(801-808행)이다. 이번 범위에 포함한다 → 5.4절.**

## 1. 역할과 목표
당신은 Flutter/Dart 시니어 개발자입니다. 대상은 `E:\FluxStudio\PlanFlow`입니다. AI 음성으로 일정을 관리하는 Flutter 앱입니다.
목표는 세 가지입니다.
1. "매월 마지막 금요일"이나 "매월 첫째 월요일"처럼 서수 요일로 정한 월간 반복 일정이 매달 올바른 날짜에 펼쳐지게 합니다.
2. "매월 31일"처럼 그 달에 없는 날짜로 반복할 때 날짜가 다음 달로 넘치거나 이후 회차가 틀어지지 않게 합니다.
3. "매달"이라는 표현을 "매월"과 같게 인식하게 합니다. 범위는 `gpt_service.dart`의 로컬 규칙 경로 한 곳뿐입니다. 다른 파서 경로의 "매달" 미지원은 후속 작업입니다(4.5절).

수정은 반드시 필요한 만큼만 하고, 테스트를 먼저 작성하고, 근거로 보고합니다.

## 2. 배경과 구조 (파싱 → 저장 → 전개 → 소비)
- **파싱** `lib/services/gpt_service.dart`
  - 1420-1436행: 정규식 `매월\s*(첫째|둘째|셋째|넷째|마지막)\s*[월화수목금토일]요일`이 `FREQ=MONTHLY;BYDAY=<서수><요일토큰>`을 만듭니다. "마지막"은 -1입니다(예: `-1FR`).
  - 1437-1439행: `매월\s*(\d{1,2})일`이 `FREQ=MONTHLY;BYMONTHDAY=N`을 만듭니다.
  - 1441행: `text.contains('매월')`이면 `FREQ=MONTHLY`가 됩니다.
  - 1451행: `(\d{1,2})\s*(일|주|개월|달|월|년)\s*마다`는 "N달마다"류만 처리합니다. 단독 "매달"은 어디에서도 인식하지 않습니다.
- **저장**: 위에서 만든 RRULE 문자열이 일정 레코드의 recurrence_rule에 저장됩니다. 정확한 필드명은 코드에서 확인하세요.
- **전개** `lib/core/recurrence_expansion.dart`
  - 67행: `if (freq == 'WEEKLY')`일 때만 `_parseRRuleByDays`(299행부터)로 BYDAY를 씁니다. 주 단위 루프이고 안전카운터는 120입니다.
  - 그 밖의 freq는 113-149행의 일반 루프(안전카운터 420)로 갑니다. 128-148행에서 다음 회차를 이렇게 계산합니다.
    - DAILY: +interval일
    - WEEKLY: +7×interval일
    - MONTHLY: `DateTime(current.year, current.month + interval, current.day, h, m, s)`
    - YEARLY: `DateTime(current.year + interval, current.month, current.day, ...)`
  - BYDAY 서수, BYMONTHDAY, BYSETPOS는 모두 쓰지 않습니다. 306행 `replaceAll(RegExp(r'[-0-9]'), '')`가 서수를 지워 버립니다.
  - 삭제된 회차는 `_isDeletedLocalDay(deletedDays, current)`로 건너뜁니다(95, 118행).
  - 범위 판정은 `include(candidate, rangeStart, rangeEnd)`, 상한은 `hardEnd`입니다.
- **소비**: `expandRecurringEvent`, `occurrenceLocalDaysInRange`, `eventHasOccurrenceInRange`를 호출하는 파일은 6곳입니다(독립 검토에서 `rg`로 센 결과. 횟수는 구현 전에 `rg`로 다시 확인).
  - `calendar_screen`, `voice_action_screen`, `group_event_recurrence`, `voice_conversation_controller`
  - `home_widget_service.dart`는 공통 함수를 쓰지 **않습니다**. 자체 복제 전개기 `_expandSingleWidgetEvent`(713-821행)가 있고 MONTHLY가 같은 결함 공식입니다(801-808행). 5.4절에서 함께 고칩니다.
  - BYDAY/BYSETPOS 문자열 처리는 이와 별도로 9개 파일에 흩어져 있습니다(`lib/widgets/recurrence_selector.dart` 포함).

## 3. 근본 원인과 재현 예시
- **원인 A (서수 무시)**: MONTHLY는 BYDAY를 전혀 보지 않고 `current.day`에 한 달을 더하기만 합니다.
  - 재현: 2026-10-30(금, 그 달 마지막 금요일)에 `FREQ=MONTHLY;BYDAY=-1FR`로 시작하면, 다음 회차가 2026-11-30(월)이 됩니다. 정답은 2026-11-27(금)입니다.
- **원인 B (월 오버플로와 연쇄 드리프트)**: Dart `DateTime(2026, 4, 31)`은 2026-05-01로 정규화됩니다.
  - 루프가 직전 회차의 `current.day`를 이어받습니다. 그래서 한 번 넘친 뒤에는 이후 모든 회차의 날짜가 1일 등으로 바뀔 수 있습니다.
  - 해당 대상: `BYMONTHDAY=29~31`, 그리고 시작일이 29~31일인 일반 `FREQ=MONTHLY`.
- **원인 C (어휘 누락)**: "매달 마지막 금요일", "매달 15일", "매달 회비"를 반복으로 인식하지 못합니다.
- 주의: 위 동작은 코드를 읽고 추론한 것이며 아직 실행해 확인하지 않았습니다. 7절의 재현 테스트를 먼저 작성해 **실패하는 것을 확인**하세요.

## 4. 선행 확인 단계 (구현 전 반드시 수행하고 결과를 보고에 적을 것)
1. `git -C E:\FluxStudio\PlanFlow rev-parse --show-toplevel`로 PlanFlow가 독립 저장소인지, `E:\FluxStudio`의 하위 디렉터리인지 확인합니다. 이 결과에 따라 11절의 worktree를 만듭니다.
2. 전개 테스트는 이미 `test/core/recurrence_expansion_test.dart`가 있습니다(기존 MONTHLY 테스트가 약 122행에 있음). 새 케이스는 이 파일에 추가하고, 기존 MONTHLY 테스트는 수정 전후 모두 통과(불변)해야 합니다.
3. 아래 항목이 RRULE을 스스로 전개하는지, 아니면 recurrence_expansion 결과를 쓰는지 확인하고 보고합니다. **이 항목들의 수정은 이번 범위가 아닙니다. 보고만 합니다.**
   - 홈 위젯: Flutter `home_widget_service.dart`의 자체 전개기는 확인됨(5.4절에서 수정). `android/`·`ios/` 네이티브 코드의 자체 RRULE 전개는 1차 착수에서 찾지 못했음(재확인만)
   - `notification_service`, `departure_alarm_service`가 전개 결과를 쓰는지
   - `calendar_sync_service`, `naver_caldav_service`, 구글 동기화가 recurrence_rule 문자열을 그대로 외부로 내보내는지. 5.3 정책 권고의 근거가 됩니다.
4. `lib/widgets/recurrence_selector.dart`가 만드는 월간 RRULE 형태를 확인합니다. 예: `BYDAY=-1FR`, `BYDAY=FR;BYSETPOS=-1`, `BYMONTHDAY=N`, 서수 없는 `BYDAY=MO`. `rg "BYSETPOS|BYMONTHDAY|BYDAY" lib`로 9개 파일 전체에서 어떤 형태가 생성되고 들어오는지 목록을 만듭니다. (독립 검토 결과: `recurrence_selector.dart:703-728`은 `BYDAY=<서수><요일>`과 `BYMONTHDAY=N`만 만들고, `BYSETPOS` 생성 경로는 `lib`에서 확인되지 않았습니다. 따라서 BYSETPOS는 구현하지 말고 보고만 합니다.)
5. `rg "매월" lib`로 `gpt_service.dart` 말고도 "매월"을 해석하는 곳이 있는지 확인합니다. 다른 파싱 경로가 있으면 "매달"을 거기에도 넣을지는 **보고만 하고**, 그 경로는 수정하지 않습니다. 독립 검토에서 이미 확인된 다른 경로: `voice_command_analysis_service.dart:922-959`, `gpt_service.dart:1060·1079·1271`, `voice_command_pipeline.dart:256`, `voice_schedule_structure_service.dart`(631·811·892·921·933·1854행). 이들의 "매달" 미지원은 후속 작업이며, 보고서에 목록으로만 적습니다.
6. 기존 저장 레코드와의 호환을 확인합니다. 이미 저장된 `BYDAY=-1FR`, `BYMONTHDAY=31`, 시작일 31일 `FREQ=MONTHLY` 레코드가 수정 뒤 어떻게 보일지 정리합니다. 데이터 마이그레이션은 하지 않습니다(전개 쪽만 바꾸므로 저장 문자열은 그대로).
7. **네이티브(android/ios) 위젯이 자체적으로 RRULE을 전개하면** 이번 수정 뒤 앱과 그 위젯의 날짜가 서로 달라집니다. 이 사실을 보고서 맨 위에 경고로 적습니다(네이티브 수정은 이번 범위 밖). Flutter 위젯 서비스는 5.4절에서 이번에 고칩니다.

## 5. 수정 위치와 방법

### 5.1 전개: `lib/core/recurrence_expansion.dart`
- 67행의 WEEKLY 분기와 같은 방식으로 **MONTHLY 전용 분기**를 추가합니다. 일반 루프(113-149)의 DAILY/WEEKLY/YEARLY 경로는 건드리지 않습니다. **월간 후보 날짜 계산은 위젯도 재사용하도록 이 파일의 라이브러리 수준 공개 함수 하나로 분리합니다**(5.4절). 구현을 두 군데에 복사하지 마세요.
- **분기 조건(확정)**: `freq == 'MONTHLY'`이고 (BYDAY에 서수가 있음 **또는** BYMONTHDAY가 있음 **또는** BYDAY 자체가 없음)이면 새 분기로 갑니다. BYDAY가 있지만 서수가 없는 경우(`BYDAY=MO` 등)는 기존 일반 루프를 그대로 씁니다. BYDAY와 BYMONTHDAY가 함께 오면 BYMONTHDAY를 우선하고 보고서에 적습니다.
- **기준점 고정 계산**: k번째 대상 월은 `DateTime(start.year, start.month + k*interval, 1)`처럼 **시작 월로부터 계산**합니다. 직전 회차의 `current.day`를 이어받지 않습니다. 이렇게 해야 드리프트가 생기지 않습니다. 시, 분, 초는 시작 시각을 유지합니다.
- 각 대상 월에서 후보 날짜를 정하는 규칙:
  - **BYDAY에 서수가 있을 때**(`1MO`~`4MO`, `5XX`, `-1XX`. 쉼표로 여러 개가 와도 됨): 그 달의 n번째 요일을 구합니다. -1은 마지막 해당 요일입니다. **그 달에 5번째 요일이 없으면 그 달은 건너뜁니다**(RFC 5545). 후보가 여러 개면 날짜순으로 냅니다.
  - **`BYDAY=XX;BYSETPOS=n`(요일 하나, 위치 하나)**: 4.4에서 이 형태가 실제로 생성되거나 들어오는 것으로 확인되면, 서수 요일 `nXX`와 같게 처리합니다. 확인되지 않으면 구현하지 말고 보고만 합니다.
  - **BYMONTHDAY=N**: 그 달에 N일이 있으면 그날을 씁니다. 없으면 5.3 정책을 따릅니다. 음수(-1은 말일)가 이미 들어오는 경로가 있으면 RFC대로 말일 기준으로 처리하고, 없으면 지원하지 않아도 됩니다.
  - **BYDAY와 BYMONTHDAY가 모두 없을 때**: 시작일의 day를 기준으로 BYMONTHDAY와 같은 규칙을 씁니다. 시작일이 28일 이하이면 결과가 기존과 **완전히 같아야** 합니다. 29~31일은 의도적인 동작 변경이므로 보고에 명시합니다.
  - **MONTHLY인데 BYDAY에 서수가 없을 때**(예: `BYDAY=MO`): 기존 동작을 유지합니다(기존 일반 루프로 보냄). 이번 범위가 아니며, 이 형태가 생성되는지만 보고합니다.
- **시작 회차(확정 규칙)**: 시작 일정 자체는 규칙에 맞든 안 맞든 기존대로 첫 회차로 냅니다(기존 일반 루프가 그렇게 함, 113-127행). 시작 월의 후보 중 `localStartAt`보다 이른 것은 버리고, 후보가 시작 일시와 같은 날짜이면 중복 없이 한 번만 냅니다. 예: 시작 10-29(목) + `BYDAY=-1FR`이면 10-29(시작 회차)와 10-30(후보)이 둘 다 나옵니다. 테스트 E14로 고정합니다.
- **INTERVAL > 1**: k*interval로 월을 건너뜁니다.
- **UNTIL / COUNT**: UNTIL은 기존 `_parseRRuleUntil`(57행, 282-297행)이 날짜 +1일을 `hardEnd`로 쓰는 방식을 그대로 따릅니다. COUNT는 현재 코드에 파싱이 없으므로(47-57행) **구현하지 않습니다**. 보고만 합니다.
- **삭제 회차**: `_isDeletedLocalDay(deletedDays, candidate)`로 건너뛰는 동작을 그대로 지킵니다.
- **범위와 상한**: `include(candidate, rangeStart, rangeEnd)`와 `hardEnd`를 그대로 씁니다.
- **안전카운터**: MONTHLY 분기에도 반복 횟수 상한을 둡니다. 값은 기존과 같은 420입니다(시작 월부터 센 420개월 상한). "낸 회차 수"가 아니라 "검사한 달 수"를 셉니다. 5번째 요일처럼 자주 건너뛰는 규칙이 무한 루프에 빠지지 않게 하기 위해서입니다.
- 306행의 서수 제거(`_parseRRuleByDays`)는 WEEKLY용이므로 **바꾸지 않습니다**. 월간용 BYDAY 파싱은 서수를 보존하는 함수를 따로 둡니다(이 파일 안의 private 함수 하나).

### 5.2 파싱: `lib/services/gpt_service.dart` 1420-1441 부근
- 1420, 1437, 1441행 **세 곳 모두** 같은 표현 `(?:매월|매달(?![가-힣]))`를 씁니다(1441행은 `contains('매월')`을 같은 의미의 정규식 판정으로 바꿈). 동사 '매달다'가 잘못 걸리지 않도록 **"매달" 바로 뒤에 한글이 오면 제외**하는 조건입니다. 이 조건이면 "매달 회비", "매달 15일", "매달15일"은 인식되고, "매달기"와 "매달아"는 제외됩니다. 한계: "매달첫째"처럼 한글을 붙여 쓴 표현은 세 곳 모두에서 놓칩니다. 그 한계를 보고에 적습니다.
- 1451행 "N달마다" 처리는 바꾸지 않습니다.

### 5.3 그 달에 없는 날짜 처리 정책 — **확정: 선택지 A**
- **선택지 A (RFC 5545, 권고하는 기본값)**: 그 달을 건너뜁니다. 예: 매월 31일이면 2월, 4월, 6월 등은 회차가 없습니다.
  - 근거: 저장된 RRULE이 Google이나 네이버 CalDAV로 그대로 내보내진다면(4.3에서 확인), 외부 캘린더는 A로 해석합니다. 앱만 다르게 펼치면 기기마다 날짜가 달라집니다. Google Calendar도 "매월 31일"을 이렇게 처리합니다.
- **선택지 B (말일로 당김)**: 2월이면 28일 또는 29일에 회차를 냅니다. "월세·카드값 매달 말일" 같은 생활 일정에는 B가 더 직관적일 수 있습니다. 하지만 외부 캘린더와 어긋납니다. 올바른 표현은 `BYMONTHDAY=-1` 같은 별도 규칙입니다.
- **구현 지시**:
  - A를 기본으로 구현합니다.
  - 정책 분기는 **private 함수 하나**에만 둡니다(한 줄만 바꾸면 B로 전환되게). 설정값이나 옵션 클래스는 만들지 않습니다.
  - 4.3 결과(외부로 내보내는지)를 근거와 함께 보고합니다. 최종 결정은 사용자가 합니다.

### 5.4 홈 위젯 서비스: `lib/services/home_widget_service.dart` (이번 범위에 포함)
- 대상은 `_expandSingleWidgetEvent`(713-821행)의 **MONTHLY 처리뿐**입니다. 현재 785-819행의 일반 루프에서 801-808행 `DateTime(current.year, current.month + interval, current.day, ...)`가 같은 결함을 냅니다.
- 방법: 5.1절에서 분리한 공개 함수를 불러서 월간 후보 날짜를 얻고, 위젯의 기존 도우미(`_copyWidgetEventWithTime`, `_widgetEventIntersectsRange`)로 이벤트를 만듭니다. 분기 조건은 5.1절과 **같은 규칙**(서수 BYDAY, BYMONTHDAY, BYDAY 없음 → 새 경로 / 서수 없는 BYDAY → 기존 루프)입니다.
- 위젯 쪽 기존 동작은 그대로 유지합니다: 마지막 `return occurrences.isEmpty ? <EventModel>[event] : occurrences;`, `until` 처리, 안전카운터 420, `_hideOverriddenWidgetOccurrences` 흐름. 위젯에는 삭제 회차 처리가 없으니 **추가하지 않습니다**(범위 밖).
- DAILY/WEEKLY/YEARLY와 위젯의 나머지 코드는 수정하지 않습니다.
- 테스트: `test/services/home_widget_service_test.dart`가 이미 있고 반복 일정 케이스(870·898행 부근 `FREQ=WEEKLY`)가 있으니 그 방식을 모델로 MONTHLY 케이스를 추가합니다. (HEAD 앵커 검증 완료: 서수 정규식 문자열 1406행, `monthlyDay` 1422행, `contains('매월')` 1426행, `마다` 1436행. 위젯 도우미 `_copyWidgetEventWithTime` 864행, `_widgetEventIntersectsRange` 901행, `_hideOverriddenWidgetOccurrences` 916행 실존.) 반복 전개를 이미 검증하는 seam이 있으면 그것으로 위젯 경로의 E1(마지막 금요일)·E5(31일) 상응 케이스를 추가합니다. seam이 없으면 새 `@visibleForTesting`을 **최소 하나만** 도입하고 그 사유를 보고합니다. 공통 함수의 동작 자체는 7절 E 시리즈가 검증합니다.
- 보고: 위젯 경로를 고친 뒤 앱 전개와 위젯 전개의 날짜가 같은지 비교한 결과를 적습니다.

## 6. 건드리면 안 되는 것
- `rrule` 등 새 패키지 도입, `pubspec.yaml` 변경 금지
- CalDAV, 네이버·구글 동기화 코드, `ical_parser`
- GPT 프롬프트, STT, 음성 대화 흐름(gpt_service의 1420-1441 부근 정규식 말고는 수정 금지)
- UI 전체(`recurrence_selector.dart` 포함), 네이티브 코드(android/ios), 알림 서비스, 그리고 홈 위젯 서비스는 5.4절의 MONTHLY 처리 외 모든 부분
- recurrence_expansion의 DAILY, WEEKLY, YEARLY 경로와 WEEKLY의 `_parseRRuleByDays`
- 다른 세션의 미커밋 변경. 공유 체크아웃에 다른 사람의 수정이 많습니다. 손대지 마세요.
- 다른 파서 경로: `voice_command_analysis_service.dart`, `voice_command_pipeline.dart`, `voice_schedule_structure_service.dart`, 그리고 `gpt_service.dart`의 1420-1441행 밖 정규식(1060·1079·1271행 등). "매달"을 거기에 넣고 싶어도 수정하지 말고 보고만 합니다.
- 이번 범위 밖 테스트 보강("다음주 화요일 3시", "이번 주말" 등)은 하지 않습니다. 필요하면 보고에 제안만 합니다.

## 7. 테스트 먼저 (TDD)
수정 전에 아래 테스트를 작성해 **현재 코드에서 실패하는 것**을 확인합니다. 그다음 구현해서 통과시킵니다. 시각은 모두 10:00 등 시작 시각을 유지하는지 함께 assert합니다. "(달력 검증)" 표시가 있는 정답은 구현 전에 `DateTime(...).weekday` 등으로 직접 확인하고, 틀리면 고친 뒤 보고합니다.

**전개 테스트** (전개 전용 테스트 파일. 없으면 새로 만듦. 기존 공개 함수의 시그니처를 그대로 씀)

| # | 규칙 | 시작 | 기대 회차 (범위 안 앞부분) |
|---|---|---|---|
| E1 | `FREQ=MONTHLY;BYDAY=-1FR` | 2026-10-30 10:00(금) | 2026-10-30, 2026-11-27, 2026-12-25, 2027-01-29 (2027-01-29가 금요일인지 달력 검증) |
| E2 | `FREQ=MONTHLY;BYDAY=1MO` | 2026-11-02 (월) | 2026-11-02, 2026-12-07, 2027-01-04 (달력 검증) |
| E3 | `FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR` | 2026-10-30 | 2026-10-30, 2026-12-25, 2027-02-26 (달력 검증) |
| E4 | `FREQ=MONTHLY;BYDAY=5FR`, 조회 범위 2026-10-01~2027-03-31 | 2026-10-30 | 2026-10-30, 2027-01-29 (2026년 11·12월과 2027년 2·3월은 5번째 금요일이 없어 건너뜀. 범위를 2027-04-30까지 넓히면 2027-04-30도 나옴. 달력 검증) |
| E5 | `FREQ=MONTHLY;BYMONTHDAY=31` | 2026-01-31 | 정책 A: 01-31, 03-31, 05-31, 07-31, 08-31 / 정책 B: 01-31, 02-28, 03-31, 04-30, 05-31. 어느 정책이든 **3월은 31일**(드리프트 없음) |
| E6 | `FREQ=MONTHLY` | 2026-01-15 | 01-15, 02-15, 03-15 (기존 동작 불변 회귀 테스트) |
| E7 | `FREQ=MONTHLY` | 2026-01-31 | E5와 같은 정책 결과 (의도적인 동작 변경) |
| E8 | `FREQ=MONTHLY;BYMONTHDAY=15` | 2026-10-15 | 10-15, 11-15, 12-15 |
| E9 | E1 + 2026-11-27 삭제 | 2026-10-30 | 10-30, 12-25, 2027-01-29 |
| E10 | E1 + UNTIL 2026-12-31 (기존 코드가 지원하는 UNTIL 형식으로) | 2026-10-30 | 10-30, 11-27, 12-25 까지만 |
| E11 | E1, 조회 범위 2026-12-01~2026-12-31 | 2026-10-30 | 12-25 하나만 |
| E12 | E4를 긴 범위(예: 10년)로 조회 | 2026-10-30 | 무한 루프 없이 종료, 안전카운터 안에서 끝남 |
| E13 | DAILY, WEEKLY(BYDAY 포함), YEARLY 대표 규칙 각 1개 | 기존 데이터 | **수정 전 결과를 기준값으로 기록**하고 수정 후 같은지 확인 |
| E14 | `FREQ=MONTHLY;BYDAY=-1FR` (시작이 규칙과 어긋남) | 2026-10-29 10:00(목) | 2026-10-29(시작 회차), 2026-10-30, 2026-11-27 — 시작 회차 규칙(5.1절) 고정. 중복·시작일 이전 회차 없음 |

COUNT는 현재 코드에서 미지원이므로 테스트하지 않습니다.

**파싱 테스트** (`test/services/gpt_service_test.dart`. 약 300, 1459행의 "첫 번째 월요일" 케이스 방식을 따름)

| # | 입력 | 기대 |
|---|---|---|
| G1 | "매달 마지막 금요일 회의" | `FREQ=MONTHLY;BYDAY=-1FR` |
| G2 | "매달 15일 병원" | `FREQ=MONTHLY;BYMONTHDAY=15` |
| G3 | "매달 회비 납부" | `FREQ=MONTHLY` |
| G4 | "매월 마지막 금요일 회의" | `FREQ=MONTHLY;BYDAY=-1FR` (회귀 테스트) |
| G5 | "매월 첫째 월요일" | 기존 기대값 그대로 (회귀 테스트) |
| G6 | "현수막 매달기", "풍선 매달아 두기" | MONTHLY 반복이 **아님** |
| G7 | "3달마다 점검" | 기존 동작 그대로 (수정 전 결과를 기준값으로 기록) |

## 8. 검증 명령 (PlanFlow 루트 또는 worktree의 PlanFlow 경로에서)
1. **수정 전 기준선**: worktree에서 `flutter pub get`을 실행한 뒤, 아래 테스트 파일을 하나씩 실행해 통과·실패 수와 실패 테스트 이름을 원문으로 기록합니다. 기존 실패는 이번 작업 탓이 아니라는 근거가 됩니다.
   - `flutter test test/services/gpt_service_test.dart`
   - `flutter test test/services/voice_date_range_parser_test.dart`
   - `flutter test test/services/voice_schedule_structure_service_test.dart`
   - `flutter test test/core/recurrence_expansion_test.dart`
   - `flutter test test/services/home_widget_service_test.dart`
2. **새 테스트가 실패하는 것 확인**: E1~E13, G1~G7 추가 직후 실행합니다. E1~E5, E7, E9~E11, G1~G3이 실패해야 정상이고(현재 코드가 BYDAY를 무시하므로), E6, E8, E12, E13, G4, G5, G7은 통과해야 정상입니다. E14는 결과를 그대로 보고합니다.
3. **구현 후**:
   - `flutter test <전개 테스트 파일>`
   - `flutter test test/services/gpt_service_test.dart`
   - 위 기준선 파일 전부 재실행
   - `flutter analyze lib/core/recurrence_expansion.dart lib/services/gpt_service.dart <새/변경 테스트 파일>`
4. 각 명령의 종료 코드와 출력 끝부분 요약을 원문으로 보관합니다.

## 9. 완료 조건
- E1~E13, G1~G7(COUNT 지원 시 그 케이스도)이 모두 통과합니다.
- 기준선 테스트에 **새 실패가 0건**입니다. 기존 실패는 수가 같거나 줄어야 합니다.
- `flutter analyze`에서 변경 파일에 새 error나 warning이 없습니다.
- 변경 파일은 원칙적으로 다음뿐입니다. 이 밖의 파일을 고쳤다면 사유를 적습니다.
  - `lib/core/recurrence_expansion.dart`
  - `lib/services/gpt_service.dart`
  - `lib/services/home_widget_service.dart` (5.4절의 MONTHLY 처리만)
  - 테스트: `test/core/recurrence_expansion_test.dart`, `test/services/gpt_service_test.dart`, `test/services/home_widget_service_test.dart`
- 4절 선행 확인 결과 7개 항목이 모두 보고되어 있습니다.

## 10. 보고 형식 (이 순서로)
1. **경고**(있을 때만): 위젯이나 동기화 쪽 불일치처럼 이번 수정으로 생기는 부작용
2. **선행 확인 결과**: 4절의 1~7번 각각에 대해 사실과 파일:줄
3. **변경 파일 목록**과 파일별 diff 요약
4. **테스트 실행 결과 원문**: 기준선, 실패 확인, 구현 후의 명령, 종료 코드, 통과/실패 수
5. **결정한 정책과 근거**: 5.3에서 어느 정책을 기본으로 했는지, 그 근거가 된 4.3 결과, B로 바꾸는 방법(어느 함수의 어느 줄)
6. **의도적인 동작 변경 목록**: 예를 들어 시작일 29~31일인 일반 MONTHLY. 정책 A에서 영향받는 달을 명시합니다(31일 시작은 2·4·6·9·11월 회차가 사라짐, 30일 시작은 2월, 29일 시작은 평년 2월).
7. **미확인·미지원 사항**: 서수 없는 MONTHLY BYDAY, 붙여 쓴 "매달첫째", YEARLY 2월 29일, COUNT 미지원, BYSETPOS 미생성, 4.5절의 다른 파서 경로 목록 등
8. **커밋 해시와 push한 브랜치 이름**

"테스트 통과"처럼 근거 없는 문장은 쓰지 않습니다. 실행 출력 원문을 붙입니다.

## 11. 실행 규칙
- **격리된 git worktree에서 작업합니다.** 공유 체크아웃(`E:\FluxStudio`)에는 다른 세션의 미커밋 변경이 많습니다.
  - PlanFlow는 `E:/FluxStudio/PlanFlow`가 독립 git 저장소 루트입니다(독립 검토에서 `rev-parse --show-toplevel`로 확인했고 4.1에서 재확인). worktree는 반드시 `E:\FluxStudio` **밖**(예: `E:\worktrees\planflow-monthly-20261029`)에 만듭니다.
  - 브랜치 예: `fix/planflow-monthly-byday-20261029`
- 작업 전후로 `git status --porcelain -uall`로 상태를 확인합니다.
- 다른 사람의 변경에 `git stash`, `git reset`, `git checkout -- <path>`, `git clean`을 쓰지 않습니다.
- 커밋은 **본인이 바꾼 파일만 pathspec으로 지정**합니다(`git add <파일>...`). `git add -A`나 `git add .`은 금지입니다. 커밋 후 `git show --stat HEAD`로 포함된 파일을 확인합니다.
- push는 작업 브랜치까지만 합니다. `-f`/`--force`는 금지입니다. 거부되면 `git pull --rebase` 후 다시 시도합니다.
- **main에 머지하지 않습니다.** 독립 리뷰가 끝난 뒤에 머지합니다.
- 작업 중 띄운 프로세스(flutter, dart 데몬 등)는 끝나면 정리합니다. 다른 프로세스는 종료하지 않습니다.
- 지시의 전제(파일 경로, 줄 번호, 함수 이름)가 실제 코드와 다르면 추측해서 진행하지 말고 멈춘 뒤, 무엇이 다른지 보고합니다.

## 12. 이후 절차
이 작업 결과는 Claude가 **독립 리뷰**합니다. 리뷰에서는 커밋된 diff를 보고, 테스트를 직접 다시 실행하고, 정책 결정 근거를 검토합니다. 리뷰를 통과한 뒤에 main에 머지합니다. 그러니 보고는 리뷰어가 같은 결과를 재현할 수 있을 만큼 구체적으로(명령, 경로, 커밋 해시) 작성합니다.
