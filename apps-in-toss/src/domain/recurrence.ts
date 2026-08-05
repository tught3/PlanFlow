/**
 * 반복 일정 회차 전개(occurrence expansion).
 *
 * 원본(Flutter) 대응: lib/data/repositories/event_repository.dart의
 * expandEventOccurrencesForOverlap() (316~421번째 줄 근처)와 주변 헬퍼
 * (eventOverlapEndFor/eventRangesOverlap/_parseRRuleUntilForOverlap/
 * _parseRRuleByDaysForOverlap/_eventIntersectsOverlapRange).
 *
 * 표시 전용 전개이므로 원본의 "이번 회차만/이후 전체/전체 수정" 같은 편집
 * 시맨틱은 포팅하지 않는다 - 여기서는 주어진 기간과 겹치는 회차 목록만
 * 순수 함수로 만든다.
 */

import type { Event } from './event.ts';
import {
  addKstDays,
  addKstMonths,
  addKstYears,
  kstIsoWeekday,
  kstWallToInstant,
} from './datetime.ts';

const DAY_MS = 24 * 60 * 60 * 1000;
const HALF_HOUR_MS = 30 * 60 * 1000;

const WEEKLY_BYDAY_SAFETY_LIMIT = 120;
const GENERAL_SAFETY_LIMIT = 420;

const BYDAY_TOKEN_TO_ISO_WEEKDAY: Record<string, number> = {
  MO: 1,
  TU: 2,
  WE: 3,
  TH: 4,
  FR: 5,
  SA: 6,
  SU: 7,
};

/**
 * 겹침 판정에 쓸 이벤트의 "끝" 시각. endAt이 startAt보다 뒤면 그대로 쓰고,
 * 아니면 종일/다일 일정은 1일, 그 외는 30분을 기본 길이로 본다.
 */
export function eventOverlapEndFor(event: Event): Date {
  const { startAt, endAt } = event;
  if (endAt !== null && endAt.getTime() > startAt.getTime()) {
    return endAt;
  }
  const fallbackMs = event.isAllDay || event.isMultiDay ? DAY_MS : HALF_HOUR_MS;
  return new Date(startAt.getTime() + fallbackMs);
}

export interface EventRangesOverlapParams {
  rangeStart: Date;
  rangeEnd: Date;
  eventStart: Date;
  eventEnd: Date;
}

/** [rangeStart, rangeEnd)와 [eventStart, eventEnd)가 겹치는지. */
export function eventRangesOverlap(params: EventRangesOverlapParams): boolean {
  const { rangeStart, rangeEnd, eventStart, eventEnd } = params;
  if (rangeStart.getTime() === eventStart.getTime()) {
    return true;
  }
  return (
    eventStart.getTime() < rangeEnd.getTime() &&
    rangeStart.getTime() < eventEnd.getTime()
  );
}

function eventIntersectsRange(
  event: Event,
  rangeStart: Date,
  rangeEnd: Date,
): boolean {
  return eventRangesOverlap({
    rangeStart,
    rangeEnd,
    eventStart: event.startAt,
    eventEnd: eventOverlapEndFor(event),
  });
}

function copyEventWithTime(event: Event, startAt: Date, endAt: Date | null): Event {
  return { ...event, startAt, endAt };
}

function parseRRuleUntil(rule: string): Date | null {
  const match = /UNTIL=([0-9TZ]+)/.exec(rule);
  if (match === null) {
    return null;
  }
  const digits = match[1].replace(/[^0-9]/g, '');
  if (digits.length < 8) {
    return null;
  }
  const year = Number(digits.slice(0, 4));
  const month = Number(digits.slice(4, 6));
  const day = Number(digits.slice(6, 8));
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return null;
  }
  return kstWallToInstant(year, month - 1, day, 23, 59, 59);
}

function parseRRuleByDays(rule: string): Set<number> {
  const match = /BYDAY=([A-Z,]+)/.exec(rule);
  const days = new Set<number>();
  if (match === null) {
    return days;
  }
  for (const token of match[1].split(',')) {
    const isoWeekday = BYDAY_TOKEN_TO_ISO_WEEKDAY[token.trim()];
    if (isoWeekday !== undefined) {
      days.add(isoWeekday);
    }
  }
  return days;
}

/**
 * event의 반복 규칙(recurrenceRule)을 [rangeStart, rangeEnd)와 겹치는
 * 실제 회차들로 전개한다. 반복 규칙이 없으면 [event] 그대로 반환한다.
 * (원본과 동일하게) 전개 결과가 비어 있으면 폴백으로 [event]를 반환한다.
 */
export function expandOccurrences(
  event: Event,
  rangeStart: Date,
  rangeEnd: Date,
): Event[] {
  const rule = event.recurrenceRule?.toUpperCase() ?? '';
  if (rule.length === 0) {
    return [event];
  }

  const freqMatch = /FREQ=([A-Z]+)/.exec(rule);
  const freq = freqMatch?.[1];
  if (freq === undefined) {
    return [event];
  }

  const intervalMatch = /INTERVAL=(\d+)/.exec(rule);
  const parsedInterval = intervalMatch ? Number(intervalMatch[1]) : Number.NaN;
  const interval = Number.isFinite(parsedInterval)
    ? Math.min(Math.max(parsedInterval, 1), 365)
    : 1;

  const startAt = event.startAt;
  const until = parseRRuleUntil(rule);
  const hardEnd =
    until !== null && until.getTime() < rangeEnd.getTime() ? until : rangeEnd;

  const durationMs =
    event.endAt !== null
      ? event.endAt.getTime() - startAt.getTime()
      : event.isAllDay || event.isMultiDay
        ? DAY_MS
        : HALF_HOUR_MS;

  const occurrences: Event[] = [];

  if (freq === 'WEEKLY') {
    const byDays = parseRRuleByDays(rule);
    if (byDays.size > 0) {
      const startWeekday = kstIsoWeekday(startAt);
      let weekStart = addKstDays(startAt, -(startWeekday - 1));
      let safety = 0;
      while (weekStart.getTime() < hardEnd.getTime() && safety < WEEKLY_BYDAY_SAFETY_LIMIT) {
        safety += 1;
        for (const isoWeekday of byDays) {
          const current = addKstDays(weekStart, isoWeekday - 1);
          if (
            current.getTime() < startAt.getTime() ||
            !(current.getTime() < hardEnd.getTime())
          ) {
            continue;
          }
          const candidate = copyEventWithTime(
            event,
            current,
            new Date(current.getTime() + durationMs),
          );
          if (eventIntersectsRange(candidate, rangeStart, rangeEnd)) {
            occurrences.push(candidate);
          }
        }
        weekStart = addKstDays(weekStart, 7 * interval);
      }
      return occurrences.length === 0 ? [event] : occurrences;
    }
  }

  let current = startAt;
  let safety = 0;
  while (current.getTime() < hardEnd.getTime() && safety < GENERAL_SAFETY_LIMIT) {
    safety += 1;
    const candidate = copyEventWithTime(
      event,
      current,
      new Date(current.getTime() + durationMs),
    );
    if (eventIntersectsRange(candidate, rangeStart, rangeEnd)) {
      occurrences.push(candidate);
    }

    switch (freq) {
      case 'DAILY':
        current = addKstDays(current, interval);
        break;
      case 'WEEKLY':
        current = addKstDays(current, 7 * interval);
        break;
      case 'MONTHLY':
        current = addKstMonths(current, interval);
        break;
      case 'YEARLY':
        current = addKstYears(current, interval);
        break;
      default:
        current = hardEnd;
        break;
    }
  }

  return occurrences.length === 0 ? [event] : occurrences;
}
