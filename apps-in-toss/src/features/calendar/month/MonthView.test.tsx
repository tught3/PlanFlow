/**
 * MonthView의 순수 함수(buildMonthGrid/buildMonthDayEvents)만 검증한다.
 * 이 저장소에는 jsdom/@testing-library가 설치돼 있지 않으므로 컴포넌트를
 * 실제로 렌더링하지 않는다 - 그리드 계산과 날짜별 일정 배치 로직을 순수
 * 함수로 분리해 직접 호출하는 방식으로 테스트한다.
 */
import { describe, expect, it } from 'vitest';

import { buildMonthDayEvents, buildMonthGrid } from './MonthView.tsx';
import type { Event } from '../../../domain/index.ts';
import { kstIsoWeekday, kstMonthRange, kstWallToInstant } from '../../../domain/index.ts';

const DAY_MS = 24 * 60 * 60 * 1000;

function makeEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-1',
    userId: 'user-1',
    title: '테스트 일정',
    startAt: kstWallToInstant(2026, 2, 10, 9, 0, 0),
    endAt: kstWallToInstant(2026, 2, 10, 10, 0, 0),
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

describe('buildMonthGrid', () => {
  it('항상 완전한 주 단위(7의 배수)로 그리드를 만든다', () => {
    // 2026-03 (March 1이 일요일, 3/31이 화요일 - 앞뒤 모두 걸치는 전형적인 케이스)
    const march = kstWallToInstant(2026, 2, 15);
    expect(buildMonthGrid(march).length % 7).toBe(0);

    // 2026-02 (Feb 2026, 윤년 아님, 28일 - 앞은 6일, 뒤는 1일만 걸치는 비대칭 케이스)
    const feb = kstWallToInstant(2026, 1, 15);
    expect(buildMonthGrid(feb).length % 7).toBe(0);
  });

  it('연속된 날짜로 구성되고(하루도 빠지거나 중복되지 않음) isCurrentMonth가 실제 월과 일치한다', () => {
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);
    const { start: monthStart, end: monthEnd } = kstMonthRange(march);

    for (let i = 1; i < grid.length; i += 1) {
      expect(grid[i].date.getTime() - grid[i - 1].date.getTime()).toBe(DAY_MS);
    }

    for (const day of grid) {
      const inMonth = day.date.getTime() >= monthStart.getTime() && day.date.getTime() < monthEnd.getTime();
      expect(day.isCurrentMonth).toBe(inMonth);
    }
  });

  it('첫째 주 경계: 월 시작 요일이 월요일이 아니면 이전 달 날짜가 그리드 앞부분에 포함된다', () => {
    // March 1, 2026은 일요일(ISO weekday 7)이라 반드시 이전 달(2월) 날짜가 앞에 붙는다.
    const march = kstWallToInstant(2026, 2, 15);
    const { start: monthStart } = kstMonthRange(march);
    expect(kstIsoWeekday(monthStart)).not.toBe(1);

    const grid = buildMonthGrid(march);
    expect(grid[0].isCurrentMonth).toBe(false);
    expect(grid[0].date.getTime()).toBeLessThan(monthStart.getTime());
    // 그리드는 항상 월요일부터 시작해야 한다(weekStartsOn 기본값 1).
    expect(kstIsoWeekday(grid[0].date)).toBe(1);

    // 실제 경계값: 2026-02-23(월)부터 시작해야 한다.
    const expectedGridStart = kstWallToInstant(2026, 1, 23);
    expect(grid[0].date.getTime()).toBe(expectedGridStart.getTime());
  });

  it('마지막 주 경계: 월 마지막 날 요일이 일요일이 아니면 다음 달 날짜가 그리드 뒷부분에 포함된다', () => {
    // March 31, 2026은 화요일(ISO weekday 2)이라 반드시 다음 달(4월) 날짜가 뒤에 붙는다.
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);
    const lastDay = grid[grid.length - 1];

    expect(lastDay.isCurrentMonth).toBe(false);
    expect(kstIsoWeekday(lastDay.date)).toBe(7);

    // 실제 경계값: 2026-04-05(일)로 끝나야 한다.
    const expectedLastDay = kstWallToInstant(2026, 3, 5);
    expect(lastDay.date.getTime()).toBe(expectedLastDay.getTime());
  });

  it('월 시작/마지막 요일이 각각 월요일/일요일이면 앞뒤로 걸치는 날짜가 없다', () => {
    // 위에서 계산된 2026-02 그리드 시작일(2026-01-26, 월)이 속한 1월을 기준으로,
    // "이번 달 1일이 월요일"인 케이스를 직접 만들어 확인한다.
    // 2026-06-01은 월요일이다.
    const june = kstWallToInstant(2026, 5, 10);
    const { start: juneStart } = kstMonthRange(june);
    expect(kstIsoWeekday(juneStart)).toBe(1);

    const grid = buildMonthGrid(june);
    expect(grid[0].date.getTime()).toBe(juneStart.getTime());
    expect(grid[0].isCurrentMonth).toBe(true);
  });
});

