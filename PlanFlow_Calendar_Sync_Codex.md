# PlanFlow — 네이버 ↔ 구글 캘린더 동기화
## Codex 구현 프롬프트 v1.0

---

## 🧭 Codex에게

```
PlanFlow 앱에 네이버 캘린더 ↔ 구글 캘린더 양방향 동기화를 구현해야 해.
아래 순서대로 정확히 진행해줘. 확신이 없으면 멈추고 확인 요청할 것.

전체 구조:
- Android Flutter 앱: OAuth 토큰 획득 + 동기화 트리거
- Supabase: DB 중앙 저장소 + Edge Function 동기화 로직 + Cron 스케줄러
- 외부 API: 네이버 Calendar API, 구글 Calendar API
```

---

## 📋 전제 조건 (사용자 직접 준비)

아래는 Codex가 아닌 사용자가 직접 준비해야 하는 항목:

```
□ 네이버 개발자센터 (https://developers.naver.com)
  → 애플리케이션 등록 → 캘린더 API 권한 신청
  → Client ID, Client Secret 발급
  → Callback URL 등록: planflow://naver-callback

□ Google Cloud Console (https://console.cloud.google.com)
  → Calendar API 활성화
  → OAuth 2.0 클라이언트 ID 생성 (Android 앱 타입)
  → 패키지명, SHA-1 fingerprint 등록

□ Supabase 대시보드
  → Edge Functions 활성화 확인
  → Cron 확장 활성화: pg_cron (Database → Extensions → pg_cron)

□ 환경변수 (.env에 추가)
  NAVER_CLIENT_ID=발급받은값
  NAVER_CLIENT_SECRET=발급받은값
```

---

## STEP 1: DB 스키마 추가

Supabase SQL Editor에서 실행:

```sql
-- 1. 사용자 토큰 저장 테이블
CREATE TABLE IF NOT EXISTS calendar_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,                    -- 'naver' | 'google'
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  expires_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(user_id, provider)
);

-- 2. 중앙 캘린더 이벤트 저장소
CREATE TABLE IF NOT EXISTS calendar_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  start_at TIMESTAMP NOT NULL,
  end_at TIMESTAMP,
  location TEXT,
  is_all_day BOOLEAN DEFAULT FALSE,

  -- 각 플랫폼의 이벤트 ID (없으면 아직 미동기화)
  naver_event_id TEXT,
  google_event_id TEXT,

  -- 동기화 메타데이터
  source TEXT NOT NULL DEFAULT 'app',        -- 'naver' | 'google' | 'app'
  hash TEXT NOT NULL,                        -- 변경 감지용 sha256
  last_synced_at TIMESTAMP,
  sync_status TEXT DEFAULT 'pending',        -- 'pending' | 'synced' | 'error'
  sync_error TEXT,                           -- 에러 메시지 보존

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 3. 동기화 로그 (디버깅용)
CREATE TABLE IF NOT EXISTS calendar_sync_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  direction TEXT NOT NULL,                   -- 'naver_to_db' | 'db_to_google' | 'google_to_db'
  status TEXT NOT NULL,                      -- 'success' | 'error'
  events_processed INT DEFAULT 0,
  events_created INT DEFAULT 0,
  events_updated INT DEFAULT 0,
  error_message TEXT,
  executed_at TIMESTAMP DEFAULT NOW()
);

-- 4. 인덱스
CREATE INDEX IF NOT EXISTS idx_calendar_events_user_id ON calendar_events(user_id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_hash ON calendar_events(hash);
CREATE INDEX IF NOT EXISTS idx_calendar_events_naver_id ON calendar_events(naver_event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_google_id ON calendar_events(google_event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_sync_status ON calendar_events(sync_status);

-- 5. RLS
ALTER TABLE calendar_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_sync_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "본인 토큰만" ON calendar_tokens FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "본인 이벤트만" ON calendar_events FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "본인 로그만" ON calendar_sync_logs FOR ALL USING (auth.uid() = user_id);

-- 6. hash 계산 함수
CREATE OR REPLACE FUNCTION calc_event_hash(
  p_title TEXT,
  p_start_at TIMESTAMP,
  p_end_at TIMESTAMP,
  p_location TEXT,
  p_description TEXT
) RETURNS TEXT AS $$
BEGIN
  RETURN encode(
    sha256(
      (COALESCE(p_title,'') ||
       COALESCE(p_start_at::TEXT,'') ||
       COALESCE(p_end_at::TEXT,'') ||
       COALESCE(p_location,'') ||
       COALESCE(p_description,''))::bytea
    ),
    'hex'
  );
END;
$$ LANGUAGE plpgsql;
```

