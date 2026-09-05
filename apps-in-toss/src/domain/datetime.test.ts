import { describe, expect, it } from 'vitest';

import {
  addKstDays,
  addKstMonths,
  isSameKstDay,
  kstDayRange,
  kstIsoWeekday,
  kstMonthRange,
  kstTodayRange,
  kstWallToInstant,
  kstWeekRange,
} from './datetime.ts';

describe('KST 자정 경계', () => {
  it('KST 23:59:59.999는 이전 날짜, 00:00:00.000는 다음 날짜로 갈린다', () => {
    // 2026-03-09 23:59:59.999 KST == 2026-03-09T14:59:59.999Z
    const justBeforeMidnight = new Date('2026-03-09T14:59:59.999Z');
    // 2026-03-10 00:00:00.000 KST == 2026-03-09T15:00:00.000Z
    const justAfterMidnight = new Date('2026-03-09T15:00:00.000Z');

    expect(isSameKstDay(justBeforeMidnight, justAfterMidnight)).toBe(false);

    const { start, end } = kstDayRange(justAfterMidnight);
    expect(start.toISOString()).toBe('2026-03-09T15:00:00.000Z');
    expect(end.toISOString()).toBe('2026-03-10T15:00:00.000Z');

    // 자정 직전 시각은 그 범위에 포함되지 않아야 한다.
    expect(justBeforeMidnight.getTime() < start.getTime()).toBe(true);
    // 자정 시각은 그 범위 시작과 같다(포함).
    expect(justAfterMidnight.getTime()).toBe(start.getTime());
  });

  it('kstTodayRange는 인자로 준 시각이 속한 KST 하루를 반환한다', () => {
    const noonUtc = new Date('2026-03-09T12:00:00.000Z'); // KST 21:00
    const { start, end } = kstTodayRange(noonUtc);
    expect(start.toISOString()).toBe('2026-03-08T15:00:00.000Z');
    expect(end.toISOString()).toBe('2026-03-09T15:00:00.000Z');
  });
});

describe('월 경계', () => {
  it('월의 첫 주 - kstMonthRange 시작은 그 달 1일 00:00 KST다', () => {
    const midMarch = new Date('2026-03-15T05:00:00.000Z');
    const { start, end } = kstMonthRange(midMarch);
    // 2026-03-01 00:00 KST == 2026-02-28T15:00:00.000Z
    expect(start.toISOString()).toBe('2026-02-28T15:00:00.000Z');
    // 다음달(2026-04-01 00:00 KST) == 2026-03-31T15:00:00.000Z
    expect(end.toISOString()).toBe('2026-03-31T15:00:00.000Z');
  });

  it('월의 마지막 주 - 2월 마지막날에서 3월로 넘어가는 경계', () => {
    // 2026년은 평년, 2월 28일이 마지막 날. 23:00 KST 기준.
    const lastDayOfFeb = new Date('2026-02-28T14:00:00.000Z'); // KST 23:00 2/28
    const { end } = kstMonthRange(lastDayOfFeb);
    expect(end.toISOString()).toBe('2026-02-28T15:00:00.000Z');

    // 자정을 넘기면 3월로 판정돼야 한다.
    const firstMinuteOfMarch = new Date('2026-02-28T15:00:00.000Z'); // KST 2026-03-01 00:00
    const marchRange = kstMonthRange(firstMinuteOfMarch);
    expect(marchRange.start.toISOString()).toBe('2026-02-28T15:00:00.000Z');
    expect(marchRange.end.toISOString()).toBe('2026-03-31T15:00:00.000Z');
  });

  it('addKstMonths는 일자 overflow를 자동 정규화한다(1/31 + 1개월)', () => {
    const jan31 = new Date('2026-01-30T15:00:00.000Z'); // KST 2026-01-31 00:00
    const result = addKstMonths(jan31, 1);
    // 2026년은 평년이라 2월엔 31일이 없다 -> 3월로 overflow.
    expect(result.getTime()).toBeGreaterThan(jan31.getTime());
    // KST 벽시계 기준 다시 확인: 2026-02-31 => 2026-03-03 (28일 + 3일)
    expect(result.toISOString()).toBe('2026-03-02T15:00:00.000Z');
  });
});

describe('주 경계/요일', () => {
  it('kstIsoWeekday는 월=1 ... 일=7을 KST 기준으로 반환한다', () => {
    // 2026-03-09는 월요일(KST)
    const monday = new Date('2026-03-08T15:00:00.000Z'); // KST 2026-03-09 00:00
    expect(kstIsoWeekday(monday)).toBe(1);

    // 2026-03-15는 일요일(KST)
    const sunday = new Date('2026-03-14T15:00:00.000Z'); // KST 2026-03-15 00:00
    expect(kstIsoWeekday(sunday)).toBe(7);
  });

  it('kstWeekRange는 기본적으로 월요일 시작이다', () => {
    const wednesday = new Date('2026-03-11T03:00:00.000Z'); // KST 2026-03-11(수) 12:00
    const { start, end } = kstWeekRange(wednesday);
    // 그 주 월요일(2026-03-09) 00:00 KST
    expect(start.toISOString()).toBe('2026-03-08T15:00:00.000Z');
    expect(end.toISOString()).toBe(addKstDays(start, 7).toISOString());
  });
});

describe('kstWallToInstant', () => {
  it('명시적 KST 벽시계 값으로부터 정확한 UTC 순간을 만든다', () => {
    const instant = kstWallToInstant(2026, 2, 10, 9, 0, 0); // 2026-03-10 09:00 KST (month=2 -> 3월)
    expect(instant.toISOString()).toBe('2026-03-10T00:00:00.000Z');
  });
});
