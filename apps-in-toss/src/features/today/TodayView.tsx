/**
 * 오늘 일정 화면.
 *
 * 오늘(KST 00:00~24:00, src/domain/datetime.ts의 kstTodayRange 사용) 일정을
 * eventRepository.listEvents로 조회해 시간순으로 표시한다. 실제 렌더링은
 * 하위 컴포넌트 TodayEventList가 담당한다.
 */
import { useEffect, useState } from 'react';

import type { Event } from '../../domain/event.ts';
import { kstTodayRange } from '../../domain/datetime.ts';
import { eventRepository as defaultEventRepository } from '../../data/eventRepository.ts';
import type { EventRepository } from '../../data/eventRepository.ts';
import { TodayEventList } from './TodayEventList.tsx';

export interface TodayViewProps {
  /** 테스트/주입용. 기본값은 앱 전역 eventRepository 싱글턴. */
  repository?: EventRepository;
  /** 테스트/주입용 "오늘" 기준 시각. 기본값은 현재 시각(new Date()). */
  now?: Date;
}

/**
 * repository에서 now가 속한 KST 하루치 일정을 조회한다.
 * 순수 데이터 로딩 로직만 분리해 React 렌더링(effect) 없이도 단위 테스트할 수 있다.
 */
export async function loadTodayEvents(
  repository: EventRepository,
  now: Date,
): Promise<{ events: Event[]; error: string | null }> {
  const { start, end } = kstTodayRange(now);

  try {
    const result = await repository.listEvents({
      start: start.toISOString(),
      end: end.toISOString(),
    });

    if (result.error !== null) {
      return { events: [], error: result.error.message };
    }

    return { events: result.data ?? [], error: null };
  } catch (err) {
    return { events: [], error: err instanceof Error ? err.message : String(err) };
  }
}

export function TodayView({ repository = defaultEventRepository, now }: TodayViewProps) {
  const [events, setEvents] = useState<Event[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const baseNow = now ?? new Date();

    loadTodayEvents(repository, baseNow).then((result) => {
      if (cancelled) {
        return;
      }
      setEvents(result.events);
      setError(result.error);
    });

    return () => {
      cancelled = true;
    };
  }, [repository, now]);

  if (events === null) {
    return (
      <div className="today-view today-view--loading">
        <p>불러오는 중...</p>
      </div>
    );
  }

  return (
    <div className="today-view">
      <h1 className="today-view__title">오늘 일정</h1>
      {error !== null && <p className="today-view__error">{error}</p>}
      <TodayEventList events={events} />
    </div>
  );
}

export default TodayView;
