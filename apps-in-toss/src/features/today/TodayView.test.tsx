/**
 * TodayView / TodayEventList 테스트.
 *
 * 이 프로젝트에는 jsdom·@testing-library/react가 설치돼 있지 않다(2026-08-05 기준,
 * package.json 확인). 그래서 두 갈래로 나눠 검증한다:
 *
 * 1) loadTodayEvents(순수 데이터 로딩 함수) - eventRepository를 모킹해 직접 호출.
 *    kstTodayRange로 계산한 KST 하루 범위가 그대로 넘어가는지, 에러 처리가
 *    맞는지 React 렌더링 없이 검증한다.
 * 2) TodayEventList(순수 presentational 컴포넌트) - hook/effect가 없으므로
 *    react-dom/server의 renderToStaticMarkup으로 jsdom 없이도 실제 렌더링 결과를
 *    검증할 수 있다. "일정 있을 때 / 빈 상태일 때"를 이 경로로 커버한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';

import type { Event } from '../../domain/event.ts';
import { kstTodayRange } from '../../domain/datetime.ts';
import type { EventRepository } from '../../data/eventRepository.ts';
import { loadTodayEvents } from './TodayView.tsx';
import { TodayEventList } from './TodayEventList.tsx';

/**
 * TodayEventList는 이제 각 행을 react-router-dom의 <Link>로 감싼다. 이 프로젝트에는
 * jsdom이 없어 renderToStaticMarkup으로만 렌더링을 검증하는데, <Link>는 라우터
 * 컨텍스트(useContext) 없이 렌더링하면 "Cannot destructure property 'basename' of
 * ...useContext(...) as it is null"로 즉시 던진다 - 그래서 항상 MemoryRouter로
 * 감싸서 렌더링한다.
 */
function renderTodayEventList(events: Event[]): string {
  return renderToStaticMarkup(
    <MemoryRouter>
      <TodayEventList events={events} />
    </MemoryRouter>,
  );
}

function makeEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-1',
    userId: 'user-1',
    title: '팀 회의',
    startAt: new Date('2026-08-05T01:00:00.000Z'), // 10:00 KST
    endAt: new Date('2026-08-05T02:00:00.000Z'), // 11:00 KST
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
    createdAt: null,
    updatedAt: null,
    ...overrides,
  };
}

function makeMockRepository(
  overrides: Partial<EventRepository> = {},
): EventRepository {
  return {
    listEvents: vi.fn().mockResolvedValue({ data: [], error: null }),
    getEvent: vi.fn().mockResolvedValue({ data: null, error: null }),
    createEvent: vi.fn().mockResolvedValue({ data: null, error: null }),
    updateEvent: vi.fn().mockResolvedValue({ data: null, error: null }),
    deleteEvent: vi.fn().mockResolvedValue({ data: null, error: null }),
    ...overrides,
  } as EventRepository;
}

describe('loadTodayEvents', () => {
  it('kstTodayRange로 계산한 오늘 KST 범위를 listEvents에 그대로 넘긴다', async () => {
    const now = new Date('2026-08-05T10:00:00.000Z');
    const expectedRange = kstTodayRange(now);
    const listEvents = vi.fn().mockResolvedValue({ data: [], error: null });
    const repository = makeMockRepository({ listEvents });

    await loadTodayEvents(repository, now);

    expect(listEvents).toHaveBeenCalledWith({
      start: expectedRange.start.toISOString(),
      end: expectedRange.end.toISOString(),
    });
  });

  it('일정이 있으면 그대로 반환한다(에러 없음)', async () => {
    const events = [makeEvent({ id: 'evt-1' }), makeEvent({ id: 'evt-2' })];
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({ data: events, error: null }),
    });

    const result = await loadTodayEvents(repository, new Date('2026-08-05T10:00:00.000Z'));

    expect(result.error).toBeNull();
    expect(result.events).toEqual(events);
  });

  it('일정이 없으면 빈 배열을 반환한다', async () => {
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({ data: [], error: null }),
    });

    const result = await loadTodayEvents(repository, new Date('2026-08-05T10:00:00.000Z'));

    expect(result.error).toBeNull();
    expect(result.events).toEqual([]);
  });

  it('data가 null이어도 빈 배열로 정규화한다', async () => {
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({ data: null, error: null }),
    });

    const result = await loadTodayEvents(repository, new Date('2026-08-05T10:00:00.000Z'));

    expect(result.events).toEqual([]);
  });

  it('repository가 error를 반환하면 error 메시지를 채우고 events는 빈 배열이다', async () => {
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({
        data: null,
        error: { message: 'network down', code: '500' },
      }),
    });

    const result = await loadTodayEvents(repository, new Date('2026-08-05T10:00:00.000Z'));

    expect(result.error).toBe('network down');
    expect(result.events).toEqual([]);
  });

  it('repository가 예외를 던지면 잡아서 error 문자열로 반환한다', async () => {
    const repository = makeMockRepository({
      listEvents: vi.fn().mockRejectedValue(new Error('boom')),
    });

    const result = await loadTodayEvents(repository, new Date('2026-08-05T10:00:00.000Z'));

    expect(result.error).toBe('boom');
    expect(result.events).toEqual([]);
  });

  it('매주 반복 일정은 오늘 날짜의 회차로 전개되어 표시된다(원본 회차가 아니라 오늘의 회차)', async () => {
    // 2026-08-05(수)이 "오늘". 원본 반복 일정은 2주 전 수요일(2026-07-22)에 시작해
    // 매주 수요일 반복한다 - listEvents는 이 원본(미전개) row를 그대로 돌려준다.
    const now = new Date('2026-08-05T10:00:00.000Z'); // 19:00 KST, 수요일
    const recurringEvent = makeEvent({
      id: 'weekly-1',
      title: '주간 스탠드업',
      startAt: new Date('2026-07-22T01:00:00.000Z'), // 10:00 KST, 수요일
      endAt: new Date('2026-07-22T01:30:00.000Z'),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
    });
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({ data: [recurringEvent], error: null }),
    });

    const result = await loadTodayEvents(repository, now);

    expect(result.error).toBeNull();
    expect(result.events).toHaveLength(1);
    const occurrence = result.events[0];
    expect(occurrence.id).toBe('weekly-1');
    // 원본 시작일(7/22)이 아니라 오늘(8/5)의 회차로 전개돼야 한다.
    expect(occurrence.startAt.toISOString()).toBe('2026-08-05T01:00:00.000Z');
    expect(occurrence.startAt.getTime()).not.toBe(recurringEvent.startAt.getTime());
  });

  it('반복 일정 회차와 일반 일정을 함께 조회하면 시작 시각순으로 정렬해 반환한다', async () => {
    const now = new Date('2026-08-05T10:00:00.000Z');
    const recurringEvent = makeEvent({
      id: 'weekly-1',
      title: '주간 스탠드업',
      startAt: new Date('2026-07-22T00:30:00.000Z'), // 09:30 KST
      endAt: new Date('2026-07-22T01:00:00.000Z'),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
    });
    const oneOffEvent = makeEvent({
      id: 'evt-2',
      title: '점심 약속',
      startAt: new Date('2026-08-05T03:00:00.000Z'), // 12:00 KST
      endAt: new Date('2026-08-05T04:00:00.000Z'),
    });
    const repository = makeMockRepository({
      listEvents: vi.fn().mockResolvedValue({ data: [oneOffEvent, recurringEvent], error: null }),
    });

    const result = await loadTodayEvents(repository, now);

    expect(result.events.map((event) => event.id)).toEqual(['weekly-1', 'evt-2']);
  });
});

