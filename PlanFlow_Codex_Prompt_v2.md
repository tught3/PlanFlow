# PlanFlow — Codex 초기 세팅 & 구현 프롬프트 v2

---

## 🧭 Codex에게 전달할 컨텍스트

```
너는 PlanFlow라는 AI 음성 기반 지능형 스케줄러 앱을 처음부터 만들어야 해.
아무것도 없는 상태에서 시작하니까, 환경 세팅부터 코드 구현까지 순서대로 진행해줘.
중간에 판단이 필요한 부분은 멈추지 말고 아래 스펙 기준으로 결정해서 진행해.

⚠️ 코드를 구현하거나 수정하기 전에 반드시 agents.md를 먼저 읽고, 그 내용을 그대로 따라서 진행해. agents.md에 명시된 규칙이 최우선이야.
```

---

## 📱 앱 스펙 요약

- **앱 이름**: PlanFlow
- **플랫폼**: Android 우선 (iOS는 추후)
- **언어/프레임워크**: Flutter (Dart)
- **백엔드**: Supabase (PostgreSQL + Auth + Realtime)
- **AI 파싱**: OpenAI GPT-4o-mini API
- **STT**: 온디바이스 STT (speech_to_text 패키지, onDevice: true 필수)
- **TTS**: flutter_tts (모닝/이브닝 브리핑용)
- **음성 데이터 보안 원칙**: 음성 파일은 절대 외부 서버로 전송하지 않는다. STT 변환된 텍스트만 Supabase로 전송. 음성 원본은 기기 로컬에만 보관.

---

## 🏗️ 기술 스택 선택 이유

| 항목 | 선택 | 이유 |
|------|------|------|
| 프레임워크 | Flutter | Android 성능 최적, 시스템 알람/위젯 권한 제어 용이 |
| 백엔드 | Supabase | Auth + DB + Realtime 통합, 무료 티어로 MVP 충분, 배포 후 가성비 최고 |
| AI 파싱 | GPT-4o-mini | 속도 빠르고 저비용, 한국어 비정형 텍스트 구조화에 최적 |
| STT | 온디바이스 | 음성 데이터 외부 유출 없음, 비용 0원 |
| TTS | flutter_tts | 무료, 온디바이스, 브리핑에 충분한 품질 |
| 배포 | Google Play Store | Android 우선 전략 |

---

## 👤 사용자에게 요청할 작업 목록

> Codex야, 아래 항목들은 네가 직접 할 수 없고 사용자가 직접 해야 하는 작업이야.
> 각 단계에서 해당 작업이 필요한 시점에 사용자에게 명확하게 요청해줘.
> 모든 자동화 가능한 코드 작업을 먼저 완료한 후, 마지막에 사용자 작업 목록을 한꺼번에 안내해도 돼.

```
[사용자 직접 작업 목록]

1. Supabase 대시보드 → SQL Editor → 아래 STEP 1의 SQL 전체 실행
2. Supabase 대시보드 → Authentication → Providers → Google 로그인 활성화
3. Supabase 대시보드 → Settings → API → URL과 anon key 복사 → .env에 입력
4. OpenAI 플랫폼 → API Keys → 새 키 발급 → .env에 입력
5. Google Cloud Console → 프로젝트 생성 → Google Calendar API 활성화 → OAuth 클라이언트 ID 발급
6. Google Play Console → 앱 등록 (배포 시점)
```

---

## 🗄️ STEP 1 — Supabase DB 스키마

> ⚠️ 사용자에게 요청: Supabase 대시보드 → SQL Editor에서 아래 SQL 전체를 실행해주세요.

```sql
-- 1. users (Supabase Auth와 연동)
create table users (
  id uuid primary key references auth.users(id),
  email text,
  name text,
  created_at timestamp default now()
);

-- 2. events (핵심 일정 테이블)
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

-- 4. reminders (알림 스케줄)
create table reminders (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references events(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  type text not null, -- 'push' | 'system_alarm' | 'evening' | 'morning'
  notify_at timestamp not null,
  is_sent boolean default false,
  created_at timestamp default now()
);

-- 5. voice_logs (STT 텍스트만 저장, 음성파일 절대 저장 금지)
create table voice_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  raw_text text,
  parsed_json jsonb,
  event_id uuid references events(id),
  created_at timestamp default now()
);

-- 6. location_history (장소별 과거 준비물 참고용)
create table location_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  location text,
  supplies text[],
  event_id uuid references events(id),
  visited_at timestamp default now()
);

-- 7. user_settings (사용자 설정)
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

-- RLS 활성화
alter table events enable row level security;
alter table pre_actions enable row level security;
alter table reminders enable row level security;
alter table voice_logs enable row level security;
alter table location_history enable row level security;
alter table user_settings enable row level security;

-- RLS 정책 (본인 데이터만 접근)
create policy "본인 일정만" on events for all using (auth.uid() = user_id);
create policy "본인 선행행동만" on pre_actions for all using (auth.uid() = user_id);
create policy "본인 알림만" on reminders for all using (auth.uid() = user_id);
create policy "본인 음성로그만" on voice_logs for all using (auth.uid() = user_id);
create policy "본인 장소기록만" on location_history for all using (auth.uid() = user_id);
create policy "본인 설정만" on user_settings for all using (auth.uid() = user_id);
```