---

## STEP 2: Supabase Edge Function — naver-poll-events

`supabase/functions/naver-poll-events/index.ts` 생성:

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    // 동기화할 사용자 목록 (네이버 토큰 있는 사용자)
    const { data: tokens, error: tokenError } = await supabase
      .from("calendar_tokens")
      .select("user_id, access_token, refresh_token, expires_at")
      .eq("provider", "naver");

    if (tokenError) throw tokenError;
    if (!tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ message: "동기화할 사용자 없음" }), { status: 200 });
    }

    const results = [];

    for (const tokenRow of tokens) {
      try {
        const result = await syncNaverForUser(supabase, tokenRow);
        results.push({ user_id: tokenRow.user_id, ...result });
      } catch (err) {
        // 한 사용자 실패해도 다음 사용자 계속 처리
        results.push({ user_id: tokenRow.user_id, status: "error", error: err.message });

        await supabase.from("calendar_sync_logs").insert({
          user_id: tokenRow.user_id,
          direction: "naver_to_db",
          status: "error",
          error_message: err.message,
        });
      }
    }

    return new Response(JSON.stringify({ results }), { status: 200 });

  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});

async function syncNaverForUser(supabase: any, tokenRow: any) {
  // 토큰 만료 확인 및 갱신
  let accessToken = tokenRow.access_token;
  if (tokenRow.expires_at && new Date(tokenRow.expires_at) < new Date()) {
    accessToken = await refreshNaverToken(supabase, tokenRow);
  }

  // 네이버 캘린더 이벤트 조회 (최근 3개월 ~ 향후 6개월)
  const startDate = new Date();
  startDate.setMonth(startDate.getMonth() - 3);
  const endDate = new Date();
  endDate.setMonth(endDate.getMonth() + 6);

  const naverEvents = await fetchNaverEvents(
    accessToken,
    startDate.toISOString().split("T")[0],
    endDate.toISOString().split("T")[0]
  );

  let created = 0;
  let updated = 0;

  for (const event of naverEvents) {
    const hash = await calcHash(
      event.summary || "",
      event.dtstart?.dateTime || event.dtstart?.date || "",
      event.dtend?.dateTime || event.dtend?.date || "",
      event.location || "",
      event.description || ""
    );

    // 기존 이벤트 확인 (naver_event_id 기준)
    const { data: existing } = await supabase
      .from("calendar_events")
      .select("id, hash")
      .eq("user_id", tokenRow.user_id)
      .eq("naver_event_id", event.uid)
      .single();

    const eventData = {
      user_id: tokenRow.user_id,
      title: event.summary || "(제목 없음)",
      description: event.description || null,
      start_at: event.dtstart?.dateTime || event.dtstart?.date,
      end_at: event.dtend?.dateTime || event.dtend?.date || null,
      location: event.location || null,
      is_all_day: !!event.dtstart?.date,
      naver_event_id: event.uid,
      source: "naver",
      hash,
      sync_status: "pending",
      updated_at: new Date().toISOString(),
    };

    if (!existing) {
      // 새 이벤트 insert
      await supabase.from("calendar_events").insert(eventData);
      created++;
    } else if (existing.hash !== hash) {
      // 변경된 이벤트 update
      await supabase
        .from("calendar_events")
        .update(eventData)
        .eq("id", existing.id);
      updated++;
    }
    // hash 동일 → skip
  }

  // 로그 저장
  await supabase.from("calendar_sync_logs").insert({
    user_id: tokenRow.user_id,
    direction: "naver_to_db",
    status: "success",
    events_processed: naverEvents.length,
    events_created: created,
    events_updated: updated,
  });

  return { status: "success", created, updated };
}

