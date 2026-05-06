# PlanFlow — 네이버 캘린더 CalDAV 연동
## Codex 구현 프롬프트 v1.0

---

## 🧭 Codex에게

```
PlanFlow 앱에 네이버 캘린더 CalDAV 연동을 구현해야 해.
CalDAV는 캘린더 전용 동기화 프로토콜이야.
네이버는 공식적으로 CalDAV를 지원하고 있어.

아래 순서대로 정확히 구현해줘.
확신이 없으면 멈추고 확인 요청할 것.
```

---

## 📋 사전 지식 (Codex가 알아야 할 것)

### 네이버 CalDAV 서버 정보 (고정값, 변경 금지)
```
서버 URL: https://caldav.calendar.naver.com
인증 방식: Basic Auth (아이디 + 앱 비밀번호)
```

### 앱 비밀번호란?
네이버는 2단계 인증 활성화 시 일반 비밀번호 대신
앱 전용 비밀번호를 사용해야 CalDAV 연결이 됨.
- 발급 경로: 네이버 로그인 → 보안설정 → 2단계 인증 → 앱 비밀번호 관리
- 사용자가 앱 내에서 이 발급 방법을 안내받아야 함

### CalDAV 기본 동작 원리
```
1. PROPFIND 요청 → 캘린더 목록 조회
2. REPORT 요청  → 캘린더 내 이벤트 목록 조회
3. GET 요청     → 개별 이벤트 .ics 파일 다운로드
4. PUT 요청     → 이벤트 생성/수정
5. DELETE 요청  → 이벤트 삭제

모든 요청은 HTTP Basic Auth 헤더 포함:
Authorization: Basic base64(아이디:앱비밀번호)
```

### iCalendar(.ics) 파싱 핵심
```
BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:회의            → title
DTSTART:20260501T140000Z → start_at
DTEND:20260501T150000Z   → end_at
LOCATION:강남역          → location
DESCRIPTION:내용         → description
UID:unique-id@naver.com  → naver_event_id
END:VEVENT
END:VCALENDAR
```

---

## 📦 필요한 패키지

`pubspec.yaml`에 추가:

```yaml
dependencies:
  http: ^1.2.0              # HTTP 요청 (이미 있을 것)
  xml: ^6.5.0               # XML 파싱 (PROPFIND/REPORT 응답)
  convert: ^3.1.1           # Base64 인코딩 (Basic Auth)
  flutter_secure_storage: ^9.0.0  # 자격증명 안전 저장
  flutter_dotenv: ^5.2.1    # 환경변수 (이미 있을 것)
```

> ⚠️ caldav_client 패키지는 업데이트가 오래됐으므로 사용하지 말 것.
> HTTP 직접 호출로 구현할 것.

---

## STEP 1: DB 스키마 추가

Supabase SQL Editor에서 실행:

```sql
-- 네이버 CalDAV 연결 정보 저장
-- (자격증명은 Flutter Secure Storage에 저장, DB에는 저장 금지)
ALTER TABLE user_settings
  ADD COLUMN IF NOT EXISTS naver_caldav_connected BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS naver_caldav_last_synced_at TIMESTAMP NULL,
  ADD COLUMN IF NOT EXISTS naver_caldav_sync_token TEXT NULL; -- 변경 감지용

-- 네이버 캘린더 이벤트 저장 컬럼 추가 (events 테이블 확장)
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS naver_uid TEXT NULL,       -- 네이버 이벤트 고유 ID
  ADD COLUMN IF NOT EXISTS naver_etag TEXT NULL,      -- 변경 감지용 ETag
  ADD COLUMN IF NOT EXISTS sync_source TEXT DEFAULT 'app'; -- 'app' | 'naver'

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_events_naver_uid ON events(naver_uid);
```

---

## STEP 2: NaverCalDavService 구현

`lib/services/naver_caldav_service.dart` 생성:

