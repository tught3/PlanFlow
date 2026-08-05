/**
 * EventDetail 삭제 로직 테스트.
 *
 * EventForm.test.tsx와 동일한 이유(jsdom/@testing-library/react 미설치)로
 * 컴포넌트를 렌더링하지 않고, EventDetail.tsx가 함께 export하는
 * handleDeleteEvent()를 eventRepository를 모킹해 직접 테스트한다.
 */
import { describe, expect, it, vi } from 'vitest';

import { formatEventDisplayDate, handleDeleteEvent } from './EventDetail.tsx';
import type { EventRepository } from '../../data/eventRepository.ts';

function makeMockRepository(overrides: Partial<EventRepository> = {}): EventRepository {
  return {
    listEvents: vi.fn(async () => ({ data: [], error: null })),
    getEvent: vi.fn(async () => ({ data: null, error: null })),
    createEvent: vi.fn(async () => ({ data: null, error: null })),
    updateEvent: vi.fn(async () => ({ data: null, error: null })),
    deleteEvent: vi.fn(async () => ({ data: null, error: null })),
    ...overrides,
  };
}

describe('handleDeleteEvent', () => {
  it('삭제 성공 시 { success: true, error: null }을 반환하고 repository.deleteEvent를 호출한다', async () => {
    const deleteEventMock = vi.fn(async () => ({ data: null, error: null }));
    const repository = makeMockRepository({ deleteEvent: deleteEventMock });

    const result = await handleDeleteEvent(repository, 'evt-1');

    expect(deleteEventMock).toHaveBeenCalledWith('evt-1');
    expect(result).toEqual({ success: true, error: null });
  });

  it('삭제 실패 시 { success: false, error: message }를 반환한다', async () => {
    const repository = makeMockRepository({
      deleteEvent: vi.fn(async () => ({ data: null, error: { message: '권한이 없습니다.' } })),
    });

    const result = await handleDeleteEvent(repository, 'evt-1');

    expect(result).toEqual({ success: false, error: '권한이 없습니다.' });
  });
});

describe('formatEventDisplayDate', () => {
  it('YYYY-MM-DD HH:mm 형식으로 포맷한다', () => {
    const date = new Date(2026, 7, 5, 9, 30); // 로컬 시각 기준 2026-08-05 09:30
    expect(formatEventDisplayDate(date)).toBe('2026-08-05 09:30');
  });

  it('한 자릿수 월/일/시/분을 0으로 패딩한다', () => {
    const date = new Date(2026, 0, 2, 3, 4); // 2026-01-02 03:04
    expect(formatEventDisplayDate(date)).toBe('2026-01-02 03:04');
  });
});