async function fetchNaverEvents(accessToken: string, startDate: string, endDate: string) {
  // 네이버 캘린더 API: iCalendar 형식으로 반환됨
  const response = await fetch(
    `https://openapi.naver.com/calendar/createSchedule.json?startDateTime=${startDate}&endDateTime=${endDate}`,
    {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    }
  );

  if (response.status === 401) {
    throw new Error("NAVER_TOKEN_EXPIRED");
  }

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`네이버 API 오류: ${response.status} ${text}`);
  }

  const data = await response.json();
  // 네이버 응답은 iCalendar 형식 → 파싱 필요
  // data.calendar 필드에 VCALENDAR 문자열 포함
  return parseNaverIcal(data.calendar || "");
}

function parseNaverIcal(icalString: string): any[] {
  // iCalendar VEVENT 파싱
  const events: any[] = [];
  const lines = icalString.split(/\r?\n/);
  let currentEvent: any = null;

  for (const line of lines) {
    if (line === "BEGIN:VEVENT") {
      currentEvent = {};
    } else if (line === "END:VEVENT" && currentEvent) {
      events.push(currentEvent);
      currentEvent = null;
    } else if (currentEvent) {
      if (line.startsWith("SUMMARY:")) currentEvent.summary = line.slice(8);
      if (line.startsWith("DESCRIPTION:")) currentEvent.description = line.slice(12);
      if (line.startsWith("LOCATION:")) currentEvent.location = line.slice(9);
      if (line.startsWith("UID:")) currentEvent.uid = line.slice(4);
      if (line.startsWith("DTSTART;TZID=")) {
        currentEvent.dtstart = { dateTime: formatNaverDate(line.split(":")[1]) };
      } else if (line.startsWith("DTSTART:")) {
        const val = line.slice(8);
        if (val.length === 8) {
          currentEvent.dtstart = { date: `${val.slice(0,4)}-${val.slice(4,6)}-${val.slice(6,8)}` };
        } else {
          currentEvent.dtstart = { dateTime: formatNaverDate(val) };
        }
      }
      if (line.startsWith("DTEND;TZID=")) {
        currentEvent.dtend = { dateTime: formatNaverDate(line.split(":")[1]) };
      } else if (line.startsWith("DTEND:")) {
        const val = line.slice(6);
        if (val.length === 8) {
          currentEvent.dtend = { date: `${val.slice(0,4)}-${val.slice(4,6)}-${val.slice(6,8)}` };
        } else {
          currentEvent.dtend = { dateTime: formatNaverDate(val) };
        }
      }
    }
  }

  return events;
}

function formatNaverDate(naverDate: string): string {
  // 20260501T140000 → 2026-05-01T14:00:00+09:00
  if (naverDate.length < 15) return naverDate;
  return `${naverDate.slice(0,4)}-${naverDate.slice(4,6)}-${naverDate.slice(6,8)}T${naverDate.slice(9,11)}:${naverDate.slice(11,13)}:${naverDate.slice(13,15)}+09:00`;
}

