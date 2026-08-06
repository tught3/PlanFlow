/**
 * 주간 캘린더 화면.
 *
 * 주 시작 요일은 원본(Flutter) lib/screens/calendar/calendar_widgets.dart의
 * `weekdayLabels = ['일', '월', '화', '수', '목', '금', '토']`와 동일하게
 * 일요일 시작으로 맞춘다(한국 앱 관례).
 *
 * 날짜 계산은 src/domain/datetime.ts의 KST 유틸만 사용하고, 일정 조회는
 * src/data/eventRepository.ts의 listEvents()만 사용한다(이 파일 안에서
 * 직접 timestamptz 변환을 하지 않는다).
 *
 * 반복 일정 전개는 src/domain/recurrence.ts의 expandOccurrences()를 그대로
 * 쓴다(MonthView.tsx와 동일한 방식) - 원본 회차(recurrence_rule이 있는 row)를
 * 그대로 표시하지 않고, 그 주 범위와 겹치는 실제 회차로 전개한 뒤 각 회차의
 * startAt이 속한 요일 칸에 배치한다.
 */
import { useEffect, useMemo, useState } from 'react';

import type { Event } from '../../../domain/event.ts';
import {
  addKstDays,
  expandOccurrences,
  isSameKstDay,
  kstWeekRange,
  toKstWall,
} from '../../../domain/index.ts';
import { eventRepository as defaultEventRepository } from '../../../data/eventRepository.ts';
import type { EventRepository } from '../../../data/eventRepository.ts';
import { Spinner, ErrorMessage } from '../../../components/index.ts';

/** ISO weekday 기준 주 시작 요일. 7 = 일요일. */
const WEEK_STARTS_ON = 7;

const WEEKDAY_LABELS = ['일', '월', '화', '수', '목', '금', '토'] as const;

/** date가 속한 주의 시작일(일요일 00:00 KST)을 반환한다. */
export function getWeekStart(date: Date): Date {
  return kstWeekRange(date, { weekStartsOn: WEEK_STARTS_ON }).start;
}

/** weekStart(일요일)를 기준으로 그 주 7일(일~토)의 Date 배열을 반환한다. */
export function getWeekDays(weekStart: Date): Date[] {
  return Array.from({ length: 7 }, (_, index) => addKstDays(weekStart, index));
}

/** weekStart를 delta주만큼 이동한 새 주 시작일(일요일)을 반환한다. */
export function shiftWeek(weekStart: Date, delta: number): Date {
  return addKstDays(weekStart, delta * 7);
}

/** 'M/D' 형태로 KST 기준 월/일을 표시한다. */
export function formatMonthDay(date: Date): string {
  const wall = toKstWall(date);
  return `${wall.getUTCMonth() + 1}/${wall.getUTCDate()}`;
}

