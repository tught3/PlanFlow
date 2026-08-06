/**
 * 월간 캘린더 뷰.
 *
 * 그리드 계산(buildMonthGrid)과 날짜별 일정 배치(buildMonthDayEvents)는 순수
 * 함수로 분리해 export한다 - 테스트(MonthView.test.tsx)는 DOM 렌더링 없이
 * 이 함수들만 직접 검증한다(이 저장소에는 jsdom/@testing-library가 설치돼
 * 있지 않다).
 *
 * 반복 일정 전개는 src/domain/recurrence.ts의 expandOccurrences()를 그대로
 * 쓰고, 다일(multi-day)/기본 길이 판정은 eventOverlapEndFor()를 그대로 쓴다.
 * 날짜 계산(월/주 범위, 일 더하기 등)은 src/domain/datetime.ts만 쓴다.
 */
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';

import {
  addKstDays,
  addKstMonths,
  eventOverlapEndFor,
  eventRangesOverlap,
  expandOccurrences,
  isSameKstDay,
  kstMonthRange,
  kstWeekRange,
  toKstWall,
} from '../../../domain/index.ts';
import type { Event } from '../../../domain/index.ts';
import { eventRepository as defaultEventRepository } from '../../../data/eventRepository.ts';
import type { EventRepository } from '../../../data/eventRepository.ts';
import { Spinner, ErrorMessage } from '../../../components/index.ts';

const DAY_MS = 24 * 60 * 60 * 1000;
/** 한 셀에 표시할 최대 일정 칩 수(초과분은 month-view__overflow로 +N 표시). */
const MAX_CHIPS_PER_CELL = 3;
/**
 * 주 시작 요일은 원본(Flutter) lib/screens/calendar/calendar_widgets.dart의
 * `weekdayLabels = ['일', '월', '화', '수', '목', '금', '토']`(일요일 시작)와
 * WeekView.tsx(ISO weekday 7 = 일요일 시작)에 맞춘다.
 */
const WEEKDAY_LABELS = ['일', '월', '화', '수', '목', '금', '토'];

export interface MonthGridDay {
  /** 이 날짜의 KST 자정(00:00 KST)을 나타내는 실제 UTC Date. */
  date: Date;
  /** buildMonthGrid에 넘긴 monthAnchor가 속한 달에 실제로 속하는 날짜인지. */
  isCurrentMonth: boolean;
}

export interface MonthDayEventEntry {
  /** 반복 일정이면 해당 회차로 전개된 Event(원본이 아니라 occurrence). */
  event: Event;
  /** 이 날짜 셀이 일정의 실제 시작일인지(연속 표시 시 좌측 모서리 처리용). */
  isSpanStart: boolean;
  /** 이 날짜 셀이 일정의 실제 종료일인지(연속 표시 시 우측 모서리 처리용). */
  isSpanEnd: boolean;
}

/**
 * monthAnchor가 속한 달의 월간 캘린더 그리드를 만든다. 항상 완전한 주
 * 단위(7의 배수)로 반환하며, 이번 달 앞/뒤로 걸치는 이전/다음 달 날짜도
 * 포함한다(isCurrentMonth=false로 표시).
 */
export function buildMonthGrid(monthAnchor: Date, weekStartsOn = 7): MonthGridDay[] {
  const { start: monthStart, end: monthEnd } = kstMonthRange(monthAnchor);
  const { start: gridStart } = kstWeekRange(monthStart, { weekStartsOn });
  const lastDayOfMonth = new Date(monthEnd.getTime() - DAY_MS);
  const { end: gridEnd } = kstWeekRange(lastDayOfMonth, { weekStartsOn });

  const days: MonthGridDay[] = [];
  let cursor = gridStart;
  while (cursor.getTime() < gridEnd.getTime()) {
    days.push({
      date: cursor,
      isCurrentMonth:
        cursor.getTime() >= monthStart.getTime() && cursor.getTime() < monthEnd.getTime(),
    });
    cursor = addKstDays(cursor, 1);
  }
  return days;
}

