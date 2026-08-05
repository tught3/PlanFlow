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
 */
import { useEffect, useMemo, useState } from 'react';

import type { Event } from '../../../domain/event.ts';
import { addKstDays, isSameKstDay, kstWeekRange, toKstWall } from '../../../domain/datetime.ts';
import { eventRepository } from '../../../data/eventRepository.ts';

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

export interface WeekViewProps {
  /** 초기 표시 기준 날짜. 미지정 시 현재 시각(테스트에서 고정 날짜 주입 가능). */
  initialDate?: Date;
}

/** 주간 캘린더: 일~토 7일 그리드 + 해당 주 일정 목록 + 전주/다음주 이동. */
export default function WeekView({ initialDate }: WeekViewProps = {}) {
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

    eventRepository
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
  }, [weekStart, weekEnd]);

  const eventsByDay = useMemo(
    () => weekDays.map((day) => events.filter((event) => isSameKstDay(event.startAt, day))),
    [weekDays, events],
  );

  const handlePrevWeek = () => setWeekStart((current) => shiftWeek(current, -1));
  const handleNextWeek = () => setWeekStart((current) => shiftWeek(current, 1));

  const rangeLabel = `${formatMonthDay(weekStart)} - ${formatMonthDay(weekDays[6])}`;

  return (
    <section aria-label="주간 캘린더" data-testid="week-view">
      <header>
        <button type="button" aria-label="이전 주" onClick={handlePrevWeek}>
          이전 주
        </button>
        <span data-testid="week-range-label">{rangeLabel}</span>
        <button type="button" aria-label="다음 주" onClick={handleNextWeek}>
          다음 주
        </button>
      </header>

      {isLoading ? <p role="status">불러오는 중...</p> : null}
      {errorMessage !== null ? <p role="alert">{errorMessage}</p> : null}

      <div data-testid="week-grid">
        {weekDays.map((day, index) => (
          <div key={day.toISOString()} data-testid={`week-day-${index}`}>
            <span data-testid="week-day-label">{WEEKDAY_LABELS[index]}</span>
            <span data-testid="week-day-date">{formatMonthDay(day)}</span>
            <ul>
              {eventsByDay[index].map((event) => (
                <li key={event.id}>{event.title}</li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  );
}
