import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

import { createEventRepository } from './eventRepository.ts';
import type { SupabaseEventRow } from '../domain/event.ts';

/**
 * Supabase query builder는 메서드 체이닝 중 어느 지점에서든 await 될 수 있는
 * thenable 객체다(single()/maybeSingle() 없이 곧바로 await되는 delete().eq()
 * 케이스 포함). 그래서 모든 체인 메서드가 같은 chain 객체를 반환하고,
 * chain 자체가 .then을 구현하도록 모킹한다.
 */
function createMockChain(result: { data: unknown; error: { message: string; code?: string } | null }) {
  const chain: Record<string, unknown> = {};
  const chainMethods = ['select', 'insert', 'update', 'delete', 'eq', 'lte', 'gte', 'or', 'order'];
  for (const method of chainMethods) {
    chain[method] = vi.fn(() => chain);
  }
  chain.single = vi.fn(() => Promise.resolve(result));
  chain.maybeSingle = vi.fn(() => Promise.resolve(result));
  chain.then = (
    onFulfilled?: ((value: typeof result) => unknown) | null,
    onRejected?: ((reason: unknown) => unknown) | null,
  ) => Promise.resolve(result).then(onFulfilled, onRejected);
  return chain;
}

function createMockClient(result: { data: unknown; error: { message: string; code?: string } | null }) {
  const chain = createMockChain(result);
  const from = vi.fn(() => chain);
  const client = { from } as unknown as SupabaseClient;
  return { client, from, chain };
}

const SAMPLE_ROW: SupabaseEventRow = {
  id: 'evt-1',
  user_id: 'user-1',
  title: '회의',
  start_at: '2026-08-05T01:00:00.000Z',
  end_at: '2026-08-05T02:00:00.000Z',
  location: null,
  location_lat: null,
  location_lng: null,
  memo: null,
  supplies: [],
  participants: [],
  targets: [],
  is_critical: false,
  use_strong_alarm: false,
  recurrence_rule: null,
  recurrence_end_date: null,
  recurrence_count: null,
  is_all_day: false,
  is_multi_day: false,
  parent_event_id: null,
  overridden_occurrence_date: null,
  category: '업무',
  source: 'manual',
  created_at: '2026-08-05T00:00:00.000Z',
  updated_at: '2026-08-05T00:00:00.000Z',
};