async function refreshNaverToken(supabase: any, tokenRow: any): Promise<string> {
  const clientId = Deno.env.get("NAVER_CLIENT_ID")!;
  const clientSecret = Deno.env.get("NAVER_CLIENT_SECRET")!;

  const response = await fetch(
    `https://nid.naver.com/oauth2.0/token?grant_type=refresh_token&client_id=${clientId}&client_secret=${clientSecret}&refresh_token=${tokenRow.refresh_token}`,
    { method: "POST" }
  );

  if (!response.ok) throw new Error("네이버 토큰 갱신 실패");

  const data = await response.json();

  // 갱신된 토큰 저장
  await supabase
    .from("calendar_tokens")
    .update({
      access_token: data.access_token,
      expires_at: new Date(Date.now() + data.expires_in * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", tokenRow.user_id)
    .eq("provider", "naver");

  return data.access_token;
}

async function calcHash(...parts: string[]): Promise<string> {
  const combined = parts.join("|");
  const hashBuffer = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(combined)
  );
  return Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}
```

---

## STEP 3: Supabase Edge Function — sync-to-google

`supabase/functions/sync-to-google/index.ts` 생성:

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    // 구글 토큰 있는 사용자 목록
    const { data: tokens } = await supabase
      .from("calendar_tokens")
      .select("user_id, access_token, refresh_token, expires_at")
      .eq("provider", "google");

    if (!tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ message: "동기화할 사용자 없음" }), { status: 200 });
    }

    const results = [];

    for (const tokenRow of tokens) {
      try {
        const result = await syncToGoogleForUser(supabase, tokenRow);
        results.push({ user_id: tokenRow.user_id, ...result });
      } catch (err) {
        results.push({ user_id: tokenRow.user_id, status: "error", error: err.message });

        await supabase.from("calendar_sync_logs").insert({
          user_id: tokenRow.user_id,
          direction: "db_to_google",
          status: "error",
          error_message: err.message,
        });
      }
    }

    return new Response(JSON.stringify({ results }), { status: 200 });

  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});

async function syncToGoogleForUser(supabase: any, tokenRow: any) {
  // 토큰 만료 확인 및 갱신
  let accessToken = tokenRow.access_token;
  if (tokenRow.expires_at && new Date(tokenRow.expires_at) < new Date()) {
    accessToken = await refreshGoogleToken(supabase, tokenRow);
  }

  // DB에서 구글에 미동기화된 이벤트 조회 (google_event_id 없거나 pending)
  const { data: pendingEvents, error } = await supabase
    .from("calendar_events")
    .select("*")
    .eq("user_id", tokenRow.user_id)
    .or("google_event_id.is.null,sync_status.eq.pending");

  if (error) throw error;
  if (!pendingEvents || pendingEvents.length === 0) {
    return { status: "success", created: 0, updated: 0 };
  }

  let created = 0;
  let updated = 0;

  for (const event of pendingEvents) {
    try {
      const googleEvent = {
        summary: event.title,
        description: event.description || "",
        location: event.location || "",
        start: event.is_all_day
          ? { date: event.start_at.split("T")[0] }
          : { dateTime: event.start_at, timeZone: "Asia/Seoul" },
        end: event.is_all_day
          ? { date: (event.end_at || event.start_at).split("T")[0] }
          : { dateTime: event.end_at || event.start_at, timeZone: "Asia/Seoul" },
      };

      let googleEventId = event.google_event_id;

      if (!googleEventId) {
        // 구글에 새로 생성
        const res = await createGoogleEvent(accessToken, googleEvent);
        googleEventId = res.id;
        created++;
      } else {
        // 구글 이벤트 업데이트
        await updateGoogleEvent(accessToken, googleEventId, googleEvent);
        updated++;
      }

      // DB 업데이트
      await supabase
        .from("calendar_events")
        .update({
          google_event_id: googleEventId,
          sync_status: "synced",
          last_synced_at: new Date().toISOString(),
          sync_error: null,
        })
        .eq("id", event.id);

    } catch (eventErr) {
      // 이벤트 하나 실패해도 계속 진행
      await supabase
        .from("calendar_events")
        .update({
          sync_status: "error",
          sync_error: eventErr.message,
        })
        .eq("id", event.id);
    }
  }

  await supabase.from("calendar_sync_logs").insert({
    user_id: tokenRow.user_id,
    direction: "db_to_google",
    status: "success",
    events_processed: pendingEvents.length,
    events_created: created,
    events_updated: updated,
  });

  return { status: "success", created, updated };
}

async function createGoogleEvent(accessToken: string, event: any) {
  const response = await fetch(
    "https://www.googleapis.com/calendar/v3/calendars/primary/events",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(event),
    }
  );

  if (response.status === 401) throw new Error("GOOGLE_TOKEN_EXPIRED");
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`구글 이벤트 생성 실패: ${response.status} ${text}`);
  }

  return await response.json();
}

async function updateGoogleEvent(accessToken: string, eventId: string, event: any) {
  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/primary/events/${eventId}`,
    {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(event),
    }
  );

  if (response.status === 401) throw new Error("GOOGLE_TOKEN_EXPIRED");
  if (response.status === 404) {
    // 구글에서 삭제된 이벤트 → google_event_id 초기화하여 재생성 유도
    throw new Error("GOOGLE_EVENT_NOT_FOUND");
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`구글 이벤트 수정 실패: ${response.status} ${text}`);
  }
}

