# PlanFlow — Codex 마스터 프롬프트 v3 (최종)

---

## 🧭 Codex에게

```
너는 PlanFlow라는 AI 음성 기반 지능형 스케줄러 앱을 처음부터 만들어야 해.
아무것도 없는 상태에서 시작하니까 환경 세팅부터 코드 구현까지 순서대로 진행해줘.
중간에 판단이 필요한 부분은 멈추지 말고 이 문서의 스펙 기준으로 결정해서 진행해.

⚠️ 코드를 구현하거나 수정하기 전에 반드시 agents.md를 먼저 읽고 그 내용을 그대로 따라서 진행해.
agents.md에 명시된 규칙이 최우선이야.

사용자가 직접 해야 하는 작업(Supabase SQL 실행, API 키 발급 등)은
해당 시점에 명확하게 안내하고 대기해줘.
```

---

## 📱 앱 스펙

- **앱 이름**: PlanFlow
- **플랫폼**: Android 우선 (iOS는 추후)
- **프레임워크**: Flutter (Dart)
- **백엔드**: Supabase (PostgreSQL + Auth + Realtime)
- **AI 파싱**: OpenAI GPT-4o-mini
- **STT**: 온디바이스 (speech_to_text 패키지, onDevice: true 필수)
- **TTS**: flutter_tts (모닝/이브닝 브리핑용)
- **음성 보안 원칙**: 음성 파일은 절대 외부 서버 전송 금지. STT 변환 텍스트만 Supabase 저장.

---

## 🚀 1차 배포 전략

1차 배포는 수익구조 없이 **전체 기능 무료 오픈**으로 진행.
목적은 사용자 확보 및 검증.

- 모든 기능 제한 없이 무료 제공
- 앱 내 **"PRO 얼리버드 신청" 버튼** 하나만 노출
- 버튼 클릭 시 이메일 수집 (Supabase early_bird_emails 테이블 저장)
- 2차 배포 때 수익구조(플랜/구독) 적용
- 유료 전환 시 얼리버드 신청자에게 할인 쿠폰 발송

---

## 💰 수익구조 (2차 배포 때 적용, 지금은 참고용)

### 플랜 구성

| 플랜 | 가격 | 타깃 |
|------|------|------|
| FREE | 무료 | 맛보기 |
| PRO | ₩4,900/월 | 개인 헤비유저 |
| MASTER | ₩9,900/월 | 완전 무제한 개인 |
| TEAM S | ₩19,900/월 | 3인 |
| TEAM M | ₩37,400/월 | 6인 |
| TEAM L | ₩68,900/월 | 12인 |
| BUSINESS | 별도 견적 | 13인 이상 기업 |

### 플랜별 기능 한도

| 기능 | FREE | PRO | MASTER | 광고등급 |
|------|------|-----|--------|---------|
| 음성 등록 | 월 20회 | 무제한 | 무제한 | ⭐ |
| 음성 수정/삭제 | 월 10회 | 무제한 | 무제한 | ⭐ |
| 음성 단순 조회 | 월 10회 | 무제한 | 무제한 | ⭐ |
| 일정 저장 | 50개 | 무제한 | 무제한 | - |
| 모닝/이브닝 브리핑 | 월 3회 | 월 10회 | 무제한 | ⭐⭐ |
| 선행행동 역산 알림 | 월 1회 | 월 7회 | 무제한 | ⭐⭐ |
| 이동시간 버퍼 | 월 1회 | 월 3회 | 무제한 | ⭐⭐ |
| 음성 고급 조회 | ❌ | 월 30회 | 무제한 | ⭐⭐ |
| 시스템 알람 | 월 2회 | 월 10회 | 무제한 | ⭐ |
| 카톡/문자 일정 감지 | 월 2회 | 월 10회 | 무제한 | ⭐⭐⭐ |
| 통화 텍스트 일정 감지 | ❌ | 월 3회 | 무제한 | ⭐⭐⭐ |
| 단순 충돌 감지 | ✅ | ✅ | ✅ | - |
| AI 맥락 충돌 감지 | ❌ | 월 10회 | 무제한 | ⭐⭐⭐ |
| 홈 위젯 | ✅ 무료 | ✅ | ✅ | - |
| 구글/네이버 캘린더 | 읽기만 | 읽기+쓰기 | 읽기+쓰기 | - |
| 리워드 광고 추가사용 | ✅ | ✅ (한도소진후) | ❌ | - |
| 네이티브 광고 | 있음 | 없음 | 없음 | - |

### 네이티브 광고 표시 방식 (FREE 전용)
일정 카드 3~4개마다 광고 카드 1개 자연스럽게 삽입.
실제 일정과 구분되도록 아래 규칙 적용:
- 배경색: 실제 일정(흰색) vs 광고(연한 회색)
- 우측 상단에 작게 "광고" 라벨 표시 (법적 광고 표시 의무 충족)
- 시계 아이콘 대신 업체 아이콘 표시
- PRO/MASTER는 네이티브 광고 완전 제거 → "광고 없는 깔끔한 화면"이 PRO 전환 이유 중 하나

### 기능 등급 정의

| 등급 | 기준 | 해당 기능 | 광고 방식 | 총 시간 |
|------|------|----------|----------|--------|
| ⭐ 일반 | 있으면 편한 기능 | 음성 등록/수정/삭제, 단순 조회, 시스템 알람 | 30초 1개 | 30초 |
| ⭐⭐ 핵심 | 자주 쓰는 킬러 기능 | 브리핑, 선행역산, 고급 조회, 이동시간 버퍼 | 1분 1개 | 1분 |
| ⭐⭐⭐ 프리미엄 | 차원이 다른 AI 기능 | AI 맥락 충돌 감지, 카톡/문자 감지, 통화 감지 | 1분 1개 + 30초 1개 연속 | 1분 30초 |

> 광고 전 사전 안내 모달 표시 필수.
> 모달에 [시청하기] + [업그레이드] 버튼 나란히 배치 → 자연스러운 구독 전환 유도.

### 단순 조회 vs 고급 조회 정의

