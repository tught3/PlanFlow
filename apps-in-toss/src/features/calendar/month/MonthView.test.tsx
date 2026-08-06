/**
 * MonthView의 순수 함수(buildMonthGrid/buildMonthDayEvents)만 검증한다.
 * 이 저장소에는 jsdom/@testing-library가 설치돼 있지 않으므로 컴포넌트를
 * 실제로 렌더링하지 않는다 - 그리드 계산과 날짜별 일정 배치 로직을 순수
 * 함수로 분리해 직접 호출하는 방식으로 테스트한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it } from 'vitest';

import { MonthCellChips, buildMonthDayEvents, buildMonthGrid } from './MonthView.tsx';
import type { MonthDayEventEntry } from './MonthView.tsx';
import type { Event } from '../../../domain/index.ts';
import { kstIsoWeekday, kstMonthRange, kstWallToInstant } from '../../../domain/index.ts';

/**
 * MonthCellChips는 각 일정 칩을 react-router-dom의 <Link>로 감싼다. 이
 * 저장소에는 jsdom이 없어 renderToStaticMarkup으로만 렌더링을 검증하는데,
 * <Link>는 라우터 컨텍스트 없이 렌더링하면 예외를 던지므로 항상
 * MemoryRouter로 감싸서 렌더링한다(TodayEventList.tsx/WeekDayEventList와
 * 동일한 패턴).
 */
function renderMonthCellChips(entries: MonthDayEventEntry[], maxChips?: number): string {
  return renderToStaticMarkup(
    <MemoryRouter>
      <MonthCellChips entries={entries} maxChips={maxChips} />
    </MemoryRouter>,
  );
}

