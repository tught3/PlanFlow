## 스마트 준비 알람 개선 지시

### 배경
현재 스마트 준비 알람이 "출발 시간"만 알려주는데,
실제로는 "준비 시작 시간"부터 단계적으로 알려줘야 함.
사용자마다 준비 시간이 다르므로 설정값으로 관리.

---

### 1. DB 변경 (user_settings 테이블)

아래 컬럼 추가:
```sql
alter table user_settings
  add column prep_time_min integer default 30,
  add column prep_pre_alarm_offset integer default 30,
  add column depart_pre_alarm_offset integer default 30;
-- prep_time_min: 준비 시간 (분)
-- prep_pre_alarm_offset: 준비 시작 사전 예고 알림 (분 전, 0이면 안 받기)
-- depart_pre_alarm_offset: 출발 사전 예고 알림 (분 전, 0이면 안 받기)
```

---

### 2. 알람 역산 로직 수정

lib/services/smart_alarm_service.dart (또는 pre_action 생성 로직)

**하루 첫 일정 판단:**
- 당일 일정 중 start_at이 가장 이른 일정 = 첫 일정
- 첫 일정만 준비 알람 적용
- 이후 일정은 출발 알람만 적용

**알람 생성 순서 (예: 12시 원주, 이동 90분):**
```
출발 시각 = start_at - 이동시간 - 여유 30분
         = 12:00 - 90분 - 30분 = 10:00

[첫 일정인 경우]
① 준비 사전 예고 = 출발시각 - prep_time_min - prep_pre_alarm_offset
  예) prep_time=60분, pre_offset=30분
  = 10:00 - 60분 - 30분 = 08:30
  메시지: "30분 뒤부터 준비 시작하세요 🔔"
  → prep_pre_alarm_offset == 0이면 생략

② 준비 시작 알람 = 출발시각 - prep_time_min
  = 10:00 - 60분 = 09:00
  메시지: "지금 준비 시작하세요 🚿"

[모든 일정 공통]
③ 출발 사전 예고 = 출발시각 - depart_pre_alarm_offset
  예) depart_offset=30분
  = 10:00 - 30분 = 09:30
  메시지: "30분 뒤 출발해야 해요 🔔"
  → depart_pre_alarm_offset == 0이면 생략

④ 출발 알람 = 출발시각
  = 10:00
  메시지: "지금 출발하세요 🚗 (이동 약 90분)"
```

**중복/음수 방지:**
- 각 알람 시각이 현재 시각보다 과거면 생략
- 알람 간격이 5분 미만으로 겹치면 합쳐서 하나만 울림
- prep_pre_alarm_offset == 0이면 ① 생략
- depart_pre_alarm_offset == 0이면 ③ 생략

---

### 3. UserSettingsModel 수정

lib/data/models/user_settings_model.dart
```dart
// 추가 필드
final int prepTimeMin;           // 기본 30
final int prepPreAlarmOffset;    // 기본 30 (0=안받기)
final int departPreAlarmOffset;  // 기본 30 (0=안받기)
```

fromJson/toJson/copyWith 모두 업데이트

---

### 4. 설정 화면 UI 추가

lib/screens/settings/settings_screen.dart에
"스마트 준비 알람 설정" 섹션 추가:

```
⏰ 스마트 준비 알람 설정

나의 평균 준비 시간
→ SegmentedButton: [15분] [30분] [45분] [1시간] [직접입력]
→ 직접입력 선택 시 숫자 입력 필드 표시

준비 시작 사전 알림
→ SegmentedButton: [안 받기] [10분 전] [30분 전] [둘 다]
→ "둘 다" = 10분 전 + 30분 전 두 번 울림

출발 사전 알림
→ SegmentedButton: [안 받기] [10분 전] [30분 전] [둘 다]

하단 안내 문구:
"※ 준비 시간은 하루 첫 일정에만 적용돼요"
```

---

### 5. 온보딩에 추가

초기 설정 온보딩 화면에 준비 시간 선택 단계 추가.
기본값 30분으로 설정되어 있으므로 스킵 가능.

---

### 6. 스마트 준비 알람 맥락 판단 개선 (동시 적용)

현재 "병원" 키워드만 보고 무조건 진료 목적으로 판단하는 문제 수정.
GPT 파싱 프롬프트에서 선행행동 생성 시
장소 키워드만 보지 말고 행동 동사 + 장소 조합으로 판단할 것.

