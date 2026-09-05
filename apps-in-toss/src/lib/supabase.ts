/**
 * Supabase 클라이언트 (apps-in-toss 웹앱용).
 *
 * VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY는 .env(.local)에서 주입한다.
 * service_role 키는 절대 여기(클라이언트 번들)에 넣지 않는다 - anon key만 사용한다.
 *
 * 인증 세션 관리(로그인/로그아웃, persistSession 옵션 등)는 아직 붙지 않았다.
 * 지금은 데이터 레이어(src/data/*)가 쓸 클라이언트 인스턴스만 제공한다.
 */
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

// createClient()는 빈 문자열 URL을 넘기면 즉시 throw한다(모듈 로드 시점에 죽음).
// .env가 없는 로컬/테스트 환경(vitest 등)에서도 앱/테스트 모듈이 안전하게 로드되도록
// 값이 없으면 placeholder로 대체하고 콘솔에 경고만 남긴다 - 실제 요청은 당연히 실패하지만
// 그건 실 사용 시점(런타임) 문제이지 모듈 로드 시점에 앱 전체를 죽일 이유는 아니다.
const PLACEHOLDER_URL = 'https://placeholder.supabase.co';
const PLACEHOLDER_ANON_KEY = 'placeholder-anon-key';

if (!supabaseUrl || !supabaseAnonKey) {
  // eslint-disable-next-line no-console
  console.error(
    '[supabase] VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY가 설정되지 않았습니다. .env(.local)를 확인하세요.',
  );
}

export const supabase = createClient(supabaseUrl || PLACEHOLDER_URL, supabaseAnonKey || PLACEHOLDER_ANON_KEY);

export type SupabaseClientType = typeof supabase;