**단순 조회** (GPT 없음, DB 직접 검색)
```
"내일 일정 뭐야?"
"오늘 몇 시에 미팅이야?"
"이번 주 일정 말해줘"
→ 날짜/시간 기준으로 DB에서 바로 꺼내오면 됨
```

**고급 조회** (GPT 맥락 이해 필요)
```
"지난번 서호메디코 사장 만났던 장소가 어디야?"
"이번 달 JW제약 몇 번 만났어?"
"다음 주 비어있는 오후가 언제야?"
→ 자연어 의도 파악 + DB 검색 + GPT 답변 생성
```

### 단순 충돌 vs AI 맥락 충돌 정의

**단순 충돌** (GPT 없음, DB 쿼리)
```
"같은 시간에 일정이 2개 있어요"
→ 시작시간 ~ 종료시간 겹침만 체크
```

**AI 맥락 충돌** (GPT 판단)
```
"1시 30분 강남 미팅 → 2시 여의도 미팅"
→ 이동시간 40분 계산 → 사실상 불가능
→ "이동시간이 부족해요. 2시 30분으로 조정할까요?"

"오전 8시 위내시경 → 전날 저녁 9시 회식"
→ 금식 필요한데 회식 존재
→ "위내시경 전날인데 회식 괜찮으실까요?"
```

### 리워드 광고 구조

한도 소진 시 **사전 안내 모달 먼저** 표시 후 광고 진행:

```
⭐ 일반 기능 한도 소진 시:
┌─────────────────────────────────┐
│  이 기능을 1회 더 사용하려면     │
│  📺 30초 광고 1개               │
│  시청 후 즉시 사용 가능해요.     │
│  광고를 끝까지 봐야 사용권 지급  │
│  PRO 구독 시 무제한 사용 가능    │
│  [취소]  [광고 보고 사용하기]   │
└─────────────────────────────────┘

⭐⭐ 핵심 기능 한도 소진 시:
┌─────────────────────────────────┐
│  이 기능을 1회 더 사용하려면     │
│  📺 30초 광고 2개 연속           │
│  시청 후 즉시 사용 가능해요.     │
│  광고를 끝까지 봐야 사용권 지급  │
│  PRO 구독 시 월 10회 사용 가능   │
│  [취소]  [광고 보고 사용하기]   │
└─────────────────────────────────┘

⭐⭐⭐ 프리미엄 기능 한도 소진 시:
┌─────────────────────────────────┐
│  이 기능을 1회 더 사용하려면     │
│  📺 1분 광고 2개 연속            │
│  시청 후 즉시 사용 가능해요.     │
│  광고를 끝까지 봐야 사용권 지급  │
│  MASTER 구독 시 무제한 사용 가능 │
│  [취소]  [광고 보고 사용하기]   │
└─────────────────────────────────┘
```

### TEAM/BUSINESS 추가 기능
- 팀 캘린더 공유
- 음성으로 팀원 일정 등록
- 팀 브리핑
- 관리자 대시보드
- BUSINESS 전용: SSO, 권한 제어, 사용 현황 리포트, 부서별 캘린더, 영업 히스토리 CRM, 전담 CS

---

## 🗄️ DB 스키마

> ⚠️ 사용자 작업 요청: Supabase 대시보드 → SQL Editor에서 아래 SQL 전체 실행해주세요.

```sql
-- 1. users
create table users (
  id uuid primary key references auth.users(id),
  email text,
  name text,
  created_at timestamp default now()
);

-- 2. events
create table events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  title text not null,
  start_at timestamp not null,
  end_at timestamp,
  location text,
  location_lat float,
  location_lng float,
  memo text,
  supplies text[],
  is_critical boolean default false,
  source text default 'manual', -- 'voice' | 'manual' | 'google' | 'naver'
  external_id text,
  created_at timestamp default now()
);

-- 3. pre_actions (선행행동 역산 알림)
create table pre_actions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references events(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  title text not null,
  notify_at timestamp not null,
  is_done boolean default false,
  created_at timestamp default now()
);

-- 4. reminders
create table reminders (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references events(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  type text not null, -- 'push' | 'system_alarm' | 'evening' | 'morning'
  notify_at timestamp not null,
  is_sent boolean default false,
  created_at timestamp default now()
);

-- 5. voice_logs (텍스트만 저장, 음성파일 절대 금지)
create table voice_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  raw_text text,
  parsed_json jsonb,
  event_id uuid references events(id),
  created_at timestamp default now()
);

-- 6. location_history (과거 준비물 참고용)
create table location_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  location text,
  supplies text[],
  event_id uuid references events(id),
  visited_at timestamp default now()
);

-- 7. user_settings
create table user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade unique,
  morning_briefing_at time default '07:30',
  evening_briefing_at time default '21:00',
  default_reminder_min integer default 60,
  google_calendar_token text,
  naver_calendar_token text,
  created_at timestamp default now()
);

-- 8. early_bird_emails (1차 배포 얼리버드 이메일 수집)
create table early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamp default now()
);

-- RLS 활성화
alter table events enable row level security;
alter table pre_actions enable row level security;
alter table reminders enable row level security;
alter table voice_logs enable row level security;
alter table location_history enable row level security;
alter table user_settings enable row level security;

-- RLS 정책
create policy "본인 일정만" on events for all using (auth.uid() = user_id);
create policy "본인 선행행동만" on pre_actions for all using (auth.uid() = user_id);
create policy "본인 알림만" on reminders for all using (auth.uid() = user_id);
create policy "본인 음성로그만" on voice_logs for all using (auth.uid() = user_id);
create policy "본인 장소기록만" on location_history for all using (auth.uid() = user_id);
create policy "본인 설정만" on user_settings for all using (auth.uid() = user_id);
```

---

## ⚙️ Flutter 패키지