판단 기준:
- "진료", "검사", "수술", "입원", "시술" 포함 → 의료 목적
  → 금식/보험카드 준비 알람 생성
- "미팅", "영업", "방문", "상담", "계약" 포함 → 업무 목적
  → 일반 이동 준비 알람만 생성 (금식 알람 금지)
- "병문안", "문병" 포함 → 방문 목적
  → "꽃이나 선물 챙기기" 알람 생성
- 행동 동사 없이 장소만 있는 경우 → 불분명
  → ConfirmScreen에서 목적 선택 UI 표시:
     [진료/검사] [업무/영업] [병문안] [기타]
  → 사용자 선택 후 그에 맞는 선행행동 생성

병원 외 동일 원칙:
- "법원" → 소송/재판 vs 업무 방문
- "학교" → 학부모 상담 vs 업무
장소만으로 목적을 단정하지 말 것.
GPT 프롬프트 few-shot 예시도 이에 맞게 업데이트.

---

### 7. 테스트 케이스

구현 후 아래 케이스 직접 테스트:
1. 12시 원주 일정, 이동 90분, 준비 60분, 사전알림 30분
   → 08:30 / 09:00 / 09:30 / 10:00 순서로 4개 알람 생성 확인
2. 준비 사전알림 "안 받기" 설정 시 08:30 알람 생략 확인
3. 하루 두 번째 일정은 준비 알람 없이 출발 알람만 생성 확인
4. "병원 미팅" → 금식 알람 생성 안 됨 확인
5. "병원 진료" → 금식 알람 생성 확인
6. "병원" 단독 → ConfirmScreen에서 목적 선택 UI 표시 확인

---

### 8. 준비/출발 알람을 모든 일정에 기본 적용 (핵심 수정)

**현재 문제:**
준비/출발 알람이 스마트 준비 알람(선행행동)이 감지된 일정에만 생성됨.

**수정 방향:**
일정 저장 시 선행행동 감지 여부와 관계없이
**모든 일정에 준비/출발 알람을 기본으로 생성**할 것.

구현 위치: 일정 저장 로직 (event_repository 또는 reminder_service)

```dart
// 일정 저장 후 항상 실행
Future<void> createDefaultAlarms(EventModel event, UserSettings settings) async {

  // 이동시간 계산 (위치 정보 있을 때만, 없으면 0분으로 처리)
  int travelMin = 0;
  if (event.locationLat != null && event.locationLng != null) {
    travelMin = await mapService.getTravelMinutes(...) ?? 0;
  }

  // 출발 시각 = 일정 시작 - 이동시간 - 여유 30분
  final departAt = event.startAt
      .subtract(Duration(minutes: travelMin + 30));

  // 현재 시각보다 과거면 알람 생성 스킵
  if (departAt.isBefore(DateTime.now())) return;

  // 하루 첫 일정 여부 확인
  final isFirstEvent = await eventRepository.isFirstEventOfDay(
    userId: event.userId,
    date: event.startAt,
    eventId: event.id,
  );

  // [첫 일정만] 준비 사전 예고 알람
  if (isFirstEvent && settings.prepPreAlarmOffset > 0) {
    final prepPreAt = departAt
        .subtract(Duration(minutes: settings.prepTimeMin + settings.prepPreAlarmOffset));
    await scheduleAlarm(
      notifyAt: prepPreAt,
      title: event.title,
      body: '${settings.prepPreAlarmOffset}분 뒤부터 준비 시작하세요 🔔',
    );
  }

  // [첫 일정만] 준비 시작 알람
  if (isFirstEvent) {
    final prepAt = departAt.subtract(Duration(minutes: settings.prepTimeMin));
    await scheduleAlarm(
      notifyAt: prepAt,
      title: event.title,
      body: '지금 준비 시작하세요 🚿',
    );
  }

  // [모든 일정] 출발 사전 예고 알람
  if (settings.departPreAlarmOffset > 0) {
    final departPreAt = departAt
        .subtract(Duration(minutes: settings.departPreAlarmOffset));
    await scheduleAlarm(
      notifyAt: departPreAt,
      title: event.title,
      body: '${settings.departPreAlarmOffset}분 뒤 출발해야 해요 🔔',
    );
  }

  // [모든 일정] 출발 알람
  await scheduleAlarm(
    notifyAt: departAt,
    title: event.title,
    body: travelMin > 0
        ? '지금 출발하세요 🚗 (이동 약 ${travelMin}분)'
        : '곧 일정이 시작돼요 ✅',
  );
}
```