describe('TodayEventList (렌더링)', () => {
  it('일정이 있으면 시간순으로 항목을 렌더링한다', () => {
    const events = [
      makeEvent({
        id: 'evt-1',
        title: '아침 회의',
        startAt: new Date('2026-08-05T00:00:00.000Z'), // 09:00 KST
        endAt: new Date('2026-08-05T01:00:00.000Z'), // 10:00 KST
      }),
      makeEvent({
        id: 'evt-2',
        title: '저녁 약속',
        startAt: new Date('2026-08-05T10:00:00.000Z'), // 19:00 KST
        endAt: null,
      }),
    ];

    const html = renderTodayEventList(events);

    expect(html).toContain('아침 회의');
    expect(html).toContain('저녁 약속');
    expect(html).toContain('09:00');
    expect(html).toContain('10:00');
    expect(html).toContain('19:00');
    expect(html).not.toContain('오늘 일정이 없습니다');
  });

  it('종일 일정은 하루 종일로 표시한다', () => {
    const events = [
      makeEvent({ id: 'evt-1', title: '워크숍', isAllDay: true }),
    ];

    const html = renderTodayEventList(events);

    expect(html).toContain('하루 종일');
  });

  it('is_critical 일정은 별도 클래스로 시각적으로 구분된다', () => {
    const events = [
      makeEvent({ id: 'evt-1', title: '중요 미팅', isCritical: true }),
      makeEvent({ id: 'evt-2', title: '일반 미팅', isCritical: false }),
    ];

    const html = renderTodayEventList(events);

    expect(html).toContain('today-event-list__item--critical');
    // 일반 일정 항목은 critical 클래스가 붙지 않아야 한다.
    const normalItemMatch = html.match(
      /<li class="today-event-list__item"[^>]*>[\s\S]*?일반 미팅/,
    );
    expect(normalItemMatch).not.toBeNull();
  });

  it('일정이 없으면 빈 상태 문구를 렌더링한다', () => {
    const html = renderTodayEventList([]);

    expect(html).toContain('오늘 일정이 없습니다');
    expect(html).not.toContain('today-event-list__item');
  });

  it('각 일정 항목이 /event/:id로 이동하는 링크로 감싸진다(P2: 상세 화면 진입 경로 부재 수정)', () => {
    const events = [
      makeEvent({ id: 'evt-abc', title: '아침 회의' }),
      makeEvent({ id: 'evt-xyz', title: '저녁 약속' }),
    ];

    const html = renderTodayEventList(events);

    expect(html).toContain('href="/event/evt-abc"');
    expect(html).toContain('href="/event/evt-xyz"');
    // 기존 시간/제목 span 클래스는 링크 안에서도 그대로 유지되어야 한다(시각 회귀 방지).
    expect(html).toContain('today-event-list__time');
    expect(html).toContain('today-event-list__title');
    expect(html).toContain('today-event-list__link');
  });

  it('critical 일정도 today-event-list__item--critical 클래스를 유지한 채 링크를 갖는다', () => {
    const events = [makeEvent({ id: 'evt-critical', title: '중요 미팅', isCritical: true })];

    const html = renderTodayEventList(events);

    expect(html).toContain('today-event-list__item--critical');
    expect(html).toContain('href="/event/evt-critical"');
  });

  it('빈 일정 배열이면 링크 없이 EmptyState만 렌더링한다(회귀 없음)', () => {
    const html = renderTodayEventList([]);

    expect(html).toContain('오늘 일정이 없습니다');
    expect(html).not.toContain('<a');
    expect(html).not.toContain('today-event-list__link');
  });
});