```yaml
dependencies:
  flutter:
    sdk: flutter
  supabase_flutter: ^2.0.0
  speech_to_text: ^6.6.0
  flutter_tts: ^3.8.5
  flutter_local_notifications: ^16.3.0
  android_alarm_manager_plus: ^3.0.3
  flutter_riverpod: ^2.4.9
  go_router: ^13.2.0
  http: ^1.2.0
  flutter_dotenv: ^5.1.0
  home_widget: ^0.4.1
  intl: ^0.19.0
  googleapis: ^12.0.0
  googleapis_auth: ^1.4.1
  google_sign_in: ^6.2.1
  cupertino_icons: ^1.0.6
```

---

## 📁 폴더 구조

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── constants.dart
│   ├── router.dart
│   └── theme.dart
├── data/
│   ├── models/
│   │   ├── event_model.dart
│   │   ├── pre_action_model.dart
│   │   ├── reminder_model.dart
│   │   └── user_settings_model.dart
│   └── repositories/
│       ├── event_repository.dart
│       ├── reminder_repository.dart
│       └── settings_repository.dart
├── services/
│   ├── stt_service.dart
│   ├── gpt_service.dart
│   ├── tts_service.dart
│   ├── notification_service.dart
│   ├── alarm_service.dart
│   └── calendar_sync_service.dart
├── providers/
│   ├── event_provider.dart
│   ├── auth_provider.dart
│   └── settings_provider.dart
└── screens/
    ├── splash/splash_screen.dart
    ├── auth/login_screen.dart
    ├── home/
    │   ├── home_screen.dart
    │   └── widgets/
    │       ├── today_event_card.dart
    │       └── early_bird_banner.dart      ← 얼리버드 배너
    ├── calendar/calendar_screen.dart
    ├── voice/
    │   ├── voice_input_screen.dart
    │   └── confirm_screen.dart
    ├── event/
    │   ├── event_detail_screen.dart
    │   └── event_edit_screen.dart
    └── settings/settings_screen.dart