```dart
// 아래 요구사항으로 NaverCalDavService 클래스를 구현해줘.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xml/xml.dart';

// == 클래스 구조 ==
class NaverCalDavService {
  static const _baseUrl = 'https://caldav.calendar.naver.com';
  static const _storage = FlutterSecureStorage();
  static const _idKey = 'naver_caldav_id';
  static const _pwKey = 'naver_caldav_pw';

  // 1. 자격증명 저장 (Flutter Secure Storage 사용)
  Future<void> saveCredentials(String naverId, String appPassword);

  // 2. 자격증명 삭제 (연동 해제)
  Future<void> clearCredentials();

  // 3. 연결 테스트 (저장 전에 먼저 확인)
  // → PROPFIND 요청으로 캘린더 목록 조회 시도
  // → 성공: true, 실패(401/네트워크오류): false
  Future<bool> testConnection(String naverId, String appPassword);

  // 4. 캘린더 목록 조회
  // → PROPFIND /calendars/[네이버ID]/ Depth:1
  Future<List<NaverCalendar>> getCalendars();

  // 5. 이벤트 목록 조회 (특정 기간)
  // → REPORT /calendars/[네이버ID]/[캘린더경로]/
  // → 기간: 3개월 전 ~ 6개월 후
  Future<List<NaverEvent>> getEvents({
    required String calendarPath,
    required DateTime from,
    required DateTime to,
  });

  // 6. 전체 동기화 (모든 캘린더 → Supabase events 테이블)
  Future<SyncResult> syncAll();

  // 내부: Basic Auth 헤더 생성
  Map<String, String> _authHeaders(String id, String pw) {
    final encoded = base64Encode(utf8.encode('$id:$pw'));
    return {
      'Authorization': 'Basic $encoded',
      'Content-Type': 'application/xml; charset=utf-8',
      'Depth': '1',
    };
  }
}

// == 모델 ==
class NaverCalendar {
  final String path;         // /calendars/[id]/[캘린더명]/
  final String displayName;  // 캘린더 이름
  final String ctag;         // 변경 감지용
}

class NaverEvent {
  final String uid;          // 네이버 고유 ID
  final String etag;         // 변경 감지용
  final String icsData;      // 전체 iCal 데이터
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String? location;
  final String? description;
  final bool isAllDay;
}

class SyncResult {
  final bool success;
  final int created;
  final int updated;
  final int skipped;
  final String? errorMessage;
}
```

### PROPFIND 요청 예시 (캘린더 목록)

```xml
<!-- 이 XML을 PROPFIND 요청 body로 사용 -->
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop>
    <d:displayname />
    <cs:getctag />
    <d:resourcetype />
  </d:prop>
</d:propfind>
```

```dart
// PROPFIND 요청 방법
final response = await http.Request(
  'PROPFIND',
  Uri.parse('$_baseUrl/calendars/$naverId/'),
)
  ..headers.addAll(_authHeaders(id, pw))
  ..body = propfindXml;

final streamedResponse = await response.send();
final responseBody = await streamedResponse.stream.bytesToString();
// → XML 파싱하여 캘린더 목록 추출
```

### REPORT 요청 예시 (이벤트 목록)

```xml
<!-- 이 XML을 REPORT 요청 body로 사용 -->
<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="20260201T000000Z" end="20261101T000000Z"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>
```

```dart
// REPORT 요청 방법
final response = await http.Request(
  'REPORT',
  Uri.parse('$_baseUrl$calendarPath'),
)
  ..headers.addAll({
    ..._authHeaders(id, pw),
    'Depth': '1',
  })
  ..body = reportXml;
```

### iCalendar 파싱 함수

```dart
// iCal 텍스트에서 NaverEvent 추출
NaverEvent? parseIcal(String icsData, String etag) {
  // VEVENT 블록 추출
  // SUMMARY, DTSTART, DTEND, LOCATION, DESCRIPTION, UID 파싱
  // DTSTART;TZID=Asia/Seoul:20260501T140000 형태 처리
  // DTSTART:20260501 (날짜만) → isAllDay = true
  // 타임존 처리: +09:00 (KST) 기준
}
```

---

## STEP 3: 동기화 로직

`lib/services/naver_caldav_service.dart`의 `syncAll()` 구현:

```dart
// syncAll() 내부 로직
Future<SyncResult> syncAll() async {
  // 1. 자격증명 로드
  final id = await _storage.read(key: _idKey);
  final pw = await _storage.read(key: _pwKey);
  if (id == null || pw == null) return SyncResult(success: false, ...);

  // 2. 캘린더 목록 조회
  final calendars = await getCalendars();

  // 3. 각 캘린더의 이벤트 조회
  for (final calendar in calendars) {
    final events = await getEvents(
      calendarPath: calendar.path,
      from: DateTime.now().subtract(Duration(days: 90)),
      to: DateTime.now().add(Duration(days: 180)),
    );

    // 4. Supabase events 테이블과 비교 후 upsert
    for (final event in events) {
      // naver_uid로 기존 이벤트 확인
      // etag 동일하면 skip (변경 없음)
      // 다르면 update
      // 없으면 insert
    }
  }

  // 5. last_synced_at 업데이트
}
```

---

## STEP 4: 설정 화면 UI

`lib/screens/settings/settings_screen.dart`에 추가:

