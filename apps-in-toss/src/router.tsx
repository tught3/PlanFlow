import { useEffect, useState } from 'react';
import {
  NavLink,
  Navigate,
  Outlet,
  createBrowserRouter,
  useNavigate,
  useParams,
} from 'react-router-dom';

import type { Event } from './domain/event.ts';
import { eventRepository } from './data/eventRepository.ts';
import { supabase } from './lib/supabase.ts';
import { useSession } from './features/auth/useSession.ts';
import { LoginScreen } from './features/auth/LoginScreen.tsx';
import { TodayView } from './features/today/TodayView.tsx';
import { MonthView } from './features/calendar/month/MonthView.tsx';
import WeekView from './features/calendar/week/WeekView.tsx';
import { EventForm } from './features/event/EventForm.tsx';
import { EventDetail } from './features/event/EventDetail.tsx';
import { ConfirmDialog } from './components/index.ts';
import type { LogoutUiState } from './appLayoutLogout.ts';
import { nextLogoutState } from './appLayoutLogout.ts';

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

/** 하단 탭 목록. NavLink가 현재 경로와 일치 여부를 판단해 활성 클래스를 붙인다. */
const NAV_ITEMS = [
  { to: '/today', label: '오늘' },
  { to: '/calendar/month', label: '월간' },
  { to: '/calendar/week', label: '주간' },
  { to: '/event/new', label: '일정 추가' },
] as const;

/**
 * 하단 탭 내비게이션 + 상단 헤더(타이틀/로그아웃)를 포함하는 공용 레이아웃.
 *
 * 로그아웃 확인/실행 상태 머신(nextLogoutState)은 별도 파일
 * src/appLayoutLogout.ts로 분리되어 있다 - 이유는 그 파일 상단 주석 참고
 * (router.tsx를 그대로 테스트에서 import하면 createBrowserRouter가 모듈
 * 로드 시점에 document를 참조해 jsdom 없는 이 프로젝트의 vitest에서 죽는다).
 *
 * 이 앱은 별도 로컬 캐시(localStorage/sessionStorage/IndexedDB)를 쓰지 않는다
 * (src 전체에 해당 API 사용처가 없음, 데이터는 항상 eventRepository를 통해
 * Supabase에서 직접 조회한다). supabase-js 클라이언트 자체가 세션 토큰을
 * 내부적으로 영속화하지만, 그 저장소도 supabase.auth.signOut() 호출 시
 * supabase-js가 알아서 정리한다. 따라서 "로그아웃 시 로컬 데이터 삭제"라는
 * 요구는 이 앱에 signOut() 호출 이상의 별도 캐시 삭제 로직이 필요 없다 -
 * 세션 종료 자체로 충족된다.
 */
function AppLayout() {
  const navigate = useNavigate();
  const [logoutState, setLogoutState] = useState<LogoutUiState>('idle');

  useEffect(() => {
    if (logoutState !== 'signing-out') {
      return;
    }
    let cancelled = false;
    supabase.auth.signOut().then(() => {
      if (cancelled) {
        return;
      }
      navigate('/login', { replace: true });
    });
    return () => {
      cancelled = true;
    };
  }, [logoutState, navigate]);

  return (
    <div className="app-layout">
      <header className="app-layout__header">
        <h1 className="app-layout__title">PlanFlow</h1>
        <button
          type="button"
          className="app-layout__logout"
          onClick={() => setLogoutState((state) => nextLogoutState(state, 'open-dialog'))}
        >
          로그아웃
        </button>
      </header>
      <main className="app-layout__content">
        <Outlet />
      </main>
      <nav className="app-layout__nav">
        {NAV_ITEMS.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            // NavLink는 활성 상태일 때 aria-current="page"를 자동으로 붙인다
            // (react-router-dom 기본 동작) - 별도로 지정할 필요 없다.
            className={({ isActive }) =>
              isActive ? 'app-layout__nav-item app-layout__nav-item--active' : 'app-layout__nav-item'
            }
          >
            {item.label}
          </NavLink>
        ))}
      </nav>
      <ConfirmDialog
        open={logoutState === 'confirming'}
        title="로그아웃 하시겠습니까?"
        message="로컬에 별도로 저장된 데이터가 없어, 로그아웃하면 세션 종료만으로 정리가 완료됩니다."
        confirmLabel="로그아웃"
        danger
        onConfirm={() => setLogoutState((state) => nextLogoutState(state, 'confirm'))}
        onCancel={() => setLogoutState((state) => nextLogoutState(state, 'cancel'))}
      />
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