```

---

## 🔑 환경변수

> ⚠️ 사용자 작업 요청: 아래 값들을 직접 입력해주세요.

```
# .env
SUPABASE_URL=여기에_입력
SUPABASE_ANON_KEY=여기에_입력
OPENAI_API_KEY=여기에_입력
TMAP_API_KEY=여기에_입력
NAVER_MAP_CLIENT_ID=여기에_입력
NAVER_MAP_CLIENT_SECRET=여기에_입력
```

---

## 🎤 핵심 서비스 코드

### STT 서비스 (온디바이스 필수)

```dart
// lib/services/stt_service.dart
class SttService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;

  Future<bool> initialize() async {
    _isInitialized = await _speech.initialize(
      onError: (error) => print('STT 오류: $error'),
    );
    return _isInitialized;
  }

  Future<String> listen() async {
    if (!_isInitialized) await initialize();
    String result = '';
    await _speech.listen(
      onResult: (val) => result = val.recognizedWords,
      localeId: 'ko_KR',
      listenOptions: SpeechListenOptions(
        onDevice: true,        // ★ 필수: 음성 외부 전송 없음
        cancelOnError: true,
        partialResults: false,
      ),
    );
    await Future.delayed(const Duration(seconds: 5));
    await _speech.stop();
    return result;
  }
}
```

### GPT 파싱 서비스

```dart
// lib/services/gpt_service.dart
class GptService {
  final String _apiKey = dotenv.env['OPENAI_API_KEY']!;

  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    final now = DateTime.now();
    final prompt = '''
너는 한국어 음성을 일정 데이터로 변환하는 AI야.
오늘 날짜는 ${now.year}년 ${now.month}월 ${now.day}일이야.

규칙:
1. JSON만 출력. 설명/마크다운 금지.
2. 날짜/시간 없으면 null.
3. 준비물은 배열로.
4. 선행행동 필요하면 pre_actions 배열에 포함.

출력 형식:
{
  "title": "일정 제목",
  "start_at": "2026-05-01T14:00:00",
  "end_at": null,
  "location": "장소명 또는 null",
  "memo": "메모 또는 null",
  "supplies": ["준비물1", "준비물2"],
  "is_critical": false,
  "pre_actions": [
    { "title": "금식 시작", "offset_hours": 12 }
  ]
}

예시1 입력: "내일 오후 2시 JW제약 미팅, 우산이랑 리플릿 챙겨야 해"
예시1 출력:
{"title":"JW제약 미팅","start_at":"2026-05-02T14:00:00","end_at":null,"location":"JW제약","memo":null,"supplies":["우산","리플릿"],"is_critical":false,"pre_actions":[]}

예시2 입력: "모레 오전 8시 위내시경 검사"
예시2 출력:
{"title":"위내시경 검사","start_at":"2026-05-03T08:00:00","end_at":null,"location":null,"memo":null,"supplies":[],"is_critical":true,"pre_actions":[{"title":"금식 시작","offset_hours":12}]}

입력: "$rawText"
''';

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.1,
        'max_tokens': 500,
      }),
    );

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final content = data['choices'][0]['message']['content'] as String;

    try {
      return jsonDecode(content.trim());
    } catch (e) {
      // 파싱 실패 → ConfirmScreen에서 사용자 수동 입력
      return {
        'title': rawText,
        'start_at': null,
        'end_at': null,
        'location': null,
        'memo': rawText,
        'supplies': [],
        'is_critical': false,
        'pre_actions': [],
        'parse_failed': true,
      };
    }
  }

  Future<String> generateBriefing(
    List<Map<String, dynamic>> events,
    String type, // 'morning' | 'evening'
  ) async {
    final eventList = events
        .map((e) => '- ${e['title']} (${e['start_at']})')
        .join('\n');
    final prompt = type == 'morning'
        ? '오늘 일정을 친근하고 간결하게 브리핑해줘 (2-3문장):\n$eventList'
        : '내일 일정을 친근하고 간결하게 미리 브리핑해줘 (2-3문장):\n$eventList';

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.7,
        'max_tokens': 200,
      }),
    );

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['choices'][0]['message']['content'] as String;
  }
}
```

### 알림 서비스

```dart
// lib/services/notification_service.dart
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
  }) async {
    await _plugin.zonedSchedule(
      id, title, body, notifyAt,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'event_reminder', '일정 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
  }) async {
    await _plugin.zonedSchedule(
      id, '🚨 $title', '중요 일정이 30분 후 시작됩니다.', notifyAt,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'critical_alarm', '중요 알람',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          playSound: true,
          enableVibration: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
```

---

## 📱 화면 구현 가이드

### 홈 화면 (home_screen.dart)
```
- 오늘 날짜 + 인사말
- 일정 카드 리스트 (시간순)
  - 준비물 있으면 가방 아이콘
  - 선행행동 있으면 뱃지
  - is_critical이면 빨간 테두리
- 일정 없으면 "오늘은 여유로운 하루예요 😊"
- 하단 고정: "PRO 얼리버드 신청" 배너 (이메일 입력 → early_bird_emails 저장)
- FAB: 마이크 아이콘 (음성 입력 진입)
```

### 음성 입력 화면 (voice_input_screen.dart)

**기본 구조:**
```
- 마이크 버튼 (누르는 동안 녹음 + 애니메이션)
- 인식된 텍스트 누적 표시 (TextField — 손으로 직접 수정 가능)
- SttService.listen() 호출 → committedSegments 배열로 말 조각 누적
- GptService.parseSchedule() 호출
- 로딩 인디케이터
- 결과 → ConfirmScreen으로 push
```

**버튼 구성:**

음성 인식 중:
```
[마지막 말 지우기]  [전체 지우기]  [완료]  [취소]
```

음성 인식 후 / 직접 수정 중:
```
[다시 말하기]  [전체 지우기]  [확인 →]
```

**음성 명령어 처리 (말로도 동일하게 동작):**

STT로 인식된 텍스트에서 아래 키워드 감지 시 GPT 없이 로컬에서 즉시 처리:

| 음성 명령어 | 동작 |
|------------|------|
| "아니", "아니야", "아니요" | 방금 인식된 마지막 단어(1개)만 삭제 |
| "마지막 거 지워", "방금 거 지워" | 마지막 committedSegment 전체 삭제 |
| "다시", "처음부터", "다시 말할게" | 전체 입력 초기화 |
| "취소" | 음성 입력 화면 종료 → 홈으로 이동 |
| "바꿔줘", "수정해줘" | GPT에게 수정 의도로 전달 후 재파싱 |

**구현 방식:**
```dart
// committedSegments 배열로 말 조각 관리
List<String> committedSegments = [];

// 마지막 단어만 삭제 ("아니" 명령어)
void undoLastWord() {
  if (committedSegments.isEmpty) return;
  final lastSegment = committedSegments.last;
  final words = lastSegment.trim().split(' ');
  if (words.length <= 1) {
    committedSegments.removeLast();
  } else {
    words.removeLast();
    committedSegments[committedSegments.length - 1] = words.join(' ');
  }
}

// 마지막 세그먼트 전체 삭제
void undoLastSegment() {
  if (committedSegments.isNotEmpty) {
    committedSegments.removeLast();
  }
}

// 전체 초기화
void clearAll() {
  committedSegments.clear();
}

// 음성 명령어 감지 (GPT 호출 없이 로컬 처리)
void detectVoiceCommand(String text) {
  final t = text.trim();
  if (t == '아니' || t == '아니야' || t == '아니요') {
    undoLastWord();
  } else if (t.contains('마지막 거 지워') || t.contains('방금 거 지워')) {
    undoLastSegment();
  } else if (t == '다시' || t.contains('처음부터') || t.contains('다시 말할게')) {
    clearAll();
  } else if (t == '취소') {
    Navigator.pop(context);
  } else if (t.contains('바꿔줘') || t.contains('수정해줘')) {
    // GPT에 수정 의도로 재전달
    gptService.parseSchedule('수정 요청: ' + t + '\n기존 내용: ' + committedSegments.join(' '));
  } else {
    // 일반 입력 → 세그먼트에 추가
    committedSegments.add(t);
  }
}
```

**UX 원칙:**
- 음성 명령어는 GPT 없이 로컬에서 즉시 처리 (비용 0원, 속도 빠름)
- TextField는 항상 편집 가능하게 유지 (최후 안전장치)
- "아니" 감지는 단독 발화일 때만 적용 (문장 중간의 "아니"는 무시)

### 확인 화면 (confirm_screen.dart)
```
- 제목 (TextField, 수정 가능)
- 날짜/시간 (DateTimePicker)
- 장소 (수정 가능)
- 준비물 (칩 형태, 추가/삭제)
- 선행행동 목록 (자동 생성 + 수동 추가)
- 크리티컬 알람 토글
- 과거 같은 장소 기록 있으면 하단에 조용히 표시:
  "📎 지난 방문 때 준비물: 리플릿, 명함"
- parse_failed: true이면 상단 안내:
  "자동 인식에 실패했어요. 직접 입력해주세요."

저장 시 순서:
1. events 저장
2. pre_actions 저장 (offset_hours → notify_at 역산)
3. reminders 저장
4. location_history 저장
5. voice_logs 저장 (텍스트만, 음성파일 금지)
6. 알림 스케줄 등록
7. 홈으로 이동
```

### 홈 위젯 (home_widget)
```
- 오늘 다음 일정 표시
- 마이크 버튼: 탭하면 앱 실행 + 바로 음성 입력 화면으로 이동
- 일정 목록 간단히 표시
- 무료 사용자도 사용 가능 (전 플랜 제공)
```

---

## 👤 사용자 직접 작업 목록

Codex가 작업 중 아래 항목이 필요한 시점에 사용자에게 명확히 요청할 것:

```
[ ] 1. Supabase 프로젝트 생성
[ ] 2. Supabase SQL Editor에서 위 스키마 SQL 전체 실행
[ ] 3. Supabase Settings → API → URL, anon key 복사 → .env 입력
[ ] 4. OpenAI API Key 발급 → .env 입력
[ ] 5. Google Cloud Console → Calendar API 활성화 → OAuth 클라이언트 ID 발급
[ ] 6. Google Play Console → 앱 등록 (배포 시점)
```

---

## ✅ 구현 체크리스트 (이 순서대로)

```
[ ] 1.  Supabase 프로젝트 생성 + SQL 스키마 실행       → [사용자 작업]
[ ] 2.  .env 파일 생성 + API 키 입력                  → [사용자 작업]
[ ] 3.  Flutter 프로젝트 생성 + 패키지 설치
[ ] 4.  폴더 구조 생성
[ ] 5.  main.dart — Supabase 초기화
[ ] 6.  core/router.dart — 라우팅
[ ] 7.  core/theme.dart — 테마
[ ] 8.  SttService 구현 + 테스트
[ ] 9.  GptService 구현 + 파싱 테스트
[ ] 10. EventRepository — Supabase CRUD
[ ] 11. VoiceInputScreen 구현
[ ] 12. ConfirmScreen 구현
[ ] 13. HomeScreen 구현 + 얼리버드 배너
[ ] 14. CalendarScreen 구현
[ ] 15. EventDetailScreen / EventEditScreen
[ ] 16. NotificationService 구현
[ ] 17. 선행행동 역산 알림 로직
[ ] 18. 이브닝/모닝 브리핑 (TTS + android_alarm_manager_plus)
[ ] 19. 구글 캘린더 양방향 연동 (1차 전 플랜 무료) → [사용자: Google Cloud Console 설정]
[ ] 20. 네이버 캘린더 양방향 연동 (1차 전 플랜 무료) → [사용자: 네이버 개발자센터 설정]
[ ] 21. 이동시간 버퍼 — T맵 API + 네이버 폴백 + MapService 구현
[ ] 22. 홈 위젯 (마이크 버튼 포함)
[ ] 23. SettingsScreen
[ ] 24. 얼리버드 이메일 수집 기능 (early_bird_emails)

--- 2차 개발 ---
[ ] 25. 온보딩 권한 동의 화면 (알림/파일/백그라운드 각각)
[ ] 26. 카톡/문자 감지 서비스 (notification_listener_service)
[ ] 27. 통화 텍스트 파일 감지 서비스 (FileSystemWatcher)
[ ] 28. GPT 통화 텍스트 품질 개선 로직
[ ] 29. 감지 모달 UI (수정 가능 + 원본 보기)
[ ] 30. detection_logs 테이블 추가 + RLS 적용
[ ] 31. 설정 화면에 감지 기능 ON/OFF 토글 추가
```

---

## 🔮 2차 개발 기능 (1차 배포 후 구현)

### 📲 카톡/문자/통화 일정 자동 감지

> 사용자 동의 필수. 온보딩에서 각 권한을 독립적으로 동의 받을 것.

#### 권한 3가지 (각각 독립적으로 ON/OFF)
```
① 알림 접근 권한 → 카톡/문자 감지
② 통화 텍스트 폴더 접근 권한 → 통화 기록 감지
③ 백그라운드 실행 권한 → 앱 꺼져 있어도 감지
```

#### 온보딩 동의 화면 문구
```
"PlanFlow가 카톡/문자/통화에서 일정을 자동으로 찾아드릴 수 있어요.
모든 내용은 기기 안에서만 처리되며 외부 서버로 전송되지 않습니다.
언제든지 설정에서 끌 수 있어요."
```

#### 감지 기준 (AI 판단 조건)
아래 3가지 중 2개 이상 충족 시 일정으로 감지:
```
1. 시간 표현 있음 (내일/다음주/몇시/요일/날짜)
2. 행동 표현 있음 (만나다/미팅/예약/약속/보내다/방문)
3. 미래형 문장
```

감지 O 예시:
```
"내일 오후 2시에 만나자" ← 시간 + 만남
"다음 주 화요일 강남에서 미팅" ← 시간 + 장소
"목요일까지 서류 보내줘" ← 데드라인
"3시에 병원 예약했어" ← 시간 + 장소
```

감지 X 예시:
```
"어제 거기서 만났잖아" ← 과거
"언제 한번 봐야지" ← 막연한 미래
"밥은 먹었어?" ← 일상 대화
```

#### 카톡/문자 처리 흐름
```
Notification Listener API로 알림 수신
        ↓
AI가 감지 기준으로 일정 여부 판단
        ↓
일정 감지 시 앱 알림 발송:
"💬 카톡에서 일정이 감지됐어요. 추가할까요?"
        ↓
탭하면 감지 모달 표시 (수정 후 저장)
```

#### 통화 텍스트 처리 흐름
```
통화 텍스트 파일 새로 생성 감지 (FileSystemWatcher)
        ↓
[1단계] GPT로 품질 개선
  - 오탈자 교정
  - 문맥상 말이 되게 재구성
  - 예: "그러니까 내이 오후 두씨에" → "내일 오후 2시에"
        ↓
[2단계] 일정 키워드 감지 + JSON 추출
        ↓
앱 알림 발송:
"📞 통화 내용에서 일정이 감지됐어요. 추가할까요?"
        ↓
탭하면 감지 모달 표시 (수정 후 저장)
```

#### 감지 모달 UI
```
┌─────────────────────────────────┐
│ 📞 통화에서 일정이 감지됐어요     │
│ ─────────────────────────────── │
│ 제목  [JW제약 미팅            ] │
│ 날짜  [2026-05-02            ] │
│ 시간  [오후 2:00             ] │
│ 장소  [강남역 근처 카페       ] │
│ 메모  [                      ] │
│                                 │
│ 📄 원본 보기 ↓ (탭해서 펼치기)  │
│ "그러니까 내이 오후 두씨에..."   │
│                                 │
│    [건너뛰기]    [저장하기]     │
└─────────────────────────────────┘
```
- 모든 필드 수정 가능
- "원본 보기"는 접었다 펼 수 있게 (GPT 오해석 확인용)
- 건너뛰기 시 해당 감지 무시 (다시 안 뜸)

#### 플랜 배치
| 기능 | FREE | PRO | MASTER |
|------|------|-----|--------|
| 카톡/문자 일정 감지 | 월 2회 | 월 10회 | 무제한 |
| 통화 텍스트 일정 감지 | ❌ | 월 3회 | 무제한 |

#### DB 추가 테이블 (2차 때 스키마 추가)
```sql
-- 감지 로그 (카톡/문자/통화 감지 기록)
create table detection_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  source text not null, -- 'kakao' | 'sms' | 'call'
  raw_text text,        -- 원본 (카톡/문자 내용 또는 통화 텍스트)
  refined_text text,    -- GPT 품질 개선 후 텍스트
  parsed_json jsonb,    -- 추출된 일정 JSON
  event_id uuid references events(id), -- 저장된 경우 연결
  is_saved boolean default false,
  is_skipped boolean default false,
  created_at timestamp default now()
);
```

#### 패키지 추가 (2차 때 pubspec.yaml에 추가)
```yaml
# 알림 접근 (카톡/문자 감지)
notification_listener_service: ^0.0.4

# 파일 시스템 감지 (통화 텍스트 파일)
watcher: ^1.1.0
```

---

## ⚠️ 절대 규칙

1. **agents.md 먼저 읽고 그대로 따를 것** — 코드 작업 전 필수
2. **음성 파일 외부 전송 절대 금지** — 텍스트만 Supabase 저장
3. **onDevice: true 필수** — SpeechListenOptions에 반드시 명시
4. **GPT 파싱 실패 시** parse_failed: true → ConfirmScreen 폴백 UI
5. **Android Doze 모드 대응** — 브리핑은 android_alarm_manager_plus 사용
6. **RLS 필수** — 모든 테이블 Row Level Security 적용
7. **사용자 직접 작업 필요 시** 명확히 안내하고 대기

---

## 🗺️ 이동시간 버퍼 — 지도 API 연동 스펙

### API 선택 전략: T맵 메인 + 네이버 폴백

| API | 용도 | 비용 | 발급처 |
|-----|------|------|--------|
| T맵 API (1순위) | 자동차 이동시간 (실시간 교통 최강) | 무료 (일 1,000건) | SK오픈API |
| 네이버 지도 API (2순위) | T맵 실패 시 폴백 + 대중교통 | 무료 (일정 한도) | 네이버 클라우드 플랫폼 |

> ⚠️ 사용자 작업 요청:
> - SK오픈API (https://openapi.sk.com) → T맵 API 키 발급
> - 네이버 클라우드 플랫폼 → Directions API 키 발급
> - 발급된 키 .env에 추가:
> ```
> TMAP_API_KEY=여기에_입력
> NAVER_MAP_CLIENT_ID=여기에_입력
> NAVER_MAP_CLIENT_SECRET=여기에_입력
> ```

### 처리 흐름

```
일정 장소 입력 (ConfirmScreen)
        ↓
T맵 API로 이동시간 계산 (자동차 기준)
        ↓ 실패 시 자동 폴백
네이버 지도 API로 재시도
        ↓
이동시간 기반 출발 알림 역산
예: 미팅 2시 → 이동 35분 → 1시 20분 "지금 출발하세요" 알림
```

### 이동 수단 설정
- 사용자 설정(user_settings)에서 기본 이동수단 선택 가능
- 자동차 → T맵 우선
- 대중교통 → 네이버 우선 (대중교통 정확도 더 높음)

```sql
-- user_settings 테이블에 컬럼 추가
alter table user_settings
  add column travel_mode text default 'car'; -- 'car' | 'transit'
```

### T맵 API 호출 예시

```dart
// lib/services/map_service.dart

class MapService {
  final String _tmapKey = dotenv.env['TMAP_API_KEY']!;
  final String _naverClientId = dotenv.env['NAVER_MAP_CLIENT_ID']!;
  final String _naverClientSecret = dotenv.env['NAVER_MAP_CLIENT_SECRET']!;

  // 이동시간 계산 (분 단위 반환)
  Future<int?> getTravelMinutes({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    String mode = 'car', // 'car' | 'transit'
  }) async {
    try {
      // 1순위: T맵
      return await _tmapDuration(startLat, startLng, endLat, endLng);
    } catch (e) {
      try {
        // 2순위: 네이버 폴백
        return await _naverDuration(startLat, startLng, endLat, endLng);
      } catch (e) {
        return null; // 둘 다 실패 시 null 반환
      }
    }
  }

  Future<int> _tmapDuration(double sLat, double sLng, double eLat, double eLng) async {
    final response = await http.post(
      Uri.parse('https://apis.openapi.sk.com/tmap/routes?version=1'),
      headers: {
        'appKey': _tmapKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'startX': sLng.toString(),
        'startY': sLat.toString(),
        'endX': eLng.toString(),
        'endY': eLat.toString(),
        'reqCoordType': 'WGS84GEO',
        'resCoordType': 'WGS84GEO',
        'trafficInfo': 'Y', // 실시간 교통 반영
      }),
    );
    final data = jsonDecode(response.body);
    final seconds = data['features'][0]['properties']['totalTime'] as int;
    return (seconds / 60).ceil(); // 분 단위로 변환
  }

  Future<int> _naverDuration(double sLat, double sLng, double eLat, double eLng) async {
    final url = 'https://naveropenapi.apigw.ntruss.com/map-direction/v1/driving'
        '?start=$sLng,$sLat&goal=$eLng,$eLat&option=trafast';
    final response = await http.get(
      Uri.parse(url),
      headers: {
        'X-NCP-APIGW-API-KEY-ID': _naverClientId,
        'X-NCP-APIGW-API-KEY': _naverClientSecret,
      },
    );
    final data = jsonDecode(response.body);
    final ms = data['route']['trafast'][0]['summary']['duration'] as int;
    return (ms / 60000).ceil(); // ms → 분 변환
  }
}
```

### 출발 알림 역산 로직

```dart
// 이동시간 계산 후 출발 알림 자동 생성
Future<void> createTravelReminder(Event event) async {
  if (event.locationLat == null || event.locationLng == null) return;

  final currentLat = await getCurrentLat(); // 현재 위치
  final currentLng = await getCurrentLng();

  final minutes = await mapService.getTravelMinutes(
    startLat: currentLat,
    startLng: currentLng,
    endLat: event.locationLat!,
    endLng: event.locationLng!,
  );

  if (minutes == null) return;

  // 출발 시각 = 일정 시작 - 이동시간 - 여유 10분
  final departAt = event.startAt
      .subtract(Duration(minutes: minutes + 10));

  // pre_actions 테이블에 저장
  await preActionRepository.create(PreAction(
    eventId: event.id,
    userId: event.userId,
    title: '출발 시간이에요 🚗 (이동 약 $minutes분)',
    notifyAt: departAt,
  ));
}
```

### 폴더 구조 추가
```
lib/services/
  └── map_service.dart   ← 신규 추가