---

## ⚙️ STEP 2 — Flutter 프로젝트 생성 및 패키지 설치

```bash
flutter create planflow
cd planflow
```

```yaml
# pubspec.yaml dependencies
dependencies:
  flutter:
    sdk: flutter

  # Supabase
  supabase_flutter: ^2.0.0

  # 온디바이스 STT (음성 외부 전송 없음)
  speech_to_text: ^6.6.0

  # TTS (모닝/이브닝 브리핑)
  flutter_tts: ^3.8.5

  # 로컬 푸시 알림
  flutter_local_notifications: ^16.3.0

  # 시스템 알람 연동 (Android AlarmManager)
  android_alarm_manager_plus: ^3.0.3

  # 상태관리
  flutter_riverpod: ^2.4.9

  # 라우팅
  go_router: ^13.2.0

  # HTTP (GPT API 호출)
  http: ^1.2.0

  # 환경변수
  flutter_dotenv: ^5.1.0

  # 홈 위젯
  home_widget: ^0.4.1

  # 날짜 포맷
  intl: ^0.19.0

  # 구글 캘린더 연동
  googleapis: ^12.0.0
  googleapis_auth: ^1.4.1
  google_sign_in: ^6.2.1

  cupertino_icons: ^1.0.6
```

---

## 📁 STEP 3 — 폴더 구조

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
│   ├── stt_service.dart            # 온디바이스 STT
│   ├── gpt_service.dart            # GPT-4o-mini 파싱 + 브리핑
│   ├── tts_service.dart            # TTS 브리핑 재생
│   ├── notification_service.dart   # 푸시 알림
│   ├── alarm_service.dart          # 시스템 알람
│   └── calendar_sync_service.dart  # 구글/네이버 캘린더 연동
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
    │       └── briefing_banner.dart
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

## 🔑 STEP 4 — 환경변수 설정

```
# .env (루트 디렉토리)
SUPABASE_URL=여기에_입력
SUPABASE_ANON_KEY=여기에_입력
OPENAI_API_KEY=여기에_입력
```

```dart
// main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const ProviderScope(child: PlanFlowApp()));
}
```

---

## 🎤 STEP 5 — 핵심 서비스 구현

### 5-1. STT 서비스 (온디바이스, 음성 외부 전송 절대 금지)

