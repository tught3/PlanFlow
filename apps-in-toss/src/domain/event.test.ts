import { describe, expect, it } from 'vitest';

import { toDomainEvent, toSupabaseRow } from './event.ts';
import type { SupabaseEventRow } from './event.ts';

function makeRow(overrides: Partial<SupabaseEventRow> = {}): SupabaseEventRow {
  return {
    id: 'evt-1',
    user_id: 'user-1',
    title: '팀 회의',
    start_at: '2026-03-10T01:00:00.000Z',
    end_at: '2026-03-10T02:00:00.000Z',
    location: '회의실 A',
    location_lat: 37.5665,
    location_lng: 126.978,
    memo: '분기 계획 논의',
    supplies: ['노트북', '펜'],
    participants: ['홍길동', '김철수'],
    targets: ['user-1', 'user-2'],
    is_critical: true,
    use_strong_alarm: false,
    recurrence_rule: 'FREQ=WEEKLY;BYDAY=MO',
    recurrence_end_date: '2026-06-30',
    recurrence_count: 12,
    is_all_day: false,
    is_multi_day: false,
    parent_event_id: null,
    overridden_occurrence_date: null,
    category: '업무',
    source: 'manual',
    created_at: '2026-03-01T00:00:00.000Z',
    updated_at: '2026-03-02T00:00:00.000Z',
    ...overrides,
  };
}

describe('toDomainEvent / toSupabaseRow round-trip', () => {
  it('snake_case row -> camelCase Event -> snake_case row 가 정확히 왕복된다', () => {
    const row = makeRow();
    const event = toDomainEvent(row);

    expect(event.id).toBe(row.id);
    expect(event.userId).toBe(row.user_id);
    expect(event.title).toBe(row.title);
    expect(event.startAt.toISOString()).toBe(row.start_at);
    expect(event.endAt?.toISOString()).toBe(row.end_at);
    expect(event.location).toBe(row.location);
    expect(event.locationLat).toBe(row.location_lat);
    expect(event.locationLng).toBe(row.location_lng);
    expect(event.memo).toBe(row.memo);
    expect(event.supplies).toEqual(row.supplies);
    expect(event.participants).toEqual(row.participants);
    expect(event.targets).toEqual(row.targets);
    expect(event.isCritical).toBe(row.is_critical);
    expect(event.useStrongAlarm).toBe(row.use_strong_alarm);
    expect(event.recurrenceRule).toBe(row.recurrence_rule);
    expect(event.recurrenceEndDate).toBe(row.recurrence_end_date);
    expect(event.recurrenceCount).toBe(row.recurrence_count);
    expect(event.isAllDay).toBe(row.is_all_day);
    expect(event.isMultiDay).toBe(row.is_multi_day);
    expect(event.parentEventId).toBe(row.parent_event_id);
    expect(event.category).toBe(row.category);
    expect(event.source).toBe(row.source);
    expect(event.createdAt?.toISOString()).toBe(row.created_at);
    expect(event.updatedAt?.toISOString()).toBe(row.updated_at);

    const roundTripRow = toSupabaseRow(event);
    expect(roundTripRow).toEqual(row);
  });

  it('null 가능 필드가 null이어도 왕복된다', () => {
    const row = makeRow({
      end_at: null,
      location: null,
      location_lat: null,
      location_lng: null,
      memo: null,
      supplies: [],
      participants: [],
      targets: [],
      recurrence_rule: null,
      recurrence_end_date: null,
      recurrence_count: null,
      parent_event_id: null,
      overridden_occurrence_date: null,
      created_at: null,
      updated_at: null,
    });

    const event = toDomainEvent(row);
    expect(event.endAt).toBeNull();
    expect(event.recurrenceRule).toBeNull();
    expect(event.createdAt).toBeNull();
    expect(event.updatedAt).toBeNull();

    const roundTripRow = toSupabaseRow(event);
    expect(roundTripRow.end_at).toBeNull();
    expect(roundTripRow.recurrence_rule).toBeNull();
    // created_at/updated_at은 null이면 페이로드에서 아예 빠진다(DB default 사용).
    expect(roundTripRow.created_at).toBeUndefined();
    expect(roundTripRow.updated_at).toBeUndefined();
  });

  it('overridden_occurrence_date(단일 예외 회차 원본 숨김용)가 왕복된다', () => {
    const row = makeRow({
      parent_event_id: 'evt-parent',
      overridden_occurrence_date: '2026-03-17T01:00:00.000Z',
    });
    const event = toDomainEvent(row);
    expect(event.parentEventId).toBe('evt-parent');
    expect(event.overriddenOccurrenceDate?.toISOString()).toBe(
      '2026-03-17T01:00:00.000Z',
    );

    const roundTripRow = toSupabaseRow(event);
    expect(roundTripRow.overridden_occurrence_date).toBe(
      '2026-03-17T01:00:00.000Z',
    );
  });

  it('includeId:false 이면 id가 페이로드에서 빠진다(신규 insert용)', () => {
    const event = toDomainEvent(makeRow());
    const insertRow = toSupabaseRow(event, { includeId: false });
    expect('id' in insertRow).toBe(false);
  });

  it('start_at이 없으면 오류를 던진다(필수 필드)', () => {
    const row = makeRow({ start_at: '' as unknown as string });
    expect(() => toDomainEvent(row)).toThrowError(/start_at/);
  });
});
