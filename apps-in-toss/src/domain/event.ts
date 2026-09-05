/**
 * PlanFlow 도메인 Event 타입 정의.
 *
 * 원본(Flutter) 대응 파일:
 * - lib/data/models/event_model.dart (EventModel)
 * - supabase/schema.sql (public.events 테이블, 160~190번째 줄)
 *
 * Supabase row는 snake_case, 도메인 타입은 camelCase를 쓴다.
 * 매핑은 이 파일의 toDomainEvent()/toSupabaseInsertRow()/toSupabaseUpdateRow()로만
 * 하고, 다른 곳에서 개별 필드를 직접 snake_case <-> camelCase 변환하지 않는다.
 */

/** Supabase `public.events` row (snake_case, DB 그대로). */
export interface SupabaseEventRow {
  id: string;
  user_id: string;
  title: string;
  start_at: string;
  end_at: string | null;
  location: string | null;
  location_lat: number | null;
  location_lng: number | null;
  memo: string | null;
  supplies: string[];
  participants: string[];
  targets: string[];
  is_critical: boolean;
  use_strong_alarm: boolean;
  recurrence_rule: string | null;
  /** postgres `date` 컬럼. 시간 정보가 없는 'YYYY-MM-DD' 문자열. */
  recurrence_end_date: string | null;
  recurrence_count: number | null;
  is_all_day: boolean;
  is_multi_day: boolean;
  parent_event_id: string | null;
  overridden_occurrence_date: string | null;
  category: string;
  source: string;
  created_at: string | null;
  updated_at: string | null;
}

/** 도메인 Event (camelCase). 화면/로직에서는 이 타입만 사용한다. */
export interface Event {
  id: string;
  userId: string;
  title: string;
  startAt: Date;
  endAt: Date | null;
  location: string | null;
  locationLat: number | null;
  locationLng: number | null;
  memo: string | null;
  supplies: string[];
  participants: string[];
  targets: string[];
  isCritical: boolean;
  useStrongAlarm: boolean;
  recurrenceRule: string | null;
  /** 'YYYY-MM-DD' 형태의 날짜 전용 문자열(postgres date). */
  recurrenceEndDate: string | null;
  recurrenceCount: number | null;
  isAllDay: boolean;
  isMultiDay: boolean;
  parentEventId: string | null;
  overriddenOccurrenceDate: Date | null;
  category: string;
  source: string;
  createdAt: Date | null;
  updatedAt: Date | null;
}

const DEFAULT_CATEGORY = '기타';
const DEFAULT_SOURCE = 'manual';

function parseDate(value: string | null | undefined): Date | null {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return parsed;
}

function toUtcIso(value: Date | null | undefined): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return value.toISOString();
}

function toStringArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value
      .map((item) => (item === null || item === undefined ? '' : String(item)))
      .filter((item) => item.length > 0);
  }
  return [];
}

/** Supabase row -> 도메인 Event. */
export function toDomainEvent(row: SupabaseEventRow): Event {
  const startAt = parseDate(row.start_at);
  if (startAt === null) {
    throw new Error('Missing required field: start_at');
  }

  return {
    id: row.id,
    userId: row.user_id,
    title: row.title,
    startAt,
    endAt: parseDate(row.end_at),
    location: row.location ?? null,
    locationLat: row.location_lat ?? null,
    locationLng: row.location_lng ?? null,
    memo: row.memo ?? null,
    supplies: toStringArray(row.supplies),
    participants: toStringArray(row.participants),
    targets: toStringArray(row.targets),
    isCritical: Boolean(row.is_critical),
    useStrongAlarm: Boolean(row.use_strong_alarm),
    recurrenceRule: row.recurrence_rule ?? null,
    recurrenceEndDate: row.recurrence_end_date ?? null,
    recurrenceCount: row.recurrence_count ?? null,
    isAllDay: Boolean(row.is_all_day),
    isMultiDay: Boolean(row.is_multi_day),
    parentEventId: row.parent_event_id ?? null,
    overriddenOccurrenceDate: parseDate(row.overridden_occurrence_date),
    category: row.category || DEFAULT_CATEGORY,
    source: row.source || DEFAULT_SOURCE,
    createdAt: parseDate(row.created_at),
    updatedAt: parseDate(row.updated_at),
  };
}

export interface ToSupabaseRowOptions {
  /** false면 'id' 필드를 뺀다(신규 insert 시 DB default 사용 등). 기본 true. */
  includeId?: boolean;
}

/** 도메인 Event -> Supabase row(snake_case). insert/update 양쪽에 쓸 수 있다. */
export function toSupabaseRow(
  event: Event,
  options: ToSupabaseRowOptions = {},
): Partial<SupabaseEventRow> {
  const includeId = options.includeId ?? true;
  const row: Partial<SupabaseEventRow> = {
    user_id: event.userId,
    title: event.title,
    start_at: toUtcIso(event.startAt) as string,
    end_at: toUtcIso(event.endAt),
    location: event.location,
    location_lat: event.locationLat,
    location_lng: event.locationLng,
    memo: event.memo,
    supplies: event.supplies,
    participants: event.participants,
    targets: event.targets,
    is_critical: event.isCritical,
    use_strong_alarm: event.useStrongAlarm,
    recurrence_rule: event.recurrenceRule,
    recurrence_end_date: event.recurrenceEndDate,
    recurrence_count: event.recurrenceCount,
    is_all_day: event.isAllDay,
    is_multi_day: event.isMultiDay,
    parent_event_id: event.parentEventId,
    overridden_occurrence_date: toUtcIso(event.overriddenOccurrenceDate),
    category: event.category,
    source: event.source,
  };

  if (includeId) {
    row.id = event.id;
  }
  if (event.createdAt !== null) {
    row.created_at = toUtcIso(event.createdAt) as string;
  }
  if (event.updatedAt !== null) {
    row.updated_at = toUtcIso(event.updatedAt) as string;
  }

  return row;
}