```

### pubspec.yaml 추가 패키지
```yaml
# 현재 위치 가져오기 (출발지 계산용)
geolocator: ^11.0.0
```

---

## 📅 캘린더 연동 스펙

### 1차 배포 기준
- 구글 캘린더: **양방향 (읽기+쓰기)** 전 플랜 무료 제공
- 네이버 캘린더: **양방향 (읽기+쓰기)** 전 플랜 무료 제공
- 구독 플랜 없으므로 제한 없음

### 2차 배포 시 변경 (구독 도입 후)
- FREE: 읽기만
- PRO/MASTER: 읽기+쓰기

---

### 구글 캘린더 연동

> ⚠️ 사용자 작업 요청:
> Google Cloud Console → Calendar API 활성화 → OAuth 클라이언트 ID 발급

**사용 패키지:**
```yaml
googleapis: ^12.0.0
googleapis_auth: ^1.4.1
google_sign_in: ^6.2.1
```

**구현 흐름:**
```
구글 로그인 (google_sign_in)
        ↓
OAuth 토큰 획득
        ↓
Calendar API로 일정 읽기/쓰기
        ↓
PlanFlow DB와 양방향 동기화
```

**동기화 규칙:**
- 구글에서 가져온 일정: source = 'google', external_id = 구글 이벤트 ID
- PlanFlow에서 생성한 일정: 구글 캘린더에도 자동 등록
- 구글에서 수정/삭제 시: PlanFlow DB에도 반영 (주기적 폴링 또는 webhook)

```dart
// lib/services/calendar_sync_service.dart

