import { useEffect, useState } from 'react';
import { Link, Navigate, Outlet, createBrowserRouter, useNavigate, useParams } from 'react-router-dom';

import type { Event } from './domain/event.ts';
import { eventRepository } from './data/eventRepository.ts';
import { supabase } from './lib/supabase.ts';
import { TodayView } from './features/today/TodayView.tsx';
import { MonthView } from './features/calendar/month/MonthView.tsx';
import WeekView from './features/calendar/week/WeekView.tsx';
import { EventForm } from './features/event/EventForm.tsx';
import { EventDetail } from './features/event/EventDetail.tsx';

/**
 * 로그인 세션에서 현재 사용자 id를 읽어온다.
 * 인증 흐름(로그인/로그아웃)은 아직 붙지 않았으므로(src/lib/supabase.ts 주석 참고),
 * 여기서는 현재 세션의 user id만 읽어 EventForm에 전달한다.
 */
function useCurrentUserId(): { userId: string | null; loading: boolean } {
  const [userId, setUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    supabase.auth.getUser().then(({ data }) => {
      if (cancelled) {
        return;
      }
      setUserId(data.user?.id ?? null);
      setLoading(false);
    });

    return () => {
      cancelled = true;
    };
  }, []);

  return { userId, loading };
}

/** 하단 탭 내비게이션을 포함하는 공용 레이아웃. */
function AppLayout() {
  return (
    <div className="app-layout">
      <main className="app-layout__content">
        <Outlet />
      </main>
      <nav className="app-layout__nav">
        <Link to="/today">오늘</Link>
        <Link to="/calendar/month">월간</Link>
        <Link to="/calendar/week">주간</Link>
        <Link to="/event/new">일정 추가</Link>
      </nav>
    </div>
  );
}

/** 새 일정 생성 라우트. */
function EventNewRoute() {
  const navigate = useNavigate();
  const { userId, loading } = useCurrentUserId();

  if (loading) {
    return <p>불러오는 중...</p>;
  }
  if (userId === null) {
    return <p role="alert">로그인이 필요합니다.</p>;
  }

  return (
    <EventForm
      mode="create"
      userId={userId}
      onSaved={(event) => navigate(`/event/${event.id}`)}
      onCancel={() => navigate(-1)}
    />
  );
}

/** id 파라미터로 일정을 조회해 자식에게 전달하는 공용 로더. */
function useLoadedEvent(): { event: Event | null; error: string | null; loading: boolean } {
  const { id } = useParams<{ id: string }>();
  const [event, setEvent] = useState<Event | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    if (id === undefined) {
      setError('잘못된 요청입니다.');
      setLoading(false);
      return;
    }

    setLoading(true);
    eventRepository.getEvent(id).then((result) => {
      if (cancelled) {
        return;
      }
      if (result.error !== null) {
        setError(result.error.message);
        setEvent(null);
      } else if (result.data === null) {
        setError('일정을 찾을 수 없습니다.');
        setEvent(null);
      } else {
        setEvent(result.data);
        setError(null);
      }
      setLoading(false);
    });

    return () => {
      cancelled = true;
    };
  }, [id]);

  return { event, error, loading };
}

/** 일정 상세 라우트. */
function EventDetailRoute() {
  const navigate = useNavigate();
  const { event, error, loading } = useLoadedEvent();

  if (loading) {
    return <p>불러오는 중...</p>;
  }
  if (event === null) {
    return <p role="alert">{error ?? '일정을 찾을 수 없습니다.'}</p>;
  }

  return (
    <EventDetail
      event={event}
      onDeleted={() => navigate('/today')}
      onEdit={(target) => navigate(`/event/${target.id}/edit`)}
    />
  );
}

/** 일정 수정 라우트. */
function EventEditRoute() {
  const navigate = useNavigate();
  const { userId, loading: userLoading } = useCurrentUserId();
  const { event, error, loading: eventLoading } = useLoadedEvent();

  if (userLoading || eventLoading) {
    return <p>불러오는 중...</p>;
  }
  if (userId === null) {
    return <p role="alert">로그인이 필요합니다.</p>;
  }
  if (event === null) {
    return <p role="alert">{error ?? '일정을 찾을 수 없습니다.'}</p>;
  }

  return (
    <EventForm
      mode="update"
      userId={userId}
      initialEvent={event}
      onSaved={(saved) => navigate(`/event/${saved.id}`)}
      onCancel={() => navigate(-1)}
    />
  );
}

export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppLayout />,
    children: [
      { index: true, element: <Navigate to="/today" replace /> },
      { path: 'today', element: <TodayView /> },
      { path: 'calendar/month', element: <MonthView /> },
      { path: 'calendar/week', element: <WeekView /> },
      { path: 'event/new', element: <EventNewRoute /> },
      { path: 'event/:id', element: <EventDetailRoute /> },
      { path: 'event/:id/edit', element: <EventEditRoute /> },
    ],
  },
]);