```
== UI 요구사항 ==

[네이버 캘린더 연동] 섹션:

연결 안 된 상태:
  - "네이버 캘린더 연동" 타이틀
  - "네이버 일정을 PlanFlow로 가져옵니다" 설명
  - [연동하기] 버튼 → 자격증명 입력 다이얼로그 표시

연결된 상태:
  - "네이버 캘린더 연동됨 ✓" 표시
  - "마지막 동기화: 2026-05-01 14:30" 표시
  - [지금 동기화] 버튼
  - [연동 해제] 버튼 (텍스트 버튼, 눈에 덜 띄게)

자격증명 입력 다이얼로그:
  - 네이버 아이디 입력 필드
  - 앱 비밀번호 입력 필드 (obscureText: true)
  - "앱 비밀번호 발급 방법" 안내 링크
    → 웹뷰로 네이버 보안설정 페이지 열기
    → URL: https://nid.naver.com/user2/help/myInfo
  - [취소] [연결 확인] 버튼
  - 연결 확인 버튼 누르면: testConnection() 호출
    → 성공: 자격증명 저장 + 첫 동기화 실행
    → 실패: "아이디 또는 앱 비밀번호를 확인해주세요" 에러 메시지
```

---

## STEP 5: 백그라운드 자동 동기화

`lib/services/naver_caldav_service.dart`에 추가:

```dart
// 앱 시작 시 + 포그라운드 전환 시 자동 동기화
// android_alarm_manager_plus로 주기적 동기화 (1시간마다)

// lib/main.dart에서 초기화:
// 1. 앱 시작 시 naverCalDavService.syncAll() 호출
// 2. AppLifecycleState.resumed 시 syncAll() 호출
// 3. 1시간마다 백그라운드 syncAll() 예약
```

---

## ⚠️ 주의사항 (반드시 지킬 것)

```
1. 자격증명 보안
   - 네이버 아이디, 앱 비밀번호는 FlutterSecureStorage에만 저장
   - Supabase DB에 절대 저장 금지
   - 로그에 자격증명 출력 금지

2. 에러 처리
   - 401: "앱 비밀번호를 확인해주세요" 안내
   - 네트워크 오류: "네트워크 연결을 확인해주세요" 안내
   - 모든 예외는 throw하지 말고 SyncResult.success=false로 반환

3. 타임존
   - 네이버 CalDAV는 KST(+09:00) 기준
   - Supabase 저장 시 UTC로 변환할 것
   - DateTime.parse() 후 toUtc() 적용

4. 중복 방지
   - naver_uid 기준으로 중복 확인
   - etag 동일하면 반드시 skip (불필요한 업데이트 방지)

5. 네이버 2단계 인증
   - 일반 비밀번호로는 CalDAV 연결 불가
   - 반드시 앱 비밀번호 사용 안내 필요
   - 2단계 인증 미설정 사용자: 일반 비밀번호로도 가능
     (하지만 앱 비밀번호 사용 권장 안내)
```

---

## 📊 구현 체크리스트

```
□ STEP 1: Supabase SQL 실행 (스키마 추가)
□ STEP 2: NaverCalDavService 구현
  □ saveCredentials() — 자격증명 저장
  □ testConnection()  — 연결 테스트
  □ getCalendars()    — PROPFIND 캘린더 목록
  □ getEvents()       — REPORT 이벤트 조회
  □ iCal 파싱         — parseIcal()
□ STEP 3: syncAll() — Supabase 동기화
□ STEP 4: 설정 화면 UI
  □ 연결/해제 상태 표시
  □ 자격증명 입력 다이얼로그
  □ 앱 비밀번호 발급 안내 링크
□ STEP 5: 백그라운드 자동 동기화
□ 실기기 테스트:
  □ 올바른 앱 비밀번호로 연결 성공 확인
  □ 잘못된 비밀번호로 에러 메시지 확인
  □ 네이버 캘린더 일정이 PlanFlow events 테이블에 저장되는지 확인
  □ 네이버에서 일정 수정 후 동기화 시 반영 확인
  □ 앱 재시작 후 자동 동기화 확인
```

---

## 🙋 사용자 온보딩 안내 문구

설정 화면에서 사용자에게 보여줄 안내:

```
네이버 캘린더 연동 방법

1. 네이버 보안설정에서 앱 비밀번호를 발급하세요
   (2단계 인증 설정이 필요합니다)

2. 아래에 네이버 아이디와 앱 비밀번호를 입력하세요

3. 연동 후 네이버 일정이 자동으로 가져와집니다

※ 일반 로그인 비밀번호가 아닌 앱 비밀번호를 입력해야 합니다
※ 앱 비밀번호는 PlanFlow 앱에서만 사용되며 외부에 전송되지 않습니다
```