/**
 * gridDays 각 날짜에 걸치는 일정 목록을 계산한다(반환 배열은 gridDays와
 * 같은 길이/순서). 반복 일정은 그리드 범위로 expandOccurrences 전개하고,
 * 다일 일정은 겹치는 모든 날짜 셀에 함께 나타난다(시작일에만 나타나지
 * 않는다).
 */
export function buildMonthDayEvents(
  gridDays: MonthGridDay[],
  events: Event[],
): MonthDayEventEntry[][] {
  if (gridDays.length === 0) {
    return [];
  }

  const gridStart = gridDays[0].date;
  const gridEnd = addKstDays(gridDays[gridDays.length - 1].date, 1);

  const perDay: MonthDayEventEntry[][] = gridDays.map(() => []);

  for (const event of events) {
    const occurrences = expandOccurrences(event, gridStart, gridEnd);
    for (const occurrence of occurrences) {
      const occStart = occurrence.startAt;
      const occEnd = eventOverlapEndFor(occurrence);

      for (let i = 0; i < gridDays.length; i += 1) {
        const dayStart = gridDays[i].date;
        const dayEnd = addKstDays(dayStart, 1);
        const overlaps = eventRangesOverlap({
          rangeStart: dayStart,
          rangeEnd: dayEnd,
          eventStart: occStart,
          eventEnd: occEnd,
        });
        if (!overlaps) {
          continue;
        }
        perDay[i].push({
          event: occurrence,
          isSpanStart: occStart.getTime() >= dayStart.getTime(),
          isSpanEnd: occEnd.getTime() <= dayEnd.getTime(),
        });
      }
    }
  }

  for (const dayEvents of perDay) {
    dayEvents.sort((a, b) => a.event.startAt.getTime() - b.event.startAt.getTime());
  }

  return perDay;
}

function kstDayNumber(date: Date): number {
  return toKstWall(date).getUTCDate();
}

function monthLabel(monthAnchor: Date): string {
  const wall = toKstWall(monthAnchor);
  return `${wall.getUTCFullYear()}년 ${wall.getUTCMonth() + 1}월`;
}

/**
 * span 연속 표시용 보조 클래스. 하루짜리 일정(시작=종료)은 기본
 * month-view__chip 모서리를 그대로 쓰고, 여러 날에 걸치는 일정만 시작/중간/
 * 종료 구간별로 모서리를 다르게 처리한다.
 */
function monthChipSpanClassName(entry: MonthDayEventEntry): string | null {
  if (entry.isSpanStart && entry.isSpanEnd) {
    return null;
  }
  if (entry.isSpanStart) {
    return 'month-view__chip--span-start';
  }
  if (entry.isSpanEnd) {
    return 'month-view__chip--span-end';
  }
  return 'month-view__chip--span-mid';
}

export interface MonthCellChipsProps {
  /** buildMonthDayEvents가 계산한 한 날짜 셀의 전체 항목(overflow 절단 전). */
  entries: MonthDayEventEntry[];
  /** 한 셀에 표시할 최대 칩 수. 기본값은 MAX_CHIPS_PER_CELL. */
  maxChips?: number;
}

/**
 * 하루(날짜 셀) 안의 일정 칩 목록을 렌더링하는 순수(presentational) 컴포넌트.
 *
 * MonthView.tsx 자체는 useEffect로 eventRepository를 호출해 데이터를
 * 조회하므로(jsdom이 없는 이 저장소에서) renderToStaticMarkup으로는 effect가
 * 실행되지 않아 조회된 events를 안정적으로 검증할 수 없다. 이미 계산된
 * entries만 받는 이 컴포넌트를 별도로 두면 WeekDayEventList.tsx와 동일한
 * 방식으로 MemoryRouter + renderToStaticMarkup으로 격리 테스트할 수 있다.
 *
 * "+N" overflow 표시(month-view__overflow)는 여러 일정 중 하나를 가리키지
 * 않으므로 Link로 감싸지 않는다 - 실제 단일 일정 칩(month-view__chip)만
 * /event/:id로 이동한다.
 */
