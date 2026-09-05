/**
 * 전면 광고(interstitial) 노출 가능 여부를 판정하는 정책 엔진.
 *
 * 이 파일은 토스 광고 정책 위반(=앱 정지 리스크)을 막는 최종 방어선이므로,
 * 각 조건을 별도 이름의 함수로 분리해 실패 사유를 추적 가능하게 만든다
 * (하나의 거대한 if로 뭉치지 않는다 - 계획서 명시).
 *
 * 판정 불가/오염된 입력(adState===null, firstUsedAt===null 등)은 항상
 * "광고를 보여주지 않는 방향"(false)으로 fail-closed 처리한다.
 *
 * 날짜 경계 계산은 반드시 src/domain/datetime.ts의 isSameKstDay를 재사용한다
 * - 직접 24시간 차분으로 "같은 날"을 판정하지 않는다(자정 경계 오판 방지).
 */

import {
  FIRST_DAY_INTERSTITIAL_DISABLED,
  INTERSTITIAL_COOLDOWN_HOURS,
  INTERSTITIAL_MAX_PER_DAY,
  INTERSTITIAL_MIN_SESSION_SECONDS,
} from './adConfig';
import { isSameKstDay } from '../../domain/datetime';

/** 전면 광고 노출 여부 판정에 필요한 컨텍스트. */
export interface InterstitialEligibilityContext {
  authenticated: boolean;
  isAuthScreen: boolean;
  isEditingEvent: boolean;
  isDeleteConfirming: boolean;
  isSavePending: boolean;
  isErrorRecovering: boolean;
  modalOpen: boolean;
  session: { sessionStartedAt: Date; meaningfulActionCompleted: boolean };
  /** null이면 로컬 광고 상태가 오염/부재한 것으로 보고 fail-closed 처리한다. */
  adState: {
    firstUsedAt: Date | null;
    lastInterstitialAt: Date | null;
    interstitialCountToday: number;
  } | null;
}

const MS_PER_SECOND = 1000;
const MS_PER_HOUR = 60 * 60 * 1000;

/** 1. 로그인 상태인가. */
function isAuthenticated(context: InterstitialEligibilityContext): boolean {
  return context.authenticated === true;
}

/** 2. 인증(로그인) 화면이 아닌가. */
function isNotAuthScreen(context: InterstitialEligibilityContext): boolean {
  return !context.isAuthScreen;
}

/** 3. 일정 편집 중이 아닌가. */
function isNotEditingEvent(context: InterstitialEligibilityContext): boolean {
  return !context.isEditingEvent;
}

/** 3-1. 삭제 확인 중이 아닌가. */
function isNotDeleteConfirming(context: InterstitialEligibilityContext): boolean {
  return !context.isDeleteConfirming;
}

/** 3-2. 저장 직전(pending) 상태가 아닌가. */
function isNotSavePending(context: InterstitialEligibilityContext): boolean {
  return !context.isSavePending;
}

/** 3-3. 에러 복구 중이 아닌가. */
function isNotErrorRecovering(context: InterstitialEligibilityContext): boolean {
  return !context.isErrorRecovering;
}

/** 3-4. 다른 모달(예: 로그아웃 확인)이 열려 있지 않은가. */
function isNoModalOpen(context: InterstitialEligibilityContext): boolean {
  return !context.modalOpen;
}

/** 4. 로컬 광고 상태가 정상적으로 존재하는가(오염/부재 시 false). */
function hasValidAdState(context: InterstitialEligibilityContext): boolean {
  return context.adState !== null;
}

/**
 * 5. 설치 첫날 규칙을 통과하는가.
 * FIRST_DAY_INTERSTITIAL_DISABLED가 꺼져 있으면 항상 통과.
 * firstUsedAt이 null(첫 사용 시점 불명)이면 "첫날인지 판단 불가"로 보고
 * fail-closed(false) 처리한다.
 * firstUsedAt이 있으면 isSameKstDay로 오늘과 같은 KST 날짜인지 판정한다
 * (직접 24시간 차분 계산 금지 - 자정 경계에서 오판하기 때문).
 */
