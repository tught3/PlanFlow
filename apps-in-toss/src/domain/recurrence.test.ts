import { describe, expect, it } from 'vitest';

import type { Event } from './event.ts';
import { addKstDays, kstWallToInstant } from './datetime.ts';
import {
  eventOverlapEndFor,
  eventRangesOverlap,
  expandOccurrences,
} from './recurrence.ts';

function baseEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-r',
    userId: 'user-1',
    title: '반복 회의',
    // 2026-03-02(월) 10:00 KST == 2026-03-02T01:00:00.000Z
    startAt: kstWallToInstant(2026, 2, 2, 10, 0, 0),
    endAt: kstWallToInstant(2026, 2, 2, 11, 0, 0),
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

describe('expandOccurrences - 종료일 지정(UNTIL)', () => {
  it('UNTIL(KST 23:59:59) 이후 회차는 전개되지 않는다', () => {
    const event = baseEvent({
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20260323T235959',
    });
    const rangeStart = event.startAt;
    const rangeEnd = addKstDays(event.startAt, 60);

    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);

    expect(occurrences).toHaveLength(4);
    const lastStart = occurrences[occurrences.length - 1]!.startAt;
    // 2026-03-23(월) 10:00 KST
    expect(lastStart.toISOString()).toBe(
      kstWallToInstant(2026, 2, 23, 10, 0, 0).toISOString(),
    );
    // 3/30(그 다음 월요일)은 UNTIL을 넘겨 전개되지 않아야 한다.
    expect(
      occurrences.some(
        (occ) =>
          occ.startAt.toISOString() ===
          kstWallToInstant(2026, 2, 30, 10, 0, 0).toISOString(),
      ),
    ).toBe(false);
  });
});

describe('expandOccurrences - 횟수 지정(recurrenceCount 메타데이터)', () => {
  it('recurrenceCount는 각 회차에 그대로 유지된다(원본처럼 전개 자체는 UNTIL/range로만 제한)', () => {
    // 원본 expandEventOccurrencesForOverlap()은 RRULE의 COUNT를 파싱하지
    // 않는다(recurrenceCount 컬럼은 별도 메타데이터). 여기서는 그 사실을
    // 명시적으로 고정한다: count가 있어도 전개는 range로만 제한된다.
    const event = baseEvent({
      recurrenceRule: 'FREQ=DAILY',
      recurrenceCount: 3,
    });
    const rangeStart = event.startAt;
    const rangeEnd = addKstDays(event.startAt, 3); // 3일치 범위

    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);

    expect(occurrences.length).toBeGreaterThan(0);
    for (const occ of occurrences) {
      expect(occ.recurrenceCount).toBe(3);
    }
  });
});

describe('expandOccurrences - 월 경계(MONTHLY, 일자 overflow)', () => {
  it('1/31 매월 반복은 2월을 건너뛰고 3/3로 정규화된다(2026년 평년)', () => {
    const event = baseEvent({
      startAt: kstWallToInstant(2026, 0, 31, 10, 0, 0), // 2026-01-31 10:00 KST
      endAt: kstWallToInstant(2026, 0, 31, 11, 0, 0),
      recurrenceRule: 'FREQ=MONTHLY;INTERVAL=1',
    });
    const rangeStart = event.startAt;
    const rangeEnd = kstWallToInstant(2026, 3, 20, 0, 0, 0); // 2026-04-20까지

    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);
    const isoStarts = occurrences.map((occ) => occ.startAt.toISOString());

    expect(isoStarts).toEqual([
      kstWallToInstant(2026, 0, 31, 10, 0, 0).toISOString(), // 1/31
      kstWallToInstant(2026, 2, 3, 10, 0, 0).toISOString(), // 3/3 (2월 없음)
      kstWallToInstant(2026, 3, 3, 10, 0, 0).toISOString(), // 4/3
    ]);
  });
});