**위치 정보 없는 일정 처리:**
- 이동시간 계산 불가 → travelMin = 0
- 출발 알람 대신 "일정 시작 30분 전" 알람으로 대체
- 메시지: "곧 일정이 시작돼요 ✅"

**스마트 준비 알람(선행행동)과의 관계:**
- 준비/출발 알람은 모든 일정에 기본 적용 (이번 수정)
- 스마트 준비 알람(금식, 서류 등)은 AI 감지 시 추가로 생성
- 두 가지가 함께 동작하는 구조

**테스트 케이스 추가:**
7. 장소 없는 일정 ("팀 회의") → 출발 알람 대신 30분 전 알람 생성 확인
8. 두 번째 이후 일정 → 준비 알람 없이 출발 알람만 생성 확인
9. 과거 일정 저장 시 → 알람 생성 스킵 확인

---

### 9. 외부 장소 있는 일정에만 준비/출발 알람 적용

**수정 배경:**
모든 일정에 준비/출발 알람을 적용하면
집에서 하는 일정(강아지 밥주기, 재택근무, 화상회의 등)에도
불필요한 알람이 울리는 문제 발생.

**외부 일정 판단 기준:**
아래 두 조건 모두 충족 시에만 준비/출발 알람 생성:

조건 1: location 필드가 비어있지 않음
조건 2: location 또는 title에 내부/집 키워드가 없음

```dart
// 내부/집 키워드 목록
const internalKeywords = [
  '집', '재택', '자택', '집에서', '집앞',
  '온라인', '화상', '줌', 'zoom', 'zep', 'webex',
  '구글밋', 'google meet', 'teams', 'ms teams',
  '전화', '통화', '콜', '전화회의', '컨퍼런스콜',
  '내부', '사내', '팀내', '오피스', '자체',
];

bool isExternalEvent(EventModel event) {
  // 장소 없으면 외부 일정 아님
  if (event.location == null || event.location!.trim().isEmpty) {
    return false;
  }

  final location = event.location!.toLowerCase();
  final title = event.title.toLowerCase();

  // 내부 키워드 포함 시 외부 일정 아님
  for (final keyword in internalKeywords) {
    if (location.contains(keyword) || title.contains(keyword)) {
      return false;
    }
  }

  return true;
}
```

**첫 외부 일정 판단 수정:**
```dart
// 기존: 당일 start_at이 가장 이른 일정
// 수정: 당일 외부 장소 있는 일정 중 start_at이 가장 이른 일정
Future<bool> isFirstExternalEventOfDay({
  required String userId,
  required DateTime date,
  required String eventId,
}) async {
  final dayEvents = await eventRepository.fetchByDate(
    userId: userId,
    date: date,
  );

  // 외부 일정만 필터링
  final externalEvents = dayEvents
      .where((e) => isExternalEvent(e))
      .toList()
    ..sort((a, b) => a.startAt.compareTo(b.startAt));

  // 가장 이른 외부 일정이 현재 일정인지 확인
  return externalEvents.isNotEmpty &&
      externalEvents.first.id == eventId;
}
```

**알람 생성 흐름 최종 정리:**
```
일정 저장
    ↓
isExternalEvent() 체크
    ↓
외부 일정 아님 → 알람 생성 안 함 (끝)
    ↓
외부 일정 맞음
    ↓
이동시간 계산 (T맵 → 네이버 폴백)
    ↓
isFirstExternalEventOfDay() 체크
    ↓
첫 외부 일정 → 준비 사전예고 + 준비 시작 + 출발 사전예고 + 출발 알람
이후 외부 일정 → 출발 사전예고 + 출발 알람만
```

**테스트 케이스 추가:**
10. "강아지 밥주기" (장소 없음) → 알람 생성 안 됨 확인
11. "재택근무" → 알람 생성 안 됨 확인
12. "줌 미팅" → 알람 생성 안 됨 확인
13. "JW제약 미팅" (외부 장소) → 알람 생성 확인
14. 당일 첫 일정이 재택, 두 번째가 외부 미팅
    → 외부 미팅이 "첫 외부 일정"으로 판단되어 준비 알람 생성 확인