function makeEntry(overrides: Partial<MonthDayEventEntry> = {}, eventOverrides: Partial<Event> = {}): MonthDayEventEntry {
  return {
    event: makeEvent(eventOverrides),
    isSpanStart: true,
    isSpanEnd: true,
    ...overrides,
  };
}

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

  it('첫째 주 경계: 월 시작 요일이 일요일이 아니면 이전 달 날짜가 그리드 앞부분에 포함된다', () => {
    // April 1, 2026은 수요일(ISO weekday 3)이라 반드시 이전 달(3월) 날짜가 앞에 붙는다.
    const april = kstWallToInstant(2026, 3, 15);
    const { start: monthStart } = kstMonthRange(april);
    expect(kstIsoWeekday(monthStart)).not.toBe(7);

    const grid = buildMonthGrid(april);
    expect(grid[0].isCurrentMonth).toBe(false);
    expect(grid[0].date.getTime()).toBeLessThan(monthStart.getTime());
    // 그리드는 항상 일요일부터 시작해야 한다(weekStartsOn 기본값 7=일요일,
    // 원본 Flutter calendar_widgets.dart의 일요일 시작 관례와 동일).
    expect(kstIsoWeekday(grid[0].date)).toBe(7);

    // 실제 경계값: 2026-03-29(일)부터 시작해야 한다.
    const expectedGridStart = kstWallToInstant(2026, 2, 29);
    expect(grid[0].date.getTime()).toBe(expectedGridStart.getTime());
  });

  it('마지막 주 경계: 월 마지막 날 요일이 토요일이 아니면 다음 달 날짜가 그리드 뒷부분에 포함된다', () => {
    // March 31, 2026은 화요일(ISO weekday 2)이라 반드시 다음 달(4월) 날짜가 뒤에 붙는다.
    const march = kstWallToInstant(2026, 2, 15);
    const grid = buildMonthGrid(march);
    const lastDay = grid[grid.length - 1];

    expect(lastDay.isCurrentMonth).toBe(false);
    // 그리드는 항상 토요일에 끝나야 한다(일요일 시작 기준 주의 마지막 요일).
    expect(kstIsoWeekday(lastDay.date)).toBe(6);

    // 실제 경계값: 2026-04-04(토)로 끝나야 한다.
    const expectedLastDay = kstWallToInstant(2026, 3, 4);
    expect(lastDay.date.getTime()).toBe(expectedLastDay.getTime());
  });

  it('월 시작/마지막 요일이 각각 일요일/토요일이면 앞뒤로 걸치는 날짜가 없다', () => {
    // 2026-02-01은 일요일, 2026-02-28은 토요일이라 앞뒤로 걸치는 날짜가 없어야 한다.
    const february = kstWallToInstant(2026, 1, 10);
    const { start: febStart } = kstMonthRange(february);
    expect(kstIsoWeekday(febStart)).toBe(7);

    const grid = buildMonthGrid(february);
    expect(grid[0].date.getTime()).toBe(febStart.getTime());
    expect(grid[0].isCurrentMonth).toBe(true);
    expect(kstIsoWeekday(grid[grid.length - 1].date)).toBe(6);
    expect(grid[grid.length - 1].isCurrentMonth).toBe(true);
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

describe('MonthCellChips (렌더링)', () => {
  it('실제 일정 칩은 /event/:id로 이동하는 링크로 감싸진다(P3: 월간뷰 상세 진입 경로 부재 수정)', () => {
    const entries = [
      makeEntry({}, { id: 'evt-abc', title: '아침 회의' }),
      makeEntry({}, { id: 'evt-xyz', title: '저녁 약속' }),
    ];

    const html = renderMonthCellChips(entries);

    expect(html).toContain('href="/event/evt-abc"');
    expect(html).toContain('href="/event/evt-xyz"');
    // 기존 클래스는 링크 도입 후에도 그대로 유지되어야 한다(시각 회귀 방지).
    expect(html).toContain('month-view__chip');
    expect(html).toContain('month-view__chip-link');
  });

  it('overflow(+N) 표시는 특정 일정 하나를 가리키지 않으므로 링크로 감싸지 않는다', () => {
    const entries = [
      makeEntry({}, { id: 'evt-1', title: '일정1' }),
      makeEntry({}, { id: 'evt-2', title: '일정2' }),
      makeEntry({}, { id: 'evt-3', title: '일정3' }),
      makeEntry({}, { id: 'evt-4', title: '일정4' }),
    ];

    const html = renderMonthCellChips(entries, 3);

    expect(html).toContain('month-view__overflow');
    expect(html).toContain('+1');
    // overflow 문자열 "+1"이 <a href="/event/...">...</a> 안에 들어있지 않은지
    // 확인한다 - overflow div 자체가 Link로 감싸지지 않아야 한다.
    const overflowMatch = html.match(/<div class="month-view__overflow">([\s\S]*?)<\/div>/);
    expect(overflowMatch).not.toBeNull();
    expect(overflowMatch?.[1]).not.toContain('<a');

    // 처음 3개(maxChips)만 실제 칩으로 렌더링되고 4번째는 overflow에 흡수된다.
    expect(html).toContain('href="/event/evt-1"');
    expect(html).toContain('href="/event/evt-2"');
    expect(html).toContain('href="/event/evt-3"');
    expect(html).not.toContain('href="/event/evt-4"');
  });

  it('critical 일정도 month-view__chip--critical 클래스를 유지한 채 링크를 갖는다', () => {
    const entries = [makeEntry({}, { id: 'evt-critical', title: '마감일', isCritical: true })];

    const html = renderMonthCellChips(entries);

    expect(html).toContain('month-view__chip--critical');
    expect(html).toContain('href="/event/evt-critical"');
  });

  it('다일(span) 일정의 span-start/span-mid/span-end 보조 클래스가 Link로 감싼 뒤에도 유지된다', () => {
    const startEntry = makeEntry({ isSpanStart: true, isSpanEnd: false }, { id: 'multi-1', title: '워크샵' });
    const midEntry = makeEntry({ isSpanStart: false, isSpanEnd: false }, { id: 'multi-1', title: '워크샵' });
    const endEntry = makeEntry({ isSpanStart: false, isSpanEnd: true }, { id: 'multi-1', title: '워크샵' });

    expect(renderMonthCellChips([startEntry])).toContain('month-view__chip--span-start');
    expect(renderMonthCellChips([midEntry])).toContain('month-view__chip--span-mid');
    expect(renderMonthCellChips([endEntry])).toContain('month-view__chip--span-end');
  });

  it('빈 entries면 칩도 overflow도 렌더링하지 않는다(빈 날짜 셀 회귀 없음)', () => {
    const html = renderMonthCellChips([]);

    expect(html).not.toContain('<a');
    expect(html).not.toContain('month-view__chip');
    expect(html).not.toContain('month-view__overflow');
  });

  it('같은 event.id를 가진 서로 다른 회차(반복 일정)도 key 충돌 없이 각자 렌더링된다', () => {
    // 반복 일정 전개(copyEventWithTime)는 원본 event.id를 그대로 유지하므로
    // (src/domain/recurrence.ts), 같은 셀 안에 같은 id의 회차가 두 번 있어도
    // startAt이 다르면 키가 겹치지 않아야 한다.
    const entries = [
      makeEntry({}, { id: 'weekly-1', title: '아침 스탠드업', startAt: kstWallToInstant(2026, 2, 10, 9, 0, 0) }),
      makeEntry({}, { id: 'weekly-1', title: '저녁 스탠드업', startAt: kstWallToInstant(2026, 2, 10, 19, 0, 0) }),
    ];

    const html = renderMonthCellChips(entries);

    expect(html).toContain('아침 스탠드업');
    expect(html).toContain('저녁 스탠드업');
    const linkCount = html.split('href="/event/weekly-1"').length - 1;
    expect(linkCount).toBe(2);
  });
});