class CalendarSyncService {
  // 구글 캘린더 읽기
  Future<List<Event>> fetchGoogleEvents() async { ... }

  // 구글 캘린더 쓰기
  Future<void> pushToGoogle(Event event) async { ... }

  // 네이버 캘린더 읽기
  Future<List<Event>> fetchNaverEvents() async { ... }

  // 네이버 캘린더 쓰기
  Future<void> pushToNaver(Event event) async { ... }

  // 양방향 동기화 (앱 실행 시 + 주기적으로)
  Future<void> syncAll() async {
    await syncGoogle();
    await syncNaver();
  }
}
```

---

### 네이버 캘린더 연동

> ⚠️ 사용자 작업 요청:
> 네이버 개발자센터 (https://developers.naver.com) → 캘린더 API 애플리케이션 등록 → Client ID/Secret 발급
> .env에 추가:
> ```
> NAVER_CALENDAR_CLIENT_ID=여기에_입력
> NAVER_CALENDAR_CLIENT_SECRET=여기에_입력
> ```

**네이버 캘린더 API 특이사항:**
- REST API 기반 (CalDAV 프로토콜 사용)
- OAuth 2.0 인증 필요
- 공식 Flutter 패키지 없음 → http 패키지로 직접 구현
- 레퍼런스가 적으므로 구현 시 네이버 개발자 문서 꼼꼼히 확인 필요

**인증 흐름:**
```
네이버 OAuth 로그인 (webview_flutter로 OAuth 페이지 열기)
        ↓