describe('eventRepository', () => {
  describe('listEvents', () => {
    it('올바른 쿼리 파라미터로 조회한다', async () => {
      const { client, from, chain } = createMockClient({ data: [SAMPLE_ROW], error: null });
      const repo = createEventRepository(client);

      const range = { start: '2026-08-01T00:00:00.000Z', end: '2026-08-31T23:59:59.999Z' };
      const result = await repo.listEvents(range);

      expect(from).toHaveBeenCalledWith('events');
      expect(chain.select).toHaveBeenCalledWith('*');
      expect(chain.lte).toHaveBeenCalledWith('start_at', range.end);
      expect(chain.or).toHaveBeenCalledWith(
        `and(end_at.gte.${range.start}),and(end_at.is.null,start_at.gte.${range.start})`,
      );
      expect(chain.order).toHaveBeenCalledWith('start_at', { ascending: true });

      expect(result.error).toBeNull();
      expect(result.data).toHaveLength(1);
      expect(result.data?.[0].id).toBe('evt-1');
      expect(result.data?.[0].startAt).toBeInstanceOf(Date);
    });

    it('Supabase 에러를 던지지 않고 error 필드로 반환한다', async () => {
      const { client } = createMockClient({ data: null, error: { message: 'boom', code: '500' } });
      const repo = createEventRepository(client);

      const result = await repo.listEvents({ start: 'a', end: 'b' });

      expect(result.data).toBeNull();
      expect(result.error).toEqual({ message: 'boom', code: '500' });
    });
  });

  describe('getEvent', () => {
    it('존재하면 도메인 Event로 변환해 반환한다', async () => {
      const { client, chain } = createMockClient({ data: SAMPLE_ROW, error: null });
      const repo = createEventRepository(client);

      const result = await repo.getEvent('evt-1');

      expect(chain.eq).toHaveBeenCalledWith('id', 'evt-1');
      expect(result.error).toBeNull();
      expect(result.data?.userId).toBe('user-1');
      expect(result.data?.title).toBe('회의');
    });

    it('존재하지 않으면 data/error 모두 null이다', async () => {
      const { client } = createMockClient({ data: null, error: null });
      const repo = createEventRepository(client);

      const result = await repo.getEvent('missing');

      expect(result.data).toBeNull();
      expect(result.error).toBeNull();
    });

    it('Supabase 에러를 던지지 않고 error 필드로 반환한다', async () => {
      const { client } = createMockClient({ data: null, error: { message: 'db down' } });
      const repo = createEventRepository(client);

      const result = await repo.getEvent('evt-1');

      expect(result.data).toBeNull();
      expect(result.error).toEqual({ message: 'db down', code: undefined });
    });
  });

  describe('createEvent', () => {
    it('성공 시 반환값이 도메인 Event 타입으로 변환된다', async () => {
      const { client, chain } = createMockClient({ data: SAMPLE_ROW, error: null });
      const repo = createEventRepository(client);

      const result = await repo.createEvent({
        userId: 'user-1',
        title: '회의',
        startAt: new Date('2026-08-05T01:00:00.000Z'),
        endAt: new Date('2026-08-05T02:00:00.000Z'),
        location: null,
        locationLat: null,
        locationLng: null,
        memo: null,
        supplies: [],
        participants: [],
        targets: [],
        isCritical: false,
        useStrongAlarm: false,
        recurrenceRule: null,
        recurrenceEndDate: null,
        recurrenceCount: null,
        isAllDay: false,
        isMultiDay: false,
        parentEventId: null,
        overriddenOccurrenceDate: null,
        category: '업무',
        source: 'manual',
      });

      expect(chain.insert).toHaveBeenCalled();
      const insertedRow = (chain.insert as ReturnType<typeof vi.fn>).mock.calls[0][0];
      expect(insertedRow.id).toBeUndefined();
      expect(insertedRow.user_id).toBe('user-1');

      expect(result.error).toBeNull();
      expect(result.data?.id).toBe('evt-1');
      expect(result.data?.startAt).toBeInstanceOf(Date);
    });

    it('Supabase 에러를 던지지 않고 error 필드로 반환한다', async () => {
      const { client } = createMockClient({ data: null, error: { message: 'insert failed' } });
      const repo = createEventRepository(client);

      const result = await repo.createEvent({
        userId: 'user-1',
        title: '회의',
        startAt: new Date(),
        endAt: null,
        location: null,
        locationLat: null,
        locationLng: null,
        memo: null,
        supplies: [],
        participants: [],
        targets: [],
        isCritical: false,
        useStrongAlarm: false,
        recurrenceRule: null,
        recurrenceEndDate: null,
        recurrenceCount: null,
        isAllDay: false,
        isMultiDay: false,
        parentEventId: null,
        overriddenOccurrenceDate: null,
        category: '기타',
        source: 'manual',
      });

      expect(result.data).toBeNull();
      expect(result.error).toEqual({ message: 'insert failed', code: undefined });
    });
  });

  describe('updateEvent', () => {
    it('patch에 있는 필드만 snake_case로 변환해 update를 호출한다', async () => {
      const updatedRow: SupabaseEventRow = { ...SAMPLE_ROW, title: '변경된 제목' };
      const { client, chain } = createMockClient({ data: updatedRow, error: null });
      const repo = createEventRepository(client);

      const result = await repo.updateEvent('evt-1', { title: '변경된 제목' });

      expect(chain.update).toHaveBeenCalledWith({ title: '변경된 제목' });
      expect(chain.eq).toHaveBeenCalledWith('id', 'evt-1');
      expect(result.error).toBeNull();
      expect(result.data?.title).toBe('변경된 제목');
    });

    it('Date 필드 patch는 ISO 문자열로 변환된다', async () => {
      const { client, chain } = createMockClient({ data: SAMPLE_ROW, error: null });
      const repo = createEventRepository(client);

      const newStart = new Date('2026-09-01T00:00:00.000Z');
      await repo.updateEvent('evt-1', { startAt: newStart });

      expect(chain.update).toHaveBeenCalledWith({ start_at: newStart.toISOString() });
    });

    it('Supabase 에러를 던지지 않고 error 필드로 반환한다', async () => {
      const { client } = createMockClient({ data: null, error: { message: 'update failed' } });
      const repo = createEventRepository(client);

      const result = await repo.updateEvent('evt-1', { title: 'x' });

      expect(result.data).toBeNull();
      expect(result.error).toEqual({ message: 'update failed', code: undefined });
    });
  });

  describe('deleteEvent', () => {
    it('성공 시 data=null, error=null을 반환한다', async () => {
      const { client, chain } = createMockClient({ data: null, error: null });
      const repo = createEventRepository(client);

      const result = await repo.deleteEvent('evt-1');

      expect(chain.delete).toHaveBeenCalled();
      expect(chain.eq).toHaveBeenCalledWith('id', 'evt-1');
      expect(result.data).toBeNull();
      expect(result.error).toBeNull();
    });

    it('Supabase 에러를 던지지 않고 error 필드로 반환한다', async () => {
      const { client } = createMockClient({ data: null, error: { message: 'delete failed' } });
      const repo = createEventRepository(client);

      const result = await repo.deleteEvent('evt-1');

      expect(result.data).toBeNull();
      expect(result.error).toEqual({ message: 'delete failed', code: undefined });
    });
  });
});
