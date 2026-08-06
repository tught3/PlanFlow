import { Suspense, lazy, useEffect, useState } from 'react';
import {
  NavLink,
  Navigate,
  Outlet,
  createBrowserRouter,
  useNavigate,
  useParams,
} from 'react-router-dom';

import type { Event } from './domain/event.ts';
import type { EventRepository } from './data/eventRepository.ts';
import { eventRepository } from './data/eventRepository.ts';
import { supabase } from './lib/supabase.ts';
import { useSession } from './features/auth/useSession.ts';
import { LoginScreen } from './features/auth/LoginScreen.tsx';
import { ConfirmDialog, ErrorMessage, Spinner } from './components/index.ts';
import type { LogoutUiState } from './appLayoutLogout.ts';
import { nextLogoutState } from './appLayoutLogout.ts';
import { isDevPreviewEnabled, previewRepository } from './features/devPreview/index.ts';

/**
 * F1: 라우트 단위 코드 분할.
 *
 * 아래 5개 화면(오늘/월간/주간/일정폼/일정상세)은 router.tsx에서만 정적 import되던
 * 유일한 소비처였다(테스트 파일 제외, 실측 확인됨) - 그래서 React.lazy로 바꿔도
 * 다른 곳에서 동시에 static import돼 번들이 중복 포함되는 문제가 없다.
 *
 * TodayView/EventForm/EventDetail은 named export만 있어 default 어댑터가 필요하고,
 * MonthView/WeekView는 default export가 있어 바로 연결된다.
 */
const TodayView = lazy(() =>
  import('./features/today/TodayView.tsx').then((m) => ({ default: m.TodayView })),
);
const MonthView = lazy(() => import('./features/calendar/month/MonthView.tsx'));
const WeekView = lazy(() => import('./features/calendar/week/WeekView.tsx'));
const EventForm = lazy(() =>
  import('./features/event/EventForm.tsx').then((m) => ({ default: m.EventForm })),
);
const EventDetail = lazy(() =>
  import('./features/event/EventDetail.tsx').then((m) => ({ default: m.EventDetail })),
);

/**
 * 이 세션(모듈 로드 시점)에서 실제로 쓸 이벤트 리포지토리.
 *
 * isDevPreviewEnabled()는 import.meta.env(빌드/런타임 시점에 고정되는 값)만
 * 참조하므로 페이지 로드 중간에 값이 바뀌지 않는다 - 모듈 최상단에서 한 번만
 * 평가해 아래 라우트 트리 전체(TodayView/MonthView/WeekView, 그리고
 * useLoadedEvent가 EventDetail/EventForm에 넘기는 repository)가 동일한
 * 인스턴스를 공유하게 한다.
 */
const activeEventRepository = isDevPreviewEnabled() ? previewRepository : eventRepository;

/**
 * 로그인 여부를 확인하는 게이트. AppLayout(하단 탭 포함) 상위에서 감싸서,
 * 로그인 전에는 하단 탭이 전혀 보이지 않고 /login으로 리다이렉트되게 한다.
 * 세션 상태는 useSession()이 getSession 초기조회 + onAuthStateChange 구독으로
 * 관리하므로, LoginScreen에서 로그인에 성공하면 이 게이트가 곧바로 리렌더된다.
 */
function AuthGate() {
  const { userId, loading } = useSession();

  if (loading) {
    return <Spinner />;
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
      {isDevPreviewEnabled() ? (
        // 그룹A(styles/*.css) 소유 파일을 건드리지 않기 위해 인라인 스타일만 쓴다.
        // 이 배너는 개발 미리보기 모드가 꺼져 있으면(production 기본값) 렌더링되지
        // 않는다 - isDevPreviewEnabled()가 false를 반환하는 즉시 이 분기 전체가
        // 평가되지 않는다.
        <div
          role="status"
          style={{
            background: '#fef3c7',
            color: '#92400e',
            textAlign: 'center',
            padding: '8px 16px',
            fontSize: '13px',
            fontWeight: 600,
          }}
        >
          개발 미리보기 모드 — 실제 데이터가 아닙니다
        </div>
      ) : null}
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
    return <Spinner />;
  }
  if (userId === null) {
    // AuthGate가 상위에서 비로그인 상태를 걸러내므로 정상 흐름에서는 도달하지 않는다.
    return null;
  }

  return (
    <Suspense fallback={<Spinner />}>
      <EventForm
        mode="create"
        userId={userId}
        repository={activeEventRepository}
        onSaved={(event) => navigate(`/event/${event.id}`)}
        onCancel={() => navigate(-1)}
      />
    </Suspense>
  );
}

/**
 * id 파라미터로 일정을 조회해 자식에게 전달하는 공용 로더.
 *
 * repository 인자는 D2가 만든 activeEventRepository(개발 미리보기 모드에서는
 * previewRepository, 아니면 실제 eventRepository)를 그대로 통과시키는 주입
 * 통로다 - 기본값은 실제 eventRepository 싱글턴이라 인자를 생략해도 기존
 * 동작과 동일하다.
 */
function useLoadedEvent(
  repository: EventRepository = eventRepository,
): { event: Event | null; error: string | null; loading: boolean } {
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
    repository.getEvent(id).then((result) => {
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
  }, [id, repository]);

  return { event, error, loading };
}

/** 일정 상세 라우트. */
function EventDetailRoute() {
  const navigate = useNavigate();
  const { event, error, loading } = useLoadedEvent(activeEventRepository);

  if (loading) {
    return <Spinner />;
  }
  if (event === null) {
    return <ErrorMessage message={error ?? '일정을 찾을 수 없습니다.'} />;
  }

  return (
    <Suspense fallback={<Spinner />}>
      <EventDetail
        event={event}
        repository={activeEventRepository}
        onDeleted={() => navigate('/today')}
        onEdit={(target) => navigate(`/event/${target.id}/edit`)}
      />
    </Suspense>
  );
}

/** 일정 수정 라우트. */
function EventEditRoute() {
  const navigate = useNavigate();
  const { userId, loading: userLoading } = useSession();
  const { event, error, loading: eventLoading } = useLoadedEvent(activeEventRepository);

  if (userLoading || eventLoading) {
    return <Spinner />;
  }
  if (userId === null) {
    // AuthGate가 상위에서 비로그인 상태를 걸러내므로 정상 흐름에서는 도달하지 않는다.
    return null;
  }
  if (event === null) {
    return <ErrorMessage message={error ?? '일정을 찾을 수 없습니다.'} />;
  }

  return (
    <Suspense fallback={<Spinner />}>
      <EventForm
        mode="update"
        userId={userId}
        initialEvent={event}
        repository={activeEventRepository}
        onSaved={(saved) => navigate(`/event/${saved.id}`)}
        onCancel={() => navigate(-1)}
      />
    </Suspense>
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
          {
            path: 'today',
            element: (
              <Suspense fallback={<Spinner />}>
                <TodayView repository={activeEventRepository} />
              </Suspense>
            ),
          },
          {
            path: 'calendar/month',
            element: (
              <Suspense fallback={<Spinner />}>
                <MonthView repository={activeEventRepository} />
              </Suspense>
            ),
          },
          {
            path: 'calendar/week',
            element: (
              <Suspense fallback={<Spinner />}>
                <WeekView repository={activeEventRepository} />
              </Suspense>
            ),
          },
          { path: 'event/new', element: <EventNewRoute /> },
          { path: 'event/:id', element: <EventDetailRoute /> },
          { path: 'event/:id/edit', element: <EventEditRoute /> },
        ],
      },
    ],
  },
]);