/** KST 벽시계 기준 HH:mm 문자열. (TodayEventList.tsx의 formatKstTime과 동일 규칙) */
function formatKstTime(date: Date): string {
  const wall = toKstWall(date);
  const hh = String(wall.getUTCHours()).padStart(2, '0');
  const mm = String(wall.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

/** 일정 항목의 시간 라벨. 종일 일정은 '하루 종일', 아니면 시작 시각(HH:mm). */
function formatEventTimeLabel(event: Event): string {
  if (event.isAllDay) {
    return '하루 종일';
  }
  return formatKstTime(event.startAt);
}

/**
 * weekDays(7일, 일~토) 각 날짜에 걸치는 일정 목록을 계산한다(반환 배열은
 * weekDays와 같은 길이/순서). 반복 일정은 weekDays[0]~weekDays[6]+1일 범위로
 * expandOccurrences 전개하고, 각 회차는 startAt이 속한 요일 칸에 하나씩
 * 배치한다(같은 요일 안에서는 시작 시각순 정렬).
 */
export function buildWeekDayEvents(weekDays: Date[], events: Event[]): Event[][] {
  if (weekDays.length === 0) {
    return [];
  }

  const rangeStart = weekDays[0];
  const rangeEnd = addKstDays(weekDays[weekDays.length - 1], 1);

  const perDay: Event[][] = weekDays.map(() => []);

  for (const event of events) {
    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);
    for (const occurrence of occurrences) {
      const dayIndex = weekDays.findIndex((day) => isSameKstDay(occurrence.startAt, day));
      if (dayIndex === -1) {
        continue;
      }
      perDay[dayIndex].push(occurrence);
    }
  }

  for (const dayEvents of perDay) {
    dayEvents.sort((a, b) => a.startAt.getTime() - b.startAt.getTime());
  }

  return perDay;
}

export interface WeekViewProps {
  /** 초기 표시 기준 날짜. 미지정 시 현재 시각(테스트에서 고정 날짜 주입 가능). */
  initialDate?: Date;
  /** 테스트/주입용. 기본값은 앱 전역 eventRepository 싱글턴. */
  repository?: EventRepository;
}

/** 주간 캘린더: 일~토 7일 그리드 + 해당 주 일정 목록 + 전주/다음주 이동. */
export default function WeekView({ initialDate, repository = defaultEventRepository }: WeekViewProps = {}) {
  const [weekStart, setWeekStart] = useState<Date>(() => getWeekStart(initialDate ?? new Date()));
  const [events, setEvents] = useState<Event[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const weekDays = useMemo(() => getWeekDays(weekStart), [weekStart]);
  const weekEnd = useMemo(() => addKstDays(weekStart, 7), [weekStart]);

  useEffect(() => {
    let cancelled = false;
    setIsLoading(true);
    setErrorMessage(null);

    repository
      .listEvents({ start: weekStart.toISOString(), end: weekEnd.toISOString() })
      .then(({ data, error }) => {
        if (cancelled) {
          return;
        }
        if (error !== null) {
          setErrorMessage(error.message);
          setEvents([]);
        } else {
          setEvents(data ?? []);
        }
        setIsLoading(false);
      })
      .catch((err: unknown) => {
        if (cancelled) {
          return;
        }
        setErrorMessage(err instanceof Error ? err.message : String(err));
        setEvents([]);
        setIsLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [weekStart, weekEnd, repository]);

  const eventsByDay = useMemo(() => buildWeekDayEvents(weekDays, events), [weekDays, events]);

  const handlePrevWeek = () => setWeekStart((current) => shiftWeek(current, -1));
  const handleNextWeek = () => setWeekStart((current) => shiftWeek(current, 1));

  const rangeLabel = `${formatMonthDay(weekStart)} - ${formatMonthDay(weekDays[6])}`;

  return (
    <section aria-label="주간 캘린더" data-testid="week-view" className="week-view">
      <header className="week-view__header">
        <button type="button" className="week-view__nav-btn" aria-label="이전 주" onClick={handlePrevWeek}>
          이전 주
        </button>
        <span data-testid="week-range-label" className="week-view__range">
          {rangeLabel}
        </span>
        <button type="button" className="week-view__nav-btn" aria-label="다음 주" onClick={handleNextWeek}>
          다음 주
        </button>
      </header>

      {isLoading ? <Spinner /> : null}
      {errorMessage !== null ? <ErrorMessage message={errorMessage} /> : null}

      <div data-testid="week-grid" className="week-view__grid">
        {weekDays.map((day, index) => {
          const isToday = isSameKstDay(day, new Date());
          const dayClassNames = ['week-view__day'];
          if (isToday) {
            dayClassNames.push('week-view__day--today');
          }
          return (
            <div key={day.toISOString()} data-testid={`week-day-${index}`} className={dayClassNames.join(' ')}>
              <span data-testid="week-day-label" className="week-view__label">
                {WEEKDAY_LABELS[index]}
              </span>
              <span data-testid="week-day-date" className="week-view__date">
                {formatMonthDay(day)}
              </span>
              <ul className="week-view__events">
                {eventsByDay[index].map((event) => {
                  const eventClassNames = ['week-view__event'];
                  if (event.isCritical) {
                    eventClassNames.push('week-view__event--critical');
                  }
                  return (
                    <li key={event.id} className={eventClassNames.join(' ')}>
                      <span className="week-view__event-time">{formatEventTimeLabel(event)}</span>
                      <span className="week-view__event-title">{event.title}</span>
                    </li>
                  );
                })}
              </ul>
            </div>
          );
        })}
      </div>
    </section>
  );
}