async function refreshGoogleToken(supabase: any, tokenRow: any): Promise<string> {
  const clientId = Deno.env.get("GOOGLE_CLIENT_ID")!;
  const clientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: tokenRow.refresh_token,
  });

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  if (!response.ok) throw new Error("구글 토큰 갱신 실패");

  const data = await response.json();

  await supabase
    .from("calendar_tokens")
    .update({
      access_token: data.access_token,
      expires_at: new Date(Date.now() + data.expires_in * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", tokenRow.user_id)
    .eq("provider", "google");

  return data.access_token;
}
```

---

## STEP 4: Supabase Edge Functions 환경변수 설정

> ⚠️ 사용자 직접 작업: Supabase 대시보드 → Edge Functions → Secrets

```
NAVER_CLIENT_ID=발급받은값
NAVER_CLIENT_SECRET=발급받은값
GOOGLE_CLIENT_ID=발급받은값
GOOGLE_CLIENT_SECRET=발급받은값
```

Edge Function 배포:

```bash
supabase functions deploy naver-poll-events
supabase functions deploy sync-to-google
```

---

## STEP 5: Supabase Cron 설정

Supabase SQL Editor에서 실행:

```sql
-- pg_cron 확장 활성화 (이미 활성화됐으면 skip)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 3분마다 네이버 폴링
SELECT cron.schedule(
  'naver-poll-events',
  '*/3 * * * *',
  $$
  SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/naver-poll-events',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- 3분마다 구글 동기화 (네이버 폴링 1.5분 뒤에 실행)
SELECT cron.schedule(
  'sync-to-google',
  '1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * *',
  $$
  SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/sync-to-google',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Supabase URL, 서비스 키 설정 (대시보드 → Settings → API에서 확인)
ALTER DATABASE postgres SET app.supabase_url = 'https://[프로젝트ID].supabase.co';
ALTER DATABASE postgres SET app.service_role_key = '[service_role_key]';
```

---

## STEP 6: Flutter — OAuth 토큰 저장 + 동기화 트리거

`lib/services/calendar_sync_service.dart` 구현 요청:

```
아래 요구사항으로 CalendarSyncService를 구현해줘.

== 역할 ==
1. 네이버 OAuth 완료 후 access_token, refresh_token을 Supabase calendar_tokens에 저장
2. 구글 OAuth 완료 후 동일하게 저장
3. 수동 동기화 트리거 (사용자가 버튼 누를 때)
4. 마지막 동기화 시간 조회
5. 동기화 상태 실시간 표시

== 구현 요구사항 ==

class CalendarSyncService {
  // 네이버 토큰 저장
  Future<void> saveNaverToken({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  });

  // 구글 토큰 저장
  Future<void> saveGoogleToken({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  });

  // 수동 동기화 트리거 (Edge Function 직접 호출)
  Future<SyncResult> triggerSync();

  // 마지막 동기화 시간
  Future<DateTime?> getLastSyncedAt();

  // 동기화 로그 최근 5개
  Future<List<SyncLog>> getRecentLogs();
}

== SyncResult 모델 ==
class SyncResult {
  final bool success;
  final int naverEventsProcessed;
  final int googleEventsSynced;
  final String? errorMessage;
}

== 주의사항 ==
- 토큰은 Supabase calendar_tokens 테이블에 저장 (로컬 저장 금지)
- triggerSync()는 두 Edge Function을 순서대로 호출
  1. naver-poll-events 호출 → 완료 대기
  2. sync-to-google 호출 → 완료 대기
- 에러는 throw하지 말고 SyncResult.success=false로 반환
```

---

## STEP 7: Flutter — 설정 화면 UI

설정 화면에 캘린더 동기화 섹션 추가:

```
== UI 요구사항 ==

캘린더 연동 섹션:
  [네이버 캘린더 연동] 버튼 또는 "연동됨 ✓" 표시
  [구글 캘린더 연동] 버튼 또는 "연동됨 ✓" 표시
  [지금 동기화] 버튼
  마지막 동기화: 2026-05-01 14:30 표시
  동기화 중일 때: 로딩 스피너 + "동기화 중..." 텍스트

== 상태 관리 ==
- 동기화 중 버튼 비활성화
- 성공 시 "동기화 완료" 스낵바
- 실패 시 에러 메시지 스낵바
```

---

## STEP 8: 네이버 OAuth 연동

```
네이버 캘린더 OAuth 연동을 구현해줘.

== 네이버 OAuth 엔드포인트 ==
인증: https://nid.naver.com/oauth2.0/authorize
토큰: https://nid.naver.com/oauth2.0/token

== 필요한 scope ==
calendar (캘린더 읽기/쓰기)

== 필요한 파라미터 ==
- response_type: code
- client_id: dotenv.env['NAVER_CLIENT_ID']
- redirect_uri: planflow://naver-callback
- state: 랜덤 문자열 (CSRF 방지)

== 구현 방식 ==
1. flutter_web_auth_2 패키지 사용하여 브라우저 OAuth 플로우
2. 콜백 URL: planflow://naver-callback
3. code 받으면 서버에서 토큰 교환
   → Supabase Edge Function으로 교환 처리 (Client Secret 노출 방지)
4. 받은 토큰을 CalendarSyncService.saveNaverToken()으로 저장

== AndroidManifest.xml에 추가 필요 ==
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="planflow" android:host="naver-callback"/>
</intent-filter>
```

---

## ⚠️ 알려진 한계 및 주의사항

```
1. 네이버 캘린더 API 제약
   - 실시간 웹훅 미지원 → 폴링만 가능 (3~5분 지연 발생)
   - iCalendar 형식으로 반환 → 파싱 필요
   - 반복 일정 처리 별도 구현 필요 (RRULE 파싱)

2. 토큰 보안
   - access_token, refresh_token은 Supabase에만 저장
   - 절대 로컬 저장소(SharedPreferences 등)에 저장 금지
   - RLS로 본인 토큰만 접근 가능

3. 동기화 충돌
   - 같은 시간에 네이버/구글 양쪽에서 수정 시 → 나중에 폴링된 쪽으로 덮어씀
   - 완전한 충돌 해결은 복잡도가 높아 1차에서는 단방향(네이버→구글) 우선 구현

4. API 호출 한도
   - 네이버 캘린더: 일 1,000회 (사용자 수 × 폴링 횟수 고려)
   - 구글 캘린더: 일 1,000,000회 (여유 있음)
   - 사용자 많아지면 폴링 주기 늘려야 함
```

---

## 📊 구현 체크리스트

```
□ STEP 1: DB 스키마 Supabase SQL Editor에서 실행
□ STEP 2: naver-poll-events Edge Function 배포
□ STEP 3: sync-to-google Edge Function 배포
□ STEP 4: Edge Functions 환경변수 설정
□ STEP 5: Cron 스케줄 설정
□ STEP 6: Flutter CalendarSyncService 구현
□ STEP 7: 설정 화면 UI 추가
□ STEP 8: 네이버 OAuth 연동
□ 실기기 테스트:
  □ 네이버 OAuth 정상 완료
  □ 구글 OAuth 정상 완료
  □ 네이버 일정 등록 → 3분 내 구글에 반영 확인
  □ 네이버 일정 수정 → 구글에 반영 확인
  □ 토큰 만료 후 자동 갱신 확인
```
