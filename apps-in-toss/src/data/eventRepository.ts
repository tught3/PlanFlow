/**
 * `events` 테이블 CRUD 리포지토리.
 *
 * snake_case(Supabase row) <-> camelCase(도메인 Event) 변환은
 * src/domain/event.ts의 toDomainEvent()/toSupabaseRow()만 사용한다.
 *
 * Supabase 에러는 throw하지 않고 { data, error } 형태(RepositoryResult)로 반환해
 * 호출부(UI)가 직접 에러 상태를 처리할 수 있게 한다.
 *
 * 클라이언트는 인자로 주입받는 팩토리 패턴(createEventRepository)을 쓴다.
 * 테스트에서는 supabase 클라이언트를 모킹해 주입하면 된다.
 * 앱 코드에서 바로 쓸 수 있도록 src/lib/supabase.ts의 기본 클라이언트로 만든
 * `eventRepository` 싱글턴도 함께 내보낸다.
 */
import type { SupabaseClient } from '@supabase/supabase-js';

import { supabase } from '../lib/supabase.ts';
import type { Event, SupabaseEventRow } from '../domain/event.ts';
import { toDomainEvent, toSupabaseRow } from '../domain/event.ts';

const TABLE = 'events';

export interface RepositoryError {
  message: string;
  code?: string;
}

export interface RepositoryResult<T> {
  data: T | null;
  error: RepositoryError | null;
}

export interface EventDateRange {
  /** ISO 문자열 (UTC). 이 시각 이전/동안 시작하는 일정만 포함. */
  start: string;
  /** ISO 문자열 (UTC). 이 시각 이후/동안 끝나는 일정까지 포함. */
  end: string;
}

/** createEvent에 넘길 입력. id/createdAt/updatedAt은 DB가 채운다. */
export type NewEventInput = Omit<Event, 'id' | 'createdAt' | 'updatedAt'>;

function toRepositoryError(error: { message: string; code?: string } | null): RepositoryError | null {
  if (error === null) {
    return null;
  }
  return { message: error.message, code: error.code };
}

function fromCaughtError(err: unknown): RepositoryError {
  if (err instanceof Error) {
    return { message: err.message };
  }
  return { message: String(err) };
}

/** 부분 업데이트(patch)용: 도메인 camelCase 키 -> Supabase snake_case 키. */
const PATCH_FIELD_MAP: Partial<Record<keyof Event, keyof SupabaseEventRow>> = {
  userId: 'user_id',
  title: 'title',
  startAt: 'start_at',
  endAt: 'end_at',
  location: 'location',
  locationLat: 'location_lat',
  locationLng: 'location_lng',
  memo: 'memo',
  supplies: 'supplies',
  participants: 'participants',
  targets: 'targets',
  isCritical: 'is_critical',
  useStrongAlarm: 'use_strong_alarm',
  recurrenceRule: 'recurrence_rule',
  recurrenceEndDate: 'recurrence_end_date',
  recurrenceCount: 'recurrence_count',
  isAllDay: 'is_all_day',
  isMultiDay: 'is_multi_day',
  parentEventId: 'parent_event_id',
  overriddenOccurrenceDate: 'overridden_occurrence_date',
  category: 'category',
  source: 'source',
};

/** patch의 Date 값 필드(toSupabaseRow의 toUtcIso 변환과 동일하게 처리). */
const PATCH_DATE_FIELDS = new Set<keyof Event>(['startAt', 'endAt', 'overriddenOccurrenceDate']);

/**
 * Partial<Event> patch -> Partial<SupabaseEventRow>.
 *
 * toSupabaseRow()는 완전한 Event 객체가 필요해 부분 업데이트에는 그대로 쓸 수 없다.
 * patch에 실제로 들어있는 키만 snake_case로 변환한다(없는 키는 UPDATE 문에서 제외되어야
 * 하므로 undefined로 채우지 않는다).
 */