describe('buildMonthDayEvents', () => {
  it('다일(multi-day) 일정이 시작일뿐 아니라 걸치는 모든 날짜 셀에 나타난다', () => {
    // 2026-03-30 09:00 ~ 2026-04-02 09:00 (월 경계를 넘는 4일짜리 일정)
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);

    const multiDayEvent = makeEvent({
      id: 'multi-1',
      title: '워크샵',
      startAt: kstWallToInstant(2026, 2, 30, 9, 0, 0),
      endAt: kstWallToInstant(2026, 3, 2, 9, 0, 0),
      isMultiDay: true,
    });

    const dayEvents = buildMonthDayEvents(grid, [multiDayEvent]);

    const findIndex = (y: number, m: number, d: number) =>
      grid.findIndex((day) => day.date.getTime() === kstWallToInstant(y, m, d).getTime());

    const mar30 = findIndex(2026, 2, 30);
    const mar31 = findIndex(2026, 2, 31);
    const apr1 = findIndex(2026, 3, 1);
    const apr2 = findIndex(2026, 3, 2);
    const mar29 = findIndex(2026, 2, 29);
    const apr3 = findIndex(2026, 3, 3);

    expect([mar30, mar31, apr1, apr2, mar29, apr3].every((i) => i >= 0)).toBe(true);

    // 걸치는 4일 모두에 이벤트가 나타난다.
    expect(dayEvents[mar30].map((e) => e.event.id)).toContain('multi-1');
    expect(dayEvents[mar31].map((e) => e.event.id)).toContain('multi-1');
    expect(dayEvents[apr1].map((e) => e.event.id)).toContain('multi-1');
    expect(dayEvents[apr2].map((e) => e.event.id)).toContain('multi-1');

    // 전날/다음날에는 나타나지 않는다.
    expect(dayEvents[mar29].map((e) => e.event.id)).not.toContain('multi-1');
    expect(dayEvents[apr3].map((e) => e.event.id)).not.toContain('multi-1');

    // 시작일에만 isSpanStart=true, 종료일에만 isSpanEnd=true (중간일은 연속 표시용으로 둘 다 false).
    expect(dayEvents[mar30][0]).toMatchObject({ isSpanStart: true, isSpanEnd: false });
    expect(dayEvents[mar31][0]).toMatchObject({ isSpanStart: false, isSpanEnd: false });
    expect(dayEvents[apr1][0]).toMatchObject({ isSpanStart: false, isSpanEnd: false });
    expect(dayEvents[apr2][0]).toMatchObject({ isSpanStart: false, isSpanEnd: true });
  });

  it('중요일정(isCritical)과 일반일정을 함께 반환하며 날짜별로 정확히 분리된다', () => {
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);

    const criticalEvent = makeEvent({
      id: 'critical-1',
      title: '마감일',
      startAt: kstWallToInstant(2026, 2, 10, 9, 0, 0),
      endAt: kstWallToInstant(2026, 2, 10, 10, 0, 0),
      isCritical: true,
    });
    const normalEvent = makeEvent({
      id: 'normal-1',
      title: '점심약속',
      startAt: kstWallToInstant(2026, 2, 11, 12, 0, 0),
      endAt: kstWallToInstant(2026, 2, 11, 13, 0, 0),
      isCritical: false,
    });

    const dayEvents = buildMonthDayEvents(grid, [criticalEvent, normalEvent]);

    const mar10 = grid.findIndex((day) => day.date.getTime() === kstWallToInstant(2026, 2, 10).getTime());
    const mar11 = grid.findIndex((day) => day.date.getTime() === kstWallToInstant(2026, 2, 11).getTime());

    expect(dayEvents[mar10]).toHaveLength(1);
    expect(dayEvents[mar10][0].event.isCritical).toBe(true);
    expect(dayEvents[mar11]).toHaveLength(1);
    expect(dayEvents[mar11][0].event.isCritical).toBe(false);
  });

  it('그리드 범위와 겹치는 회차만 반복일정(recurrenceRule)에서 전개해 배치한다', () => {
    // 2026-03-02(월)부터 매주 월요일 반복. 3월 그리드(2/23~4/5) 안에서 여러 회차가 걸린다.
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);

    const weekly = makeEvent({
      id: 'weekly-1',
      title: '주간회의',
      startAt: kstWallToInstant(2026, 2, 2, 9, 0, 0),
      endAt: kstWallToInstant(2026, 2, 2, 10, 0, 0),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
    });

    const dayEvents = buildMonthDayEvents(grid, [weekly]);
    const mondayIndices = grid
      .map((day, index) => ({ index, isMonday: kstIsoWeekday(day.date) === 1 }))
      .filter((entry) => entry.isMonday)
      .map((entry) => entry.index);

    // 시작일(2026-03-02) 이후의 월요일 셀에는 매번 회차가 하나씩 있어야 한다.
    const startTime = kstWallToInstant(2026, 2, 2).getTime();
    for (const mondayIndex of mondayIndices) {
      const dayDate = grid[mondayIndex].date.getTime();
      if (dayDate < startTime) {
        expect(dayEvents[mondayIndex].map((e) => e.event.id)).not.toContain('weekly-1');
      } else {
        expect(dayEvents[mondayIndex].map((e) => e.event.id)).toContain('weekly-1');
      }
    }

    // 월요일이 아닌 날짜에는 나타나지 않는다.
    const nonMonday = grid.findIndex((day) => kstIsoWeekday(day.date) !== 1);
    expect(dayEvents[nonMonday].map((e) => e.event.id)).not.toContain('weekly-1');
  });

  it('gridDays가 비어 있으면 빈 배열을 반환한다', () => {
    expect(buildMonthDayEvents([], [makeEvent()])).toEqual([]);
  });
});