인가 코드 획득
        ↓
액세스 토큰 교환
        ↓
CalDAV API로 일정 읽기/쓰기
```

**동기화 규칙:**
- 네이버에서 가져온 일정: source = 'naver', external_id = 네이버 이벤트 ID
- PlanFlow에서 생성한 일정: 네이버 캘린더에도 자동 등록

**추가 패키지:**
```yaml
webview_flutter: ^4.4.0   # 네이버 OAuth 로그인용
```

---

### 동기화 충돌 처리 원칙
- 같은 시간에 양쪽에서 수정된 경우: **최근 수정 시각 기준으로 덮어쓰기**
- PlanFlow에서 추가한 일정이 외부에서 삭제된 경우: PlanFlow에도 삭제 반영
- 동기화 실패 시: 사용자에게 토스트 메시지로 조용히 안내 ("캘린더 동기화에 실패했어요")

---

## 💡 용어 변경 및 UI 가이드

### "선행행동 역산 알림" → "스마트 준비 알람" 으로 전체 변경
앱 내 모든 텍스트, 버튼, 설명에서 "선행행동"/"역산 알림" 표현 제거.
사용자에게 노출되는 모든 곳에서 **"스마트 준비 알람"** 으로 통일.

### ❓ 물음표 버튼 UI
"스마트 준비 알람" 텍스트 옆에 동그라미 물음표 버튼(ℹ️) 추가.
탭하면 바텀시트 또는 툴팁으로 아래 설명 표시:

```
💡 스마트 준비 알람이란?

일정을 등록하면 AI가 자동으로
미리 해야 할 행동을 감지해서
알려드려요.

예시:
• 위내시경 검사 → 전날 저녁 "금식 시작하세요"
• 강남 미팅 → 출발 35분 전 "지금 출발하세요"

말하지 않아도 AI가 알아서 챙겨드려요 😊
```

### 구현 방식
```dart
Row(
  children: [
    Text('스마트 준비 알람', style: ...),
    SizedBox(width: 4),
    GestureDetector(
      onTap: () => showSmartAlarmInfo(context),
      child: Icon(Icons.help_outline_rounded, size: 16, color: Color(0xFF4A6080)),
    ),
  ],
)