function toPartialSupabaseRow(patch: Partial<Event>): Partial<SupabaseEventRow> {
  const row: Partial<SupabaseEventRow> = {};
  for (const key of Object.keys(patch) as (keyof Event)[]) {
    const snakeKey = PATCH_FIELD_MAP[key];
    if (snakeKey === undefined) {
      continue;
    }
    const value = patch[key];
    if (PATCH_DATE_FIELDS.has(key)) {
      const dateValue = value as Date | null | undefined;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (row as any)[snakeKey] = dateValue instanceof Date ? dateValue.toISOString() : dateValue ?? null; // banned-ok: 동적 snake_case 키 대입, 타입 불가피
    } else {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (row as any)[snakeKey] = value; // banned-ok: 동적 snake_case 키 대입, 타입 불가피
    }
  }
  return row;
}

export function createEventRepository(client: SupabaseClient) {
  return {
    /** 기간(range)과 겹치는 일정 목록 조회 (start_at 오름차순). */
    async listEvents(range: EventDateRange): Promise<RepositoryResult<Event[]>> {
      try {
        const { data, error } = await client
          .from(TABLE)
          .select('*')
          .lte('start_at', range.end)
          .or(`and(end_at.gte.${range.start}),and(end_at.is.null,start_at.gte.${range.start})`)
          .order('start_at', { ascending: true });

        if (error) {
          return { data: null, error: toRepositoryError(error) };
        }

        const rows = (data ?? []) as SupabaseEventRow[];
        const events = rows.map((row) => toDomainEvent(row));
        return { data: events, error: null };
      } catch (err) {
        return { data: null, error: fromCaughtError(err) };
      }
    },

    /** 단건 조회. */
    async getEvent(id: string): Promise<RepositoryResult<Event>> {
      try {
        const { data, error } = await client.from(TABLE).select('*').eq('id', id).maybeSingle();

        if (error) {
          return { data: null, error: toRepositoryError(error) };
        }
        if (data === null) {
          return { data: null, error: null };
        }

        const event = toDomainEvent(data as SupabaseEventRow);
        return { data: event, error: null };
      } catch (err) {
        return { data: null, error: fromCaughtError(err) };
      }
    },

    /** 신규 일정 생성. id/createdAt/updatedAt은 DB가 채운다. */
    async createEvent(input: NewEventInput): Promise<RepositoryResult<Event>> {
      try {
        const draftEvent: Event = {
          ...input,
          id: '',
          createdAt: null,
          updatedAt: null,
        };
        const insertRow = toSupabaseRow(draftEvent, { includeId: false });

        const { data, error } = await client.from(TABLE).insert(insertRow).select('*').single();

        if (error) {
          return { data: null, error: toRepositoryError(error) };
        }

        const event = toDomainEvent(data as SupabaseEventRow);
        return { data: event, error: null };
      } catch (err) {
        return { data: null, error: fromCaughtError(err) };
      }
    },

    /** 부분 수정. */
    async updateEvent(id: string, patch: Partial<Event>): Promise<RepositoryResult<Event>> {
      try {
        const updateRow = toPartialSupabaseRow(patch);

        const { data, error } = await client
          .from(TABLE)
          .update(updateRow)
          .eq('id', id)
          .select('*')
          .single();

        if (error) {
          return { data: null, error: toRepositoryError(error) };
        }

        const event = toDomainEvent(data as SupabaseEventRow);
        return { data: event, error: null };
      } catch (err) {
        return { data: null, error: fromCaughtError(err) };
      }
    },

    /** 삭제. */
    async deleteEvent(id: string): Promise<RepositoryResult<null>> {
      try {
        const { error } = await client.from(TABLE).delete().eq('id', id);

        if (error) {
          return { data: null, error: toRepositoryError(error) };
        }

        return { data: null, error: null };
      } catch (err) {
        return { data: null, error: fromCaughtError(err) };
      }
    },
  };
}

export type EventRepository = ReturnType<typeof createEventRepository>;

/** 앱 기본 Supabase 클라이언트로 만든 싱글턴 리포지토리. */
export const eventRepository = createEventRepository(supabase);
