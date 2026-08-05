/**
 * 현재 Supabase 인증 세션의 사용자 id를 구독하는 훅.
 *
 * router.tsx의 예전 useCurrentUserId는 supabase.auth.getUser()로 마운트 시점 1회만
 * 조회해서, 로그인 화면(LoginScreen)에서 로그인에 성공해도 이미 마운트된 게이트가
 * 리렌더되지 않는 문제가 있었다. 이 훅은 초기 조회(getSession) + onAuthStateChange
 * 구독을 함께 써서 로그인/로그아웃이 발생하면 즉시 반영되게 한다.
 */
import { useEffect, useState } from 'react';

import { supabase } from '../../lib/supabase.ts';

export interface SessionState {
  /** 로그인된 사용자 id. 로그인되어 있지 않으면 null. */
  userId: string | null;
  /** 초기 세션 조회가 아직 끝나지 않았으면 true. */
  loading: boolean;
}

export function useSession(): SessionState {
  const [userId, setUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) {
        return;
      }
      setUserId(data.session?.user.id ?? null);
      setLoading(false);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) {
        return;
      }
      setUserId(session?.user.id ?? null);
      setLoading(false);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);

  return { userId, loading };
}