void showSmartAlarmInfo(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (_) => SmartAlarmInfoSheet(),
  );
}
```

---

## 📥 네이버 캘린더 ICS 가져오기 스펙

### 배경
네이버 캘린더 API는 사용자가 직접 입력한 일정을 서드파티 앱에서 가져올 수 없음.
가장 안전하고 합법적이며 현실적으로 구현 가능한 방법은
**ICS 파일 내보내기 + receive_sharing_intent로 직접 공유받기** 방식.

### 구현 가능성 검증 (2025 기준)
- ✅ 패키지명으로 네이버 캘린더 앱 직접 실행 가능 (android_intent_plus)
- ✅ file_picker — Android 14/15에서 별도 저장소 권한 없이 동작
- ✅ receive_sharing_intent — 네이버에서 PlanFlow로 ICS 직접 공유 가능
- ✅ ical_parser — ICS 파싱 안정적
- ❌ FileSystemWatcher로 다운로드 폴더 자동 감지 — Android 10+ 권한 문제로 제외
- ❌ 딥링크(naverCalendar://) — 네이버가 공개 스킴 미지원으로 제외

### 최종 흐름 (수동 2번, 나머지 전부 자동)
```
[버튼] "네이버 캘린더 가져오기" 탭
        ↓
[자동] 단계별 가이드 화면 표시
        ↓
[자동] 패키지명으로 네이버 캘린더 앱 직접 실행
        ↓
[수동 1] 네이버에서 내보내기 → "공유" 탭
        ↓
[수동 2] 공유 대상에서 "PlanFlow" 선택
        ↓
[자동] PlanFlow 실행 + ICS 자동 수신 (receive_sharing_intent)
        ↓
[자동] ICS 파싱 + 중복 제거 + DB 저장
        ↓
"총 N개 일정을 가져왔어요 ✅"
```

### 구현 상세

**① 단계별 가이드 UI**
```dart
// assets/naver_guide/ 폴더에 단계별 안내 이미지 포함
PageView(
  children: [
    GuideStep(image: 'assets/naver_guide/step1.png', text: '네이버 캘린더를 열어드릴게요'),
    GuideStep(image: 'assets/naver_guide/step2.png', text: '설정 → 내보내기를 탭해주세요'),
    GuideStep(image: 'assets/naver_guide/step3.png', text: '"공유"를 탭하고 PlanFlow를 선택해주세요'),
  ],
)
```

**② 패키지명으로 네이버 캘린더 앱 직접 실행**
```dart
// android_intent_plus 패키지 사용
Future<void> openNaverCalendar() async {
  const packageName = 'com.nhn.android.calendar';
  final intent = AndroidIntent(
    action: 'android.intent.action.MAIN',
    package: packageName,
    flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
  );
  try {
    await intent.launch();
  } catch (e) {
    // 네이버 캘린더 미설치 시 플레이스토어로 이동
    await launchUrl(
      Uri.parse('market://details?id=$packageName'),
      mode: LaunchMode.externalApplication,
    );
  }
}
```

**③ ICS 공유 받기 (receive_sharing_intent)**
```dart
// main.dart에서 앱 시작 시 등록
// 네이버 캘린더에서 "공유 → PlanFlow" 선택 시 자동 수신
class _AppState extends State<App> {
  late StreamSubscription _intentSub;

  @override
  void initState() {
    super.initState();
    // 앱 실행 중 공유 수신
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen((files) {
      for (final file in files) {
        if (file.path.endsWith('.ics')) {
          importIcsFile(file.path);
        }
      }
    });

    // 앱이 닫혀있을 때 공유로 실행된 경우
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((files) {
      for (final file in files) {
        if (file.path.endsWith('.ics')) {
          importIcsFile(file.path);
        }
      }
    });
  }
}
```

**④ file_picker로 직접 선택 (대안)**
```dart
// 공유 방식이 불편한 사용자를 위한 대안
Future<void> pickIcsFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['ics'],
  );
  if (result != null) {
    await importIcsFile(result.files.single.path!);
  }
}
```

**⑤ ICS 파싱 + 중복 제거**
```dart
Future<void> importIcsFile(String filePath) async {
  final content = await File(filePath).readAsString();
  final events = parseIcs(content); // ical_parser 사용

  int imported = 0;
  for (final event in events) {
    final exists = await eventRepository.checkDuplicate(
      title: event.title,
      startAt: event.startAt,
    );
    if (!exists) {
      await eventRepository.create(event.copyWith(source: 'naver'));
      imported++;
    }
  }
  showSnackBar('총 $imported개 일정을 가져왔어요 ✅');
}
```

**⑥ 매월 재동기화 리마인더**
```dart
await notificationService.scheduleMonthlyReminder(
  title: '네이버 캘린더 업데이트',
  body: '새 일정이 있을 수 있어요. 다시 가져올까요? (30초면 돼요 😊)',
  day: 1,
  time: TimeOfDay(hour: 9, minute: 0),
);
```

### AndroidManifest.xml 설정 (ICS 공유 수신 등록)
```xml
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="text/calendar" />
</intent-filter>
```

### 추가 패키지
```yaml
android_intent_plus: ^4.0.0    # 네이버 캘린더 앱 직접 실행
receive_sharing_intent: ^2.0.0  # ICS 파일 공유 수신
file_picker: ^8.0.0             # ICS 파일 직접 선택 (대안)
ical_parser: ^2.0.0             # ICS 파싱
url_launcher: ^6.2.0            # 플레이스토어 폴백
```

### 앱 내 안내 문구
```
📅 네이버 캘린더 가져오기

직접 입력한 일정도 한 번에 가져올 수 있어요.
딱 2번만 탭하면 끝이에요.

소요시간: 약 30초
이후 매월 업데이트 알림 제공

[네이버 캘린더 열기 →]
```

### 체크리스트
```
[ ] 단계별 가이드 UI (PageView + 안내 이미지)
[ ] android_intent_plus로 네이버 캘린더 앱 직접 실행
[ ] receive_sharing_intent 등록 (AndroidManifest + main.dart)
[ ] file_picker ICS 직접 선택 (대안 버튼)
[ ] ICS 파싱 + 중복 제거 로직
[ ] 매월 1일 재동기화 리마인더
```
