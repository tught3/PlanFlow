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
import { eventRepository } from '../../../data/eventRepository.ts';

const DAY_MS = 24 * 60 * 60 * 1000;
const WEEKDAY_LABELS = ['월', '화', '수', '목', '금', '토', '일'];

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
export function buildMonthGrid(monthAnchor: Date, weekStartsOn = 1): MonthGridDay[] {
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

function eventEntryBorderRadius(entry: MonthDayEventEntry): string {
  if (entry.isSpanStart && entry.isSpanEnd) {
    return '4px';
  }
  if (entry.isSpanStart) {
    return '4px 0 0 4px';
  }
  if (entry.isSpanEnd) {
    return '0 4px 4px 0';
  }
  return '0';
}

export function MonthView() {
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

    eventRepository
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
  }, [gridDays]);

  const dayEvents = useMemo(() => buildMonthDayEvents(gridDays, events), [gridDays, events]);
  const today = useMemo(() => new Date(), []);

  return (
    <div>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 4px',
        }}
      >
        <button
          type="button"
          aria-label="이전 달"
          onClick={() => setMonthAnchor((prev) => addKstMonths(prev, -1))}
        >
          {'<'}
        </button>
        <strong>{monthLabel(monthAnchor)}</strong>
        <button
          type="button"
          aria-label="다음 달"
          onClick={() => setMonthAnchor((prev) => addKstMonths(prev, 1))}
        >
          {'>'}
        </button>
      </div>

      {errorMessage !== null ? (
        <p role="alert" style={{ color: '#c92a2a', fontSize: 13 }}>
          일정을 불러오지 못했습니다: {errorMessage}
        </p>
      ) : null}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)' }}>
        {WEEKDAY_LABELS.map((label) => (
          <div key={label} style={{ textAlign: 'center', fontSize: 12, color: '#888', padding: 4 }}>
            {label}
          </div>
        ))}
        {gridDays.map((day, index) => {
          const isToday = isSameKstDay(day.date, today);
          const entries = dayEvents[index] ?? [];
          return (
            <div
              key={day.date.toISOString()}
              style={{
                minHeight: 72,
                border: '1px solid #eee',
                padding: 4,
                opacity: day.isCurrentMonth ? 1 : 0.4,
                background: isToday ? '#eef6ff' : undefined,
              }}
            >
              <div style={{ fontSize: 12, fontWeight: isToday ? 700 : 400 }}>
                {kstDayNumber(day.date)}
              </div>
              {entries.map((entry, entryIndex) => (
                <div
                  key={`${entry.event.id}-${index}-${entryIndex}`}
                  title={entry.event.title}
                  style={{
                    fontSize: 11,
                    marginTop: 2,
                    padding: '1px 4px',
                    borderRadius: eventEntryBorderRadius(entry),
                    background: entry.event.isCritical ? '#ffe1e1' : '#e6f0ff',
                    borderLeft: entry.event.isCritical ? '3px solid #e03131' : '3px solid #4c6ef5',
                    color: entry.event.isCritical ? '#c92a2a' : '#1c3faa',
                    whiteSpace: 'nowrap',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                  }}
                >
                  {entry.event.title}
                </div>
              ))}
            </div>
          );
        })}
      </div>

      {loading ? <p style={{ fontSize: 12, color: '#888' }}>불러오는 중...</p> : null}
    </div>
  );
}

export default MonthView;
