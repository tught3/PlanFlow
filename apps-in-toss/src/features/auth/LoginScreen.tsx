/**
 * 토스 로그인 화면 (Apps in Toss 비게임 앱 심사 체크리스트 1절 대응).
 *
 * 체크리스트 대응:
 * - 토스 로그인 버튼 1개만 노출한다. 이메일/비밀번호 등 자체 로그인 입력 필드는 두지 않는다.
 * - 서비스 설명 문구를 화면에 표시한다.
 * - 개인정보처리방침 링크는 @apps-in-toss/web-framework의 openURL로 외부 브라우저에서 연다.
 * - 로그인 거부(사용자 취소)/실패 시 "다시 시도"와 "앱 종료"(Screen.close) 선택지를 함께 제공한다.
 *
 * 실제 로그인 로직은 tossLogin.ts의 runTossLogin만 호출하고, 이 파일에서 직접
 * fetch나 supabase를 호출하지 않는다.
 */
import { useState } from 'react';
import { Screen, openURL } from '@apps-in-toss/web-framework';

import { createDefaultTossLoginDeps, runTossLogin } from './tossLogin.ts';
import type { TossLoginDeps, TossLoginResult } from './tossLogin.ts';

/**
 * TODO(P10): 개인정보처리방침 URL 정본 재확인 필요.
 * docs/play-console-data-safety.md:15는 `https://fluxstudio.co.kr/privacy`를 쓰지만,
 * docs/play-console-submission.md에는 다른 URL(tught3.github.io/...)이 함께 존재해
 * 두 문서가 불일치한다. 실제 제출/심사 전에 어느 쪽이 정본인지 확인하고
 * 이 링크와 두 문서를 함께 갱신해야 한다. 지금은 데이터 보안 답변표(정식 제출용
 * Play Console 표)에 실린 값을 정본으로 간주해 사용한다.
 */
const PRIVACY_POLICY_URL = 'https://fluxstudio.co.kr/privacy';

export interface LoginScreenState {
  /** 사용자에게 보여줄 상태 메시지. */
  message: string;
  /** "다시 시도" 버튼을 보여줄지 여부. */
  canRetry: boolean;
  /** "앱 종료" 버튼을 보여줄지 여부(로그인 거부/실패 시에만 true). */
  shouldOfferExit: boolean;
}

/**
 * TossLoginResult -> 화면 상태로 변환하는 순수 함수.
 *
 * 로그인 거부(user_cancelled)와 그 외 실패 코드를 구분하지 않고 동일하게
 * "다시 시도"+"앱 종료" 선택지를 제공한다 - 심사 체크리스트가 요구하는
 * "로그인 거부 시 앱 종료" 흐름을 실패 전반으로 넓혀 적용한 것이다.
 */
export function buildLoginScreenState(result: TossLoginResult): LoginScreenState {
  if (result.ok) {
    return { message: '로그인되었습니다.', canRetry: false, shouldOfferExit: false };
  }
  return { message: result.message, canRetry: true, shouldOfferExit: true };
}

export interface LoginScreenProps {
  /** 테스트/커스텀 조립용. 생략하면 createDefaultTossLoginDeps()를 사용한다. */
  deps?: TossLoginDeps;
  onLoginSuccess?: (result: Extract<TossLoginResult, { ok: true }>) => void;
}

export function LoginScreen({ deps, onLoginSuccess }: LoginScreenProps = {}) {
  const [submitting, setSubmitting] = useState(false);
  const [state, setState] = useState<LoginScreenState | null>(null);

  async function handleLogin() {
    if (submitting) return;
    setSubmitting(true);

    const result = await runTossLogin(deps ?? createDefaultTossLoginDeps());
    const nextState = buildLoginScreenState(result);

    setState(nextState);
    setSubmitting(false);

    if (result.ok) {
      onLoginSuccess?.(result);
    }
  }

  function handleOpenPrivacyPolicy() {
    void openURL(PRIVACY_POLICY_URL);
  }

  function handleExit() {
    void Screen.close();
  }

  return (
    <section className="auth-login">
      <div className="pf-card auth-login__card">
        <h1 className="auth-login__title">PlanFlow</h1>
        <p className="auth-login__description">토스 안에서 AI 음성 일정 관리를 바로 시작하세요.</p>

        <button
          type="button"
          className="pf-button pf-button--primary auth-login__submit"
          onClick={() => void handleLogin()}
          disabled={submitting}
        >
          토스로 로그인
        </button>

        <button
          type="button"
          className="pf-button pf-button--ghost auth-login__privacy"
          onClick={handleOpenPrivacyPolicy}
        >
          개인정보처리방침
        </button>

        {state !== null ? (
          <p
            className={state.canRetry ? 'auth-login__message auth-login__message--error' : 'auth-login__message'}
            role={state.canRetry ? 'alert' : 'status'}
          >
            {state.message}
          </p>
        ) : null}

        {state !== null && state.canRetry ? (
          <button
            type="button"
            className="pf-button pf-button--primary"
            onClick={() => void handleLogin()}
            disabled={submitting}
          >
            다시 시도
          </button>
        ) : null}

        {state !== null && state.shouldOfferExit ? (
          <button type="button" className="pf-button pf-button--danger" onClick={handleExit}>
            앱 종료
          </button>
        ) : null}
      </div>
    </section>
  );
}
