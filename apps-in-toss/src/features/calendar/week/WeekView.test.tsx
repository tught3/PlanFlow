/**
 * WeekView 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library가 아직 설치되어 있지 않으므로(다른
 * 병렬 작업과의 package.json 충돌을 피하기 위해 이 작업에서는 추가하지 않음),
 * 렌더링 스모크 테스트는 `react-dom/server`의 renderToStaticMarkup으로
 * 수행한다. 이 방식은 useEffect를 실행하지 않으므로(SSR과 동일하게 동작)
 * eventRepository의 실제 네트워크 호출 없이 초기 렌더 결과만 검증한다.
 * 주 이동 로직은 컴포넌트에서 분리해 내보낸 순수 함수(getWeekStart/
 * getWeekDays/shiftWeek)로 직접 검증한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';

import { kstIsoWeekday } from '../../../domain/datetime.ts';
import WeekView, { formatMonthDay, getWeekDays, getWeekStart, shiftWeek } from './WeekView.tsx';

describe('getWeekStart', () => {
  it('어떤 요일을 넣어도 그 주의 일요일 00:00 KST를 반환한다', () => {
    // 2026-03-11(수) 12:00 KST == 2026-03-11T03:00:00.000Z
    const wednesday = new Date('2026-03-11T03:00:00.000Z');
    const weekStart = getWeekStart(wednesday);

    expect(kstIsoWeekday(weekStart)).toBe(7); // 7 = 일요일(ISO weekday)
    // 2026-03-08(일) 00:00 KST == 2026-03-07T15:00:00.000Z
    expect(weekStart.toISOString()).toBe('2026-03-07T15:00:00.000Z');
  });

  it('입력이 이미 일요일이면 그대로(그 날 자정)를 반환한다', () => {
    // 2026-03-08(일) 09:00 KST == 2026-03-08T00:00:00.000Z
    const sunday = new Date('2026-03-08T00:00:00.000Z');
    const weekStart = getWeekStart(sunday);

    expect(weekStart.toISOString()).toBe('2026-03-07T15:00:00.000Z');
  });
});

describe('getWeekDays', () => {
  it('일요일부터 토요일까지 연속 7일을 반환한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const days = getWeekDays(weekStart);

    expect(days).toHaveLength(7);
    expect(days.map((day) => kstIsoWeekday(day))).toEqual([7, 1, 2, 3, 4, 5, 6]);

    for (let i = 1; i < days.length; i += 1) {
      const diffMs = days[i].getTime() - days[i - 1].getTime();
      expect(diffMs).toBe(24 * 60 * 60 * 1000);
    }
  });
});

describe('shiftWeek (주 이동)', () => {
  it('delta=1이면 정확히 7일 뒤 같은 요일(다음 주 일요일)로 이동한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const nextWeekStart = shiftWeek(weekStart, 1);

    expect(nextWeekStart.getTime() - weekStart.getTime()).toBe(7 * 24 * 60 * 60 * 1000);
    expect(kstIsoWeekday(nextWeekStart)).toBe(7);
  });

  it('delta=-1이면 정확히 7일 전(이전 주 일요일)로 이동한다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const prevWeekStart = shiftWeek(weekStart, -1);

    expect(weekStart.getTime() - prevWeekStart.getTime()).toBe(7 * 24 * 60 * 60 * 1000);
    expect(kstIsoWeekday(prevWeekStart)).toBe(7);
  });

  it('연속 이동(다음주 -> 이전주 -> 이전주)은 최초 위치에서 1주 전과 같다', () => {
    const weekStart = getWeekStart(new Date('2026-03-11T03:00:00.000Z'));
    const roundTrip = shiftWeek(shiftWeek(shiftWeek(weekStart, 1), -1), -1);

    expect(roundTrip.getTime()).toBe(shiftWeek(weekStart, -1).getTime());
  });
});

describe('formatMonthDay', () => {
  it('KST 기준 M/D 형태로 포맷한다', () => {
    // 2026-03-08 00:00 KST
    expect(formatMonthDay(new Date('2026-03-07T15:00:00.000Z'))).toBe('3/8');
  });
});

describe('WeekView 기본 렌더링', () => {
  it('주간 캘린더 섹션과 이동 버튼, 요일 7칸을 렌더링한다', () => {
    const html = renderToStaticMarkup(
      <WeekView initialDate={new Date('2026-03-11T03:00:00.000Z')} />,
    );

    expect(html).toContain('주간 캘린더');
    expect(html).toContain('이전 주');
    expect(html).toContain('다음 주');
    expect(html).toContain('3/8 - 3/14');

    for (let i = 0; i < 7; i += 1) {
      expect(html).toContain(`data-testid="week-day-${i}"`);
    }

    const weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];
    for (const label of weekdayLabels) {
      expect(html).toContain(`>${label}<`);
    }
  });

  it('initialDate 없이도 예외 없이 렌더링된다(기본값은 현재 시각)', () => {
    const html = renderToStaticMarkup(<WeekView />);
    expect(html).toContain('주간 캘린더');
  });
});
