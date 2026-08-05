/**
 * WeekView 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library가 아직 설치되어 있지 않으므로(다른
 * 병렬 작업과의 package.json 충돌을 피하기 위해 이 작업에서는 추가하지 않음),
 * 렌더링 스모크 테스트는 `react-dom/server`의 renderToStaticMarkup으로
 * 수행한다. 이 방식은 useEffect를 실행하지 않으므로(SSR과 동일하게 동작)
 * eventRepository의 실제 네트워크 호출 없이 초기 렌더 결과만 검증한다.
 * 주 이동 로직은 컴포넌트에서 분리해 내보낸 순수 함수(getWeekStart/
 * getWeekDays/shiftWeek)로 직접 검증한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';

import type { Event } from '../../../domain/event.ts';
import { kstIsoWeekday } from '../../../domain/datetime.ts';
import WeekView, {
  buildWeekDayEvents,
  formatMonthDay,
  getWeekDays,
  getWeekStart,
  shiftWeek,
} from './WeekView.tsx';

function makeEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-1',
    userId: 'user-1',
    title: '테스트 일정',
    startAt: new Date('2026-03-11T01:00:00.000Z'), // 10:00 KST 수요일
    endAt: new Date('2026-03-11T02:00:00.000Z'),
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
    createdAt: null,
    updatedAt: null,
    ...overrides,
  };
}

describe('getWeekStart', () => {
  it('어떤 요일을 넣어도 그 주의 일요일 00:00 KST를 반환한다', () => {
    // 2026-03-11(수) 12:00 KST == 2026-03-11T03:00:00.000Z
    const wednesday = new Date('2026-03-11T03:00:00.000Z');
    const weekStart = getWeekStart(wednesday);

    expect(kstIsoWeekday(weekStart)).toBe(7); // 7 = 일요일(ISO weekday)
    // 2026-03-08(일) 00:00 KST == 2026-03-07T15:00:00.000Z
    expect(weekStart.toISOString()).toBe('2026-03-07T15:00:00.000Z');
  });

  it('입력이 이미 일요일이면 그대로(그 날 자정)를 반환한다', () => {
    // 2026-03-08(일) 09:00 KST == 2026-03-08T00:00:00.000Z
    const sunday = new Date('2026-03-08T00:00:00.000Z');
    const weekStart = getWeekStart(sunday);

    expect(weekStart.toISOString()).toBe('2026-03-07T15:00:00.000Z');
  });
});

describe('getWeekDays', () => {
  it('일요일부터 토요일까지 연속 7일을 반환한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const days = getWeekDays(weekStart);

    expect(days).toHaveLength(7);
    expect(days.map((day) => kstIsoWeekday(day))).toEqual([7, 1, 2, 3, 4, 5, 6]);

    for (let i = 1; i < days.length; i += 1) {
      const diffMs = days[i].getTime() - days[i - 1].getTime();
      expect(diffMs).toBe(24 * 60 * 60 * 1000);
    }
  });
});

describe('shiftWeek (주 이동)', () => {
  it('delta=1이면 정확히 7일 뒤 같은 요일(다음 주 일요일)로 이동한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const nextWeekStart = shiftWeek(weekStart, 1);

    expect(nextWeekStart.getTime() - weekStart.getTime()).toBe(7 * 24 * 60 * 60 * 1000);
    expect(kstIsoWeekday(nextWeekStart)).toBe(7);
  });

  it('delta=-1이면 정확히 7일 전(이전 주 일요일)로 이동한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const prevWeekStart = shiftWeek(weekStart, -1);

    expect(weekStart.getTime() - prevWeekStart.getTime()).toBe(7 * 24 * 60 * 60 * 1000);
    expect(kstIsoWeekday(prevWeekStart)).toBe(7);
  });

  it('연속 이동(다음주 -> 이전주 -> 이전주)은 최초 위치에서 1주 전과 같다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const roundTrip = shiftWeek(shiftWeek(shiftWeek(weekStart, 1), -1), -1);

    expect(roundTrip.getTime()).toBe(shiftWeek(weekStart, -1).getTime());
  });
});

describe('formatMonthDay', () => {
  it('KST 기준 M/D 형태로 포맷한다', () => {
    // 2026-03-08 00:00 KST
    expect(formatMonthDay(new Date('2026-03-07T15:00:00.000Z'))).toBe('3/8');
  });
});

describe('buildWeekDayEvents', () => {
  it('매주 반복 일정은 이번 주 범위와 겹치는 회차로 전개되어 해당 요일 칸에 배치된다', () => {
    // 이번 주(일 3/8 ~ 토 3/14) 중 수요일은 3/11. 원본 반복 일정은 2주 전
    // 수요일(2026-02-25)에 시작해 매주 수요일 반복한다 - buildWeekDayEvents는
    // 원본 회차가 아니라 이번 주의 회차로 전개해서 배치해야 한다.
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const weekDays = getWeekDays(weekStart);

    const recurringEvent = makeEvent({
      id: 'weekly-1',
      title: '주간 스탠드업',
      startAt: new Date('2026-02-25T01:00:00.000Z'), // 10:00 KST 수요일(원본 시작일)
      endAt: new Date('2026-02-25T01:30:00.000Z'),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
    });

    const dayEvents = buildWeekDayEvents(weekDays, [recurringEvent]);

    // 수요일(index 3)에만 이번 주 회차가 있어야 한다.
    expect(dayEvents[3].map((e) => e.id)).toEqual(['weekly-1']);
    expect(dayEvents[3][0].startAt.toISOString()).toBe('2026-03-11T01:00:00.000Z');
    // 원본 시작일(2/25)이 아니라 이번 주 회차이므로 startAt이 원본과 다르다.
    expect(dayEvents[3][0].startAt.getTime()).not.toBe(recurringEvent.startAt.getTime());

    // 다른 요일에는 나타나지 않는다.
    for (let i = 0; i < weekDays.length; i += 1) {
      if (i === 3) {
        continue;
      }
      expect(dayEvents[i].map((e) => e.id)).not.toContain('weekly-1');
    }
  });

  it('반복 일정 회차와 일반 일정이 같은 요일에 있으면 시작 시각순으로 정렬한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const weekDays = getWeekDays(weekStart);

    const recurringEvent = makeEvent({
      id: 'weekly-1',
      title: '주간 스탠드업',
      startAt: new Date('2026-02-25T00:30:00.000Z'), // 09:30 KST 수요일
      endAt: new Date('2026-02-25T01:00:00.000Z'),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
    });
    const oneOffEvent = makeEvent({
      id: 'evt-2',
      title: '점심 약속',
      startAt: new Date('2026-03-11T03:00:00.000Z'), // 12:00 KST 수요일
      endAt: new Date('2026-03-11T04:00:00.000Z'),
    });

    const dayEvents = buildWeekDayEvents(weekDays, [oneOffEvent, recurringEvent]);

    expect(dayEvents[3].map((e) => e.id)).toEqual(['weekly-1', 'evt-2']);
  });

  it('weekDays가 비어 있으면 빈 배열을 반환한다', () => {
    expect(buildWeekDayEvents([], [makeEvent()])).toEqual([]);
  });
});

describe('WeekView 기본 렌더링', () => {
  it('주간 캘린더 섹션과 이동 버튼, 요일 7칸을 렌더링한다', () => {
    const html = renderToStaticMarkup(
      <WeekView initialDate={new Date('2026-03-11T03:00:00.000Z')} />,
    );

    expect(html).toContain('주간 캘린더');
    expect(html).toContain('이전 주');
    expect(html).toContain('다음 주');
    expect(html).toContain('3/8 - 3/14');

    for (let i = 0; i < 7; i += 1) {
      expect(html).toContain(`data-testid="week-day-${i}"`);
    }

    const weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];
    for (const label of weekdayLabels) {
      expect(html).toContain(`>${label}<`);
    }
  });

  it('initialDate 없이도 예외 없이 렌더링된다(기본값은 현재 시각)', () => {
    const html = renderToStaticMarkup(<WeekView />);
    expect(html).toContain('주간 캘린더');
  });
});