export function MonthCellChips({ entries, maxChips = MAX_CHIPS_PER_CELL }: MonthCellChipsProps) {
  const visibleEntries = entries.slice(0, maxChips);
  const overflowCount = entries.length - visibleEntries.length;

  return (
    <>
      {visibleEntries.map((entry) => {
        const chipClassNames = ['month-view__chip'];
        if (entry.event.isCritical) {
          chipClassNames.push('month-view__chip--critical');
        }
        const spanClassName = monthChipSpanClassName(entry);
        if (spanClassName !== null) {
          chipClassNames.push(spanClassName);
        }
        return (
          <div
            key={`${entry.event.id}-${entry.event.startAt.toISOString()}`}
            className={chipClassNames.join(' ')}
            title={entry.event.title}
          >
            <Link to={`/event/${entry.event.id}`} className="month-view__chip-link">
              {entry.event.title}
            </Link>
          </div>
        );
      })}
      {overflowCount > 0 ? <div className="month-view__overflow">+{overflowCount}</div> : null}
    </>
  );
}

export interface MonthViewProps {
  /** 테스트/주입용. 기본값은 앱 전역 eventRepository 싱글턴. */
  repository?: EventRepository;
}

export function MonthView({ repository = defaultEventRepository }: MonthViewProps = {}) {
  const [monthAnchor, setMonthAnchor] = useState<Date>(() => new Date());
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const gridDays = useMemo(() => buildMonthGrid(monthAnchor), [monthAnchor]);

  useEffect(() => {
    if (gridDays.length === 0) {
      return;
    }
    const gridStart = gridDays[0].date;
    const gridEnd = addKstDays(gridDays[gridDays.length - 1].date, 1);

    let cancelled = false;
    setLoading(true);
    setErrorMessage(null);

    repository
      .listEvents({ start: gridStart.toISOString(), end: gridEnd.toISOString() })
      .then((result) => {
        if (cancelled) {
          return;
        }
        if (result.error !== null) {
          setErrorMessage(result.error.message);
          setEvents([]);
          return;
        }
        setEvents(result.data ?? []);
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [gridDays, repository]);

  const dayEvents = useMemo(() => buildMonthDayEvents(gridDays, events), [gridDays, events]);
  const today = useMemo(() => new Date(), []);

  return (
    <div className="month-view">
      <div className="month-view__header">
        <button
          type="button"
          className="month-view__nav-btn"
          aria-label="이전 달"
          onClick={() => setMonthAnchor((prev) => addKstMonths(prev, -1))}
        >
          {'<'}
        </button>
        <strong className="month-view__label">{monthLabel(monthAnchor)}</strong>
        <button
          type="button"
          className="month-view__nav-btn"
          aria-label="다음 달"
          onClick={() => setMonthAnchor((prev) => addKstMonths(prev, 1))}
        >
          {'>'}
        </button>
      </div>

      {errorMessage !== null ? <ErrorMessage message={`일정을 불러오지 못했습니다: ${errorMessage}`} /> : null}

      <div className="month-view__weekdays">
        {WEEKDAY_LABELS.map((label) => (
          <div key={label} className="month-view__weekday">
            {label}
          </div>
        ))}
      </div>

      <div className="month-view__grid">
        {gridDays.map((day, index) => {
          const isToday = isSameKstDay(day.date, today);
          const entries = dayEvents[index] ?? [];

          const cellClassNames = ['month-view__cell'];
          if (!day.isCurrentMonth) {
            cellClassNames.push('month-view__cell--outside');
          }
          if (isToday) {
            cellClassNames.push('month-view__cell--today');
          }

          return (
            <div key={day.date.toISOString()} className={cellClassNames.join(' ')}>
              <div className="month-view__daynum">{kstDayNumber(day.date)}</div>
              <MonthCellChips entries={entries} />
            </div>
          );
        })}
      </div>

      {loading ? <Spinner /> : null}
    </div>
  );
}

export default MonthView;