describe('expandOccurrences - 다일(multi-day) 걸침', () => {
  it('endAt이 있는 다일 일정은 그 endAt까지가 겹침 판정 범위다', () => {
    const event = baseEvent({
      isMultiDay: true,
      startAt: kstWallToInstant(2026, 2, 2, 0, 0, 0), // 3/2 00:00 KST
      endAt: kstWallToInstant(2026, 2, 5, 0, 0, 0), // 3/5 00:00 KST (3박4일)
      recurrenceRule: null,
    });

    expect(eventOverlapEndFor(event).toISOString()).toBe(
      kstWallToInstant(2026, 2, 5, 0, 0, 0).toISOString(),
    );

    // 여행 중간(3/3)만 걸치는 범위와도 겹쳐야 한다.
    const midRangeStart = kstWallToInstant(2026, 2, 3, 0, 0, 0);
    const midRangeEnd = kstWallToInstant(2026, 2, 4, 0, 0, 0);
    expect(
      eventRangesOverlap({
        rangeStart: midRangeStart,
        rangeEnd: midRangeEnd,
        eventStart: event.startAt,
        eventEnd: eventOverlapEndFor(event),
      }),
    ).toBe(true);
  });

  it('endAt이 없는 다일 일정은 1일 폴백으로 겹침을 판정한다', () => {
    const event = baseEvent({
      isMultiDay: true,
      endAt: null,
      startAt: kstWallToInstant(2026, 2, 2, 0, 0, 0),
      recurrenceRule: null,
    });
    expect(eventOverlapEndFor(event).toISOString()).toBe(
      kstWallToInstant(2026, 2, 3, 0, 0, 0).toISOString(),
    );
  });
});

describe('expandOccurrences - 올데이(all-day)', () => {
  it('종일 일정은 endAt이 없으면 1일 길이로 취급되고, 매주 반복 시 각 회차도 동일하다', () => {
    const event = baseEvent({
      isAllDay: true,
      endAt: null,
      startAt: kstWallToInstant(2026, 2, 2, 0, 0, 0), // 3/2(월) 00:00 KST
      recurrenceRule: 'FREQ=WEEKLY;INTERVAL=1',
    });
    const rangeStart = event.startAt;
    const rangeEnd = addKstDays(event.startAt, 10); // 3/2, 3/9만 포함(3/16은 제외)

    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);
    expect(occurrences).toHaveLength(2);
    for (const occ of occurrences) {
      expect(occ.endAt).not.toBeNull();
      expect(occ.endAt!.getTime() - occ.startAt.getTime()).toBe(
        24 * 60 * 60 * 1000,
      );
    }
  });
});

describe('expandOccurrences - KST 자정 경계', () => {
  it('KST 자정 부근 시각도 요일별 반복이 올바른 KST 날짜로 전개된다', () => {
    // 2026-03-09(월) 00:30 KST == 2026-03-08T15:30:00.000Z (UTC로는 전날)
    const event = baseEvent({
      startAt: kstWallToInstant(2026, 2, 9, 0, 30, 0),
      endAt: kstWallToInstant(2026, 2, 9, 1, 0, 0),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,TU',
    });
    const rangeStart = event.startAt;
    const rangeEnd = addKstDays(event.startAt, 3);

    const occurrences = expandOccurrences(event, rangeStart, rangeEnd);
    const isoStarts = occurrences.map((occ) => occ.startAt.toISOString()).sort();

    expect(isoStarts).toEqual([
      // 월요일 00:30 KST(UTC 전날 15:30)
      kstWallToInstant(2026, 2, 9, 0, 30, 0).toISOString(),
      // 화요일 00:30 KST - UTC 날짜도 하루 넘어가야 한다.
      kstWallToInstant(2026, 2, 10, 0, 30, 0).toISOString(),
    ]);
    expect(isoStarts[0]).toBe('2026-03-08T15:30:00.000Z');
    expect(isoStarts[1]).toBe('2026-03-09T15:30:00.000Z');
  });
});

describe('expandOccurrences - 반복 규칙 없음', () => {
  it('recurrenceRule이 없으면 원본 이벤트 하나만 반환한다', () => {
    const event = baseEvent({ recurrenceRule: null });
    const occurrences = expandOccurrences(
      event,
      event.startAt,
      addKstDays(event.startAt, 1),
    );
    expect(occurrences).toEqual([event]);
  });
});
