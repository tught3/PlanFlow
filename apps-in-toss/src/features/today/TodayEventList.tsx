/**
 * 오늘 일정 목록을 시간순으로 렌더링하는 순수(presentational) 컴포넌트.
 *
 * 데이터 조회(useEffect/eventRepository)는 TodayView.tsx가 담당하고, 이 컴포넌트는
 * 이미 조회된 Event[]를 받아 렌더링만 한다 - hook/effect가 없어 렌더링 결과를
 * (jsdom 없이) react-dom/server의 renderToStaticMarkup만으로도 그대로 테스트할 수 있다.
 */
import { Link } from 'react-router-dom';

import type { Event } from '../../domain/event.ts';
import { toKstWall } from '../../domain/datetime.ts';
import { EmptyState } from '../../components/index.ts';

export interface TodayEventListProps {
  events: Event[];
}

/** KST 벽시계 기준 HH:mm 문자열. (예: 09:05) */
function formatKstTime(date: Date): string {
  const wall = toKstWall(date);
  const hh = String(wall.getUTCHours()).padStart(2, '0');
  const mm = String(wall.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

function formatTimeLabel(event: Event): string {
  if (event.isAllDay) {
    return '하루 종일';
  }
  const start = formatKstTime(event.startAt);
  if (event.endAt === null) {
    return start;
  }
  return `${start} - ${formatKstTime(event.endAt)}`;
}

export function TodayEventList({ events }: TodayEventListProps) {
  if (events.length === 0) {
    return (
      <div className="today-event-list__empty" data-testid="today-empty">
        <EmptyState message="오늘 일정이 없습니다." />
      </div>
    );
  }

  return (
    <ul className="today-event-list" data-testid="today-event-list">
      {events.map((event) => {
        const className = event.isCritical
          ? 'today-event-list__item today-event-list__item--critical'
          : 'today-event-list__item';
        return (
          <li
            key={`${event.id}-${event.startAt.toISOString()}`}
            className={className}
            data-critical={event.isCritical}
          >
            <Link to={`/event/${event.id}`} className="today-event-list__link">
              <span className="today-event-list__time">{formatTimeLabel(event)}</span>
              <span className="today-event-list__title">{event.title}</span>
            </Link>
          </li>
        );
      })}
    </ul>
  );
}

export default TodayEventList;