function passesFirstDayRule(
  context: InterstitialEligibilityContext,
  now: Date,
): boolean {
  if (!FIRST_DAY_INTERSTITIAL_DISABLED) {
    return true;
  }
  if (context.adState === null) {
    return false;
  }
  if (context.adState.firstUsedAt === null) {
    return false;
  }
  return !isSameKstDay(now, context.adState.firstUsedAt);
}

/** 6. 세션이 최소 지속 시간 이상 유지됐는가. */
function meetsMinSessionDuration(
  context: InterstitialEligibilityContext,
  now: Date,
): boolean {
  const elapsedSeconds =
    (now.getTime() - context.session.sessionStartedAt.getTime()) / MS_PER_SECOND;
  return elapsedSeconds >= INTERSTITIAL_MIN_SESSION_SECONDS;
}

/** 7. 이번 세션에서 의미 있는 행동이 완료됐는가. */
function hasMeaningfulActionCompleted(
  context: InterstitialEligibilityContext,
): boolean {
  return context.session.meaningfulActionCompleted === true;
}

/**
 * 8. 쿨다운(최소 재노출 간격)을 통과하는가.
 * lastInterstitialAt이 null이면 한 번도 노출된 적이 없다는 뜻이므로 통과.
 */
function passesCooldown(
  context: InterstitialEligibilityContext,
  now: Date,
): boolean {
  if (context.adState === null) {
    return false;
  }
  const { lastInterstitialAt } = context.adState;
  if (lastInterstitialAt === null) {
    return true;
  }
  const elapsedHours = (now.getTime() - lastInterstitialAt.getTime()) / MS_PER_HOUR;
  return elapsedHours >= INTERSTITIAL_COOLDOWN_HOURS;
}

/** 9. 오늘 노출 횟수가 일일 최대치 미만인가. */
function isUnderDailyMax(context: InterstitialEligibilityContext): boolean {
  if (context.adState === null) {
    return false;
  }
  return context.adState.interstitialCountToday < INTERSTITIAL_MAX_PER_DAY;
}

/** 각 체크의 이름과 판정 함수를 순서대로 나열한다(추적 가능한 실패 사유용). */
const CHECKS: Array<{
  name: string;
  evaluate: (context: InterstitialEligibilityContext, now: Date) => boolean;
}> = [
  { name: 'authenticated', evaluate: (context) => isAuthenticated(context) },
  { name: 'not-auth-screen', evaluate: (context) => isNotAuthScreen(context) },
  { name: 'not-editing-event', evaluate: (context) => isNotEditingEvent(context) },
  {
    name: 'not-delete-confirming',
    evaluate: (context) => isNotDeleteConfirming(context),
  },
  { name: 'not-save-pending', evaluate: (context) => isNotSavePending(context) },
  {
    name: 'not-error-recovering',
    evaluate: (context) => isNotErrorRecovering(context),
  },
  { name: 'no-modal-open', evaluate: (context) => isNoModalOpen(context) },
  { name: 'valid-ad-state', evaluate: (context) => hasValidAdState(context) },
  { name: 'first-day-rule', evaluate: (context, now) => passesFirstDayRule(context, now) },
  {
    name: 'min-session-duration',
    evaluate: (context, now) => meetsMinSessionDuration(context, now),
  },
  {
    name: 'meaningful-action-completed',
    evaluate: (context) => hasMeaningfulActionCompleted(context),
  },
  { name: 'cooldown', evaluate: (context, now) => passesCooldown(context, now) },
  { name: 'under-daily-max', evaluate: (context) => isUnderDailyMax(context) },
];

/**
 * 전면 광고를 지금 보여줘도 되는지 판정한다.
 * 모든 체크를 통과해야만 true - 하나라도 실패하면 false(fail-closed).
 */
export function canShowInterstitial(
  context: InterstitialEligibilityContext,
  now: Date = new Date(),
): boolean {
  return CHECKS.every(({ evaluate }) => evaluate(context, now));
}

/** 진단용: 어떤 체크가 실패했는지 함께 반환한다(테스트/디버깅용). */
export function explainInterstitialEligibility(
  context: InterstitialEligibilityContext,
  now: Date = new Date(),
): { eligible: boolean; failedChecks: string[] } {
  const failedChecks = CHECKS.filter(({ evaluate }) => !evaluate(context, now)).map(
    ({ name }) => name,
  );
  return { eligible: failedChecks.length === 0, failedChecks };
}
