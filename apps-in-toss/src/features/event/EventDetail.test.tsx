/**
 * EventDetail 삭제 로직 + 렌더링 테스트.
 *
 * 삭제 로직은 EventForm.test.tsx와 동일한 이유(jsdom/@testing-library/react
 * 미설치)로 컴포넌트를 렌더링하지 않고, EventDetail.tsx가 함께 export하는
 * handleDeleteEvent()를 eventRepository를 모킹해 직접 테스트한다.
 *
 * 렌더 결과 검증(예: location 표시 여부)은 ConfirmDialog.test.tsx와 동일하게
 * react-dom/server의 renderToStaticMarkup으로 마크업 문자열을 확인한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';

import { confirmDeleteEvent, EventDetail, formatEventDisplayDate, handleDeleteEvent, nextDeletePhase } from './EventDetail.tsx';
import type { EventRepository } from '../../data/eventRepository.ts';
import type { Event } from '../../domain/event.ts';

function makeEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-1',
    userId: 'user-1',
    title: '워크숍(1박 2일)',
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
    category: '기타',
    source: 'manual',
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  };
}

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

describe('삭제 확인 흐름 (nextDeletePhase / confirmDeleteEvent)', () => {
  it('확인 전(아직 confirming 상태에 도달하지 않음)에는 repository.deleteEvent가 호출되지 않는다', async () => {
    const deleteEventMock = vi.fn(async () => ({ data: null, error: null }));
    const repository = makeMockRepository({ deleteEvent: deleteEventMock });

    // 삭제 버튼을 눌러 확인 다이얼로그를 여는 단계까지만 진행하고, confirm은 아직 호출하지 않는다.
    const phaseAfterClick = nextDeletePhase({ phase: 'idle', action: 'click-delete' });
    expect(phaseAfterClick).toBe('confirming');
    expect(deleteEventMock).not.toHaveBeenCalled();

    // 방어적으로 idle 상태에서 confirmDeleteEvent가 호출돼도(확인을 거치지 않은 경우)
    // 가드가 막아 repository를 호출하지 않는다.
    const guarded = await confirmDeleteEvent({ repository, id: 'evt-1', phase: 'idle' });
    expect(deleteEventMock).not.toHaveBeenCalled();
    expect(guarded.result).toBeNull();
    expect(guarded.phase).toBe('idle');
  });

  it('확인(confirming -> confirm) 후에는 repository.deleteEvent가 정확히 1회 호출된다', async () => {
    const deleteEventMock = vi.fn(async () => ({ data: null, error: null }));
    const repository = makeMockRepository({ deleteEvent: deleteEventMock });
    const onDeletingStart = vi.fn();

    const { phase, result } = await confirmDeleteEvent({
      repository,
      id: 'evt-1',
      phase: 'confirming',
      onDeletingStart,
    });

    expect(deleteEventMock).toHaveBeenCalledTimes(1);
    expect(deleteEventMock).toHaveBeenCalledWith('evt-1');
    expect(onDeletingStart).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ success: true, error: null });
    expect(phase).toBe('idle');
  });

  it('취소 시 repository.deleteEvent 호출 횟수가 0으로 유지된다', () => {
    const deleteEventMock = vi.fn(async () => ({ data: null, error: null }));
    makeMockRepository({ deleteEvent: deleteEventMock });

    const phaseAfterClick = nextDeletePhase({ phase: 'idle', action: 'click-delete' });
    const phaseAfterCancel = nextDeletePhase({ phase: phaseAfterClick, action: 'cancel' });

    expect(phaseAfterClick).toBe('confirming');
    expect(phaseAfterCancel).toBe('idle');
    expect(deleteEventMock).not.toHaveBeenCalled();
  });

  it('삭제 실패 시 phase는 idle로 돌아가고 result.success는 false다', async () => {
    const repository = makeMockRepository({
      deleteEvent: vi.fn(async () => ({ data: null, error: { message: '권한이 없습니다.' } })),
    });

    const { phase, result } = await confirmDeleteEvent({ repository, id: 'evt-1', phase: 'confirming' });

    expect(result).toEqual({ success: false, error: '권한이 없습니다.' });
    expect(phase).toBe('idle');
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

describe('EventDetail 렌더링 - location', () => {
  it('location이 있으면 상세 화면에 표시한다', () => {
    const event = makeEvent({ location: '강원도 평창' });
    const repository = makeMockRepository();

    const html = renderToStaticMarkup(<EventDetail event={event} repository={repository} />);

    expect(html).toContain('강원도 평창');
    expect(html).toContain('event-detail__memo');
  });

  it('location이 null이면 location 문단을 렌더링하지 않는다', () => {
    const event = makeEvent({ location: null });
    const repository = makeMockRepository();

    const html = renderToStaticMarkup(<EventDetail event={event} repository={repository} />);

    expect(html).not.toContain('강원도 평창');
  });
});
