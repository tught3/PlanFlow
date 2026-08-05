import { useEffect, useState } from 'react';
import { Link, Navigate, Outlet, createBrowserRouter, useNavigate, useParams } from 'react-router-dom';

import type { Event } from './domain/event.ts';
import { eventRepository } from './data/eventRepository.ts';
import { useSession } from './features/auth/useSession.ts';
import { LoginScreen } from './features/auth/LoginScreen.tsx';
import { TodayView } from './features/today/TodayView.tsx';
import { MonthView } from './features/calendar/month/MonthView.tsx';
import WeekView from './features/calendar/week/WeekView.tsx';
import { EventForm } from './features/event/EventForm.tsx';
import { EventDetail } from './features/event/EventDetail.tsx';

/**
 * 로그인 여부를 확인하는 게이트. AppLayout(하단 탭 포함) 상위에서 감싸서,
 * 로그인 전에는 하단 탭이 전혀 보이지 않고 /login으로 리다이렉트되게 한다.
 * 세션 상태는 useSession()이 getSession 초기조회 + onAuthStateChange 구독으로
 * 관리하므로, LoginScreen에서 로그인에 성공하면 이 게이트가 곧바로 리렌더된다.
 */
function AuthGate() {
  const { userId, loading } = useSession();

  if (loading) {
    return <p>불러오는 중...</p>;
  }
  if (userId === null) {
    return <Navigate to="/login" replace />;
  }

  return <Outlet />;
}

/** /login 라우트. 로그인 성공 시 오늘 화면으로 이동시킨다. */
function LoginRoute() {
  const navigate = useNavigate();
  return <LoginScreen onLoginSuccess={() => navigate('/today', { replace: true })} />;
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
  const { userId, loading } = useSession();

  if (loading) {
    return <p>불러오는 중...</p>;
  }
  if (userId === null) {
    // AuthGate가 상위에서 비로그인 상태를 걸러내므로 정상 흐름에서는 도달하지 않는다.
    return null;
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
  const { userId, loading: userLoading } = useSession();
  const { event, error, loading: eventLoading } = useLoadedEvent();

  if (userLoading || eventLoading) {
    return <p>불러오는 중...</p>;
  }
  if (userId === null) {
    // AuthGate가 상위에서 비로그인 상태를 걸러내므로 정상 흐름에서는 도달하지 않는다.
    return null;
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
  // /login은 AuthGate/AppLayout 바깥에 둔다 - 로그인 전에는 하단 탭이 보이면 안 된다.
  { path: '/login', element: <LoginRoute /> },
  {
    path: '/',
    element: <AuthGate />,
    children: [
      {
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
    ],
  },
]);
