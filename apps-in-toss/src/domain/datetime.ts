/**
 * KST(Asia/Seoul, UTC+9, DST 없음) 기준 날짜 계산 유틸.
 *
 * timestamptz(UTC) <-> KST 변환은 이 파일 하나로 단일화한다. 다른 파일에서
 * `date.getTime() + 9 * 60 * 60 * 1000` 같은 변환을 직접 하지 않는다.
 *
 * 구현 방식은 원본(Flutter) lib/core/local_time.dart의 planflowLocal()과
 * 동일한 아이디어를 쓴다: KST 벽시계 값을 "UTC getter로 읽었을 때 KST
 * 값이 나오는 Date 객체"(wall-clock Date)로 표현한다. 이렇게 하면 실행
 * 환경의 시스템 타임존과 무관하게 항상 같은 결과를 낸다.
 */

export const KST_OFFSET_MS = 9 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * 실제 UTC 기준 Date를 "KST 벽시계 값을 UTC 필드로 담은" Date로 변환한다.
 * 반환값은 실제 시각이 아니므로 getUTCFullYear/getUTCMonth/... 로만 읽는다.
 */
export function toKstWall(date: Date): Date {
  return new Date(date.getTime() + KST_OFFSET_MS);
}

/** toKstWall()의 역변환. KST 벽시계 Date를 실제 UTC Date로 되돌린다. */
export function fromKstWall(wall: Date): Date {
  return new Date(wall.getTime() - KST_OFFSET_MS);
}

/** ISO 요일(1=월요일 ... 7=일요일)로 반환한다. KST 기준. */
export function kstIsoWeekday(date: Date): number {
  const wall = toKstWall(date);
  const jsDay = wall.getUTCDay(); // 0=Sun...6=Sat
  return jsDay === 0 ? 7 : jsDay;
}

/** 해당 시각이 속한 KST 날짜의 자정(00:00 KST)을 실제 UTC Date로 반환한다. */
export function kstDayStart(date: Date): Date {
  const wall = toKstWall(date);
  const wallDayStart = Date.UTC(
    wall.getUTCFullYear(),
    wall.getUTCMonth(),
    wall.getUTCDate(),
  );
  return fromKstWall(new Date(wallDayStart));
}

/** [00:00 KST, 다음날 00:00 KST) 범위. date가 속한 날짜 기준. */
export function kstDayRange(date: Date): { start: Date; end: Date } {
  const start = kstDayStart(date);
  const end = new Date(start.getTime() + DAY_MS);
  return { start, end };
}

/** 오늘(now 기준) 하루의 KST 범위. 기본값은 현재 시각. */
export function kstTodayRange(now: Date = new Date()): { start: Date; end: Date } {
  return kstDayRange(now);
}

/** 두 시각이 같은 KST 날짜에 속하는지. */
export function isSameKstDay(a: Date, b: Date): boolean {
  const dayA = kstDayStart(a).getTime();
  const dayB = kstDayStart(b).getTime();
  return dayA === dayB;
}

export interface WeekRangeOptions {
  /** 주 시작 요일. ISO weekday(1=월 ... 7=일) 기준. 기본 1(월요일). */
  weekStartsOn?: number;
}

/** date가 속한 주의 시작일(자정, KST) ~ 다음 주 시작일(자정, KST) 범위. */
export function kstWeekRange(
  date: Date,
  options: WeekRangeOptions = {},
): { start: Date; end: Date } {
  const weekStartsOn = options.weekStartsOn ?? 1;
  const dayStart = kstDayStart(date);
  const weekday = kstIsoWeekday(dayStart);
  const diffDays = (weekday - weekStartsOn + 7) % 7;
  const start = new Date(dayStart.getTime() - diffDays * DAY_MS);
  const end = new Date(start.getTime() + 7 * DAY_MS);
  return { start, end };
}

/** date가 속한 KST 월의 시작일(자정) ~ 다음 달 시작일(자정) 범위. */
export function kstMonthRange(date: Date): { start: Date; end: Date } {
  const wall = toKstWall(date);
  const year = wall.getUTCFullYear();
  const month = wall.getUTCMonth();
  const start = fromKstWall(new Date(Date.UTC(year, month, 1)));
  const end = fromKstWall(new Date(Date.UTC(year, month + 1, 1)));
  return { start, end };
}

/**
 * KST 벽시계 기준으로 월을 더한다(일/시/분/초는 유지, overflow는 JS Date의
 * 자동 정규화를 따른다 - 예: 1월 31일 + 1개월 = 3월 3일(윤년 아닐 때)).
 * 원본 Dart의 `DateTime(year, month + interval, day, ...)` 동작과 동일하다.
 */
export function addKstMonths(date: Date, months: number): Date {
  const wall = toKstWall(date);
  const shifted = new Date(
    Date.UTC(
      wall.getUTCFullYear(),
      wall.getUTCMonth() + months,
      wall.getUTCDate(),
      wall.getUTCHours(),
      wall.getUTCMinutes(),
      wall.getUTCSeconds(),
      wall.getUTCMilliseconds(),
    ),
  );
  return fromKstWall(shifted);
}

/** KST 벽시계 기준으로 연도를 더한다. */
export function addKstYears(date: Date, years: number): Date {
  return addKstMonths(date, years * 12);
}

/** KST 벽시계 기준으로 일을 더한다. */
export function addKstDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * DAY_MS);
}

/**
 * 명시적인 KST 벽시계 구성요소(year/month/day/...)로부터 실제 UTC 순간(Date)을
 * 만든다. month는 JS Date 관례대로 0-based(0=1월)다.
 */
export function kstWallToInstant(
  year: number,
  month: number,
  day: number,
  hour = 0,
  minute = 0,
  second = 0,
  millisecond = 0,
): Date {
  return fromKstWall(
    new Date(Date.UTC(year, month, day, hour, minute, second, millisecond)),
  );
}