```dart
// lib/services/stt_service.dart
import 'package:speech_to_text/speech_to_text.dart';

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
        onDevice: true,       // ★ 필수: 음성이 외부로 절대 나가지 않음
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

---

### 5-2. GPT 파싱 서비스

```dart
// lib/services/gpt_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GptService {
  final String _apiKey = dotenv.env['OPENAI_API_KEY']!;

  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    final now = DateTime.now();
    final prompt = '''
너는 한국어 음성을 일정 데이터로 변환하는 AI야.
오늘 날짜는 ${now.year}년 ${now.month}월 ${now.day}일이야.

규칙:
1. 결과는 반드시 JSON만 출력. 설명이나 마크다운 불필요.
2. 날짜/시간 없으면 null.
3. 준비물은 배열로.
4. 선행행동이 필요하면(금식, 이동 준비 등) pre_actions 배열에 포함.

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
{
  "title": "JW제약 미팅",
  "start_at": "${now.year}-${now.month.toString().padLeft(2,'0')}-${(now.day+1).toString().padLeft(2,'0')}T14:00:00",
  "end_at": null,
  "location": "JW제약",
  "memo": null,
  "supplies": ["우산", "리플릿"],
  "is_critical": false,
  "pre_actions": []
}

예시2 입력: "모레 오전 8시 위내시경 검사"
예시2 출력:
{
  "title": "위내시경 검사",
  "start_at": "${now.year}-${now.month.toString().padLeft(2,'0')}-${(now.day+2).toString().padLeft(2,'0')}T08:00:00",
  "end_at": null,
  "location": null,
  "memo": null,
  "supplies": [],
  "is_critical": true,
  "pre_actions": [
    { "title": "금식 시작", "offset_hours": 12 }
  ]
}

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
      // 파싱 실패 → 폴백: 사용자가 ConfirmScreen에서 수동 입력
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

  // 모닝/이브닝 브리핑 텍스트 생성
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

---

### 5-3. 알림 서비스

```dart
// lib/services/notification_service.dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

  // 일반 푸시 알림 (기본 1시간 전)
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
  }) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      notifyAt,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'event_reminder',
          '일정 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // 크리티컬 알람 (시스템 알람 수준, 무음모드에서도 울림)
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
  }) async {
    await _plugin.zonedSchedule(
      id,
      '🚨 $title',
      '중요 일정이 30분 후 시작됩니다.',
      notifyAt,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'critical_alarm',
          '중요 알람',
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

## 📱 STEP 6 — 핵심 화면 구현 가이드

### 음성 입력 화면 (voice_input_screen.dart)
```
구현 순서:
1. 마이크 버튼 UI (누르는 동안 녹음, 애니메이션)
2. SttService.listen() 호출
3. 텍스트 획득 후 GptService.parseSchedule() 호출
4. 로딩 인디케이터 표시
5. 결과를 ConfirmScreen으로 push
```

### 확인 화면 (confirm_screen.dart)
```
표시 항목:
- 제목 (수정 가능 TextField)
- 날짜/시간 (DateTimePicker)
- 장소 (수정 가능)
- 준비물 (칩 형태, 추가/삭제 가능)
- 선행행동 목록 (자동 생성된 것 표시 + 수동 추가 가능)
- 크리티컬 알람 토글 스위치
- 과거 같은 장소 방문 기록 있으면 하단에 조용히 표시:
  "📎 지난 JW제약 방문 때 준비물: 리플릿, 명함"
- parse_failed: true이면 상단에 "자동 인식에 실패했어요. 직접 입력해주세요" 안내

저장 버튼 클릭 시 순서:
1. events 테이블 저장
2. pre_actions 저장 (선행행동 역산 notify_at 계산 후)
3. reminders 저장
4. location_history 저장 (장소 + 준비물)
5. voice_logs 저장 (raw_text + parsed_json만, 음성파일 저장 금지)
6. NotificationService로 알림 스케줄 등록
7. 홈으로 이동
```

### 홈 화면 (home_screen.dart)
```
표시 항목:
- 상단: 오늘 날짜 + 인사말
- 일정 카드 리스트 (시간순 정렬)
  - 준비물 있으면 가방 아이콘 표시
  - 선행행동 있으면 별도 뱃지 표시
  - is_critical 일정은 카드 색상 강조 (빨간 테두리)
- 일정 없으면 "오늘은 여유로운 하루예요 😊" 표시
- 하단 FAB: 마이크 아이콘 (음성 입력 진입점)
```

---

## ✅ 구현 체크리스트 (이 순서대로 진행)

```
[ ] 1.  Supabase 프로젝트 생성 + SQL 스키마 실행 → [사용자 작업 요청]
[ ] 2.  .env 파일 생성 + API 키 입력 → [사용자 작업 요청]
[ ] 3.  Flutter 프로젝트 생성 + 패키지 설치
[ ] 4.  폴더 구조 생성
[ ] 5.  main.dart — Supabase 초기화
[ ] 6.  core/router.dart — 라우팅 설정
[ ] 7.  core/theme.dart — 앱 테마
[ ] 8.  SttService 구현 + 단독 테스트
[ ] 9.  GptService 구현 + 파싱 테스트
[ ] 10. EventRepository — Supabase CRUD
[ ] 11. VoiceInputScreen 구현
[ ] 12. ConfirmScreen 구현
[ ] 13. HomeScreen 구현
[ ] 14. CalendarScreen 구현
[ ] 15. EventDetailScreen / EventEditScreen 구현
[ ] 16. NotificationService 구현
[ ] 17. 선행행동 역산 알림 로직 (offset_hours → notify_at 계산)
[ ] 18. 이브닝/모닝 브리핑 (TTS + android_alarm_manager_plus)
[ ] 19. 구글 캘린더 양방향 연동 → [사용자: Google Cloud Console 설정 요청]
[ ] 20. 네이버 캘린더 연동
[ ] 21. 이동시간 버퍼 (지도 API 연동)
[ ] 22. 홈 위젯
[ ] 23. SettingsScreen 구현
```

---

## ⚠️ 절대 규칙 (agents.md와 함께 최우선 준수)

1. **코드 구현/수정 전 agents.md 반드시 먼저 읽고 그대로 따를 것**
2. **음성 파일은 절대 서버로 전송하지 않는다** — STT 텍스트만 Supabase 저장
3. **onDevice: true 필수** — SpeechListenOptions에 반드시 명시
4. **GPT 파싱 실패 시** parse_failed: true 반환 → ConfirmScreen 폴백 UI 표시
5. **Android Doze 모드 대응** — 아침 브리핑은 android_alarm_manager_plus로 처리
6. **RLS 필수** — 모든 Supabase 테이블에 Row Level Security 적용
7. **사용자 직접 작업이 필요한 시점에는 명확하게 안내하고 대기할 것**
