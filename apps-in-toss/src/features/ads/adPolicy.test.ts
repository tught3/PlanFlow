import { describe, expect, it } from 'vitest';
import {
  canShowInterstitial,
  explainInterstitialEligibility,
  type InterstitialEligibilityContext,
} from './adPolicy';
import {
  INTERSTITIAL_COOLDOWN_HOURS,
  INTERSTITIAL_MAX_PER_DAY,
  INTERSTITIAL_MIN_SESSION_SECONDS,
} from './adConfig';
import { addKstDays, isSameKstDay, kstWallToInstant } from '../../domain/datetime';

const MS_PER_SECOND = 1000;
const MS_PER_HOUR = 60 * 60 * 1000;

/** 테스트 기준 "현재 시각": 2026-03-10 12:00:00 KST. */
const NOW = kstWallToInstant(2026, 2, 10, 12, 0, 0);

/**
 * 모든 조건을 통과하는 baseline 컨텍스트.
 * - firstUsedAt: 며칠 전(오늘과 다른 KST 날짜) -> 첫날 규칙 통과.
 * - sessionStartedAt: 최소 세션 시간의 2배 전 -> 세션 시간 통과.
 * - lastInterstitialAt: 쿨다운의 2배 전 -> 쿨다운 통과.
 * - interstitialCountToday: 0 -> 일일 최대치 미만.
 */
function baselineContext(now: Date = NOW): InterstitialEligibilityContext {
  return {
    authenticated: true,
    isAuthScreen: false,
    isEditingEvent: false,
    isDeleteConfirming: false,
    isSavePending: false,
    isErrorRecovering: false,
    modalOpen: false,
    session: {
      sessionStartedAt: new Date(
        now.getTime() - INTERSTITIAL_MIN_SESSION_SECONDS * 2 * MS_PER_SECOND,
      ),
      meaningfulActionCompleted: true,
    },
    adState: {
      firstUsedAt: addKstDays(now, -3),
      lastInterstitialAt: new Date(
        now.getTime() - INTERSTITIAL_COOLDOWN_HOURS * 2 * MS_PER_HOUR,
      ),
      interstitialCountToday: 0,
    },
  };
}

describe('canShowInterstitial', () => {
  it('15. 모든 조건이 충족되면 true를 반환한다(baseline happy path)', () => {
    expect(canShowInterstitial(baselineContext(), NOW)).toBe(true);
  });

  it('1. 설치 첫날(firstUsedAt이 오늘과 같은 KST 날짜)이면 false를 반환한다', () => {
    const context = baselineContext();
    context.adState = {
      ...context.adState!,
      firstUsedAt: NOW,
    };
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('2. 세션 지속 시간이 최소치 미만이면 false를 반환한다', () => {
    const context = baselineContext();
    context.session = {
      ...context.session,
      sessionStartedAt: new Date(
        NOW.getTime() - (INTERSTITIAL_MIN_SESSION_SECONDS - 1) * MS_PER_SECOND,
      ),
    };
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('3. 세션 지속 시간은 충족했지만 의미 있는 행동이 없으면 false를 반환한다', () => {
    const context = baselineContext();
    context.session = {
      ...context.session,
      meaningfulActionCompleted: false,
    };
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('4. 의미 있는 행동 완료 + 나머지 조건 충족 시 true를 반환한다(happy path)', () => {
    const context = baselineContext();
    context.session = {
      ...context.session,
      meaningfulActionCompleted: true,
    };
    expect(canShowInterstitial(context, NOW)).toBe(true);
  });

  it('5. 마지막 전면 광고 노출이 24시간 미만 전이면 false를 반환한다', () => {
    const context = baselineContext();
    context.adState = {
      ...context.adState!,
      lastInterstitialAt: new Date(
        NOW.getTime() - (INTERSTITIAL_COOLDOWN_HOURS - 1) * MS_PER_HOUR,
      ),
    };
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('6. 마지막 전면 광고 노출이 24시간 이상 전(나머지 조건 충족)이면 true를 반환한다', () => {
    const context = baselineContext();
    context.adState = {
      ...context.adState!,
      lastInterstitialAt: new Date(
        NOW.getTime() - INTERSTITIAL_COOLDOWN_HOURS * MS_PER_HOUR,
      ),
    };
    expect(canShowInterstitial(context, NOW)).toBe(true);
  });

  it('7. 오늘 노출 횟수가 이미 일일 최대치에 도달했으면 false를 반환한다', () => {
    const context = baselineContext();
    context.adState = {
      ...context.adState!,
      interstitialCountToday: INTERSTITIAL_MAX_PER_DAY,
    };
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('8. 인증 화면이면 false를 반환한다', () => {
    const context = baselineContext();
    context.isAuthScreen = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('9. 일정 편집 중이면 false를 반환한다', () => {
    const context = baselineContext();
    context.isEditingEvent = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('10. 모달이 열려 있으면 false를 반환한다', () => {
    const context = baselineContext();
    context.modalOpen = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('11a. 삭제 확인 중이면 false를 반환한다', () => {
    const context = baselineContext();
    context.isDeleteConfirming = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('11b. 저장 직전(pending) 상태면 false를 반환한다', () => {
    const context = baselineContext();
    context.isSavePending = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('11c. 에러 복구 중이면 false를 반환한다', () => {
    const context = baselineContext();
    context.isErrorRecovering = true;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('12. adState가 null(로컬 상태 오염/부재)이면 false를 반환한다', () => {
    const context = baselineContext();
    context.adState = null;
    expect(canShowInterstitial(context, NOW)).toBe(false);
  });

  it('13. 자정(KST) 경계를 넘으면 첫날 규칙은 isSameKstDay 기준으로 더 이상 적용되지 않는다', () => {
    // firstUsedAt: 2026-01-01 23:59:59 KST, now: 2026-01-02 00:00:01 KST.
    // 실제 경과 시간은 2초뿐이지만 KST 날짜 경계를 넘었으므로 "첫날"이 아니다.
    // 24시간 차분으로 직접 계산했다면(오답) 여전히 "같은 날"로 오판했을 것이다.
    const firstUsedAt = kstWallToInstant(2026, 0, 1, 23, 59, 59);
    const now = kstWallToInstant(2026, 0, 2, 0, 0, 1);

    // 사전 확인: 이 두 시각은 서로 다른 KST 날짜에 속한다(isSameKstDay 재사용).
    expect(isSameKstDay(now, firstUsedAt)).toBe(false);

    const context = baselineContext(now);
    context.adState = {
      ...context.adState!,
      firstUsedAt,
    };
    expect(canShowInterstitial(context, now)).toBe(true);
  });

  it('13b. 반대로 같은 KST 날짜 안에서는(자정 넘지 않음) 여전히 첫날로 판정된다', () => {
    const firstUsedAt = kstWallToInstant(2026, 0, 1, 0, 0, 1);
    const now = kstWallToInstant(2026, 0, 1, 23, 59, 59);

    expect(isSameKstDay(now, firstUsedAt)).toBe(true);

    const context = baselineContext(now);
    context.adState = {
      ...context.adState!,
      firstUsedAt,
    };
    expect(canShowInterstitial(context, now)).toBe(false);
  });

  it('14. 단일 조건 매트릭스: 9개 조건 중 정확히 하나만 실패해도 항상 false여야 한다', () => {
    type Mutation = {
      description: string;
      apply: (context: InterstitialEligibilityContext) => void;
    };

    const mutations: Mutation[] = [
      {
        description: 'authenticated=false',
        apply: (context) => {
          context.authenticated = false;
        },
      },
      {
        description: 'isAuthScreen=true',
        apply: (context) => {
          context.isAuthScreen = true;
        },
      },
      {
        description: 'isEditingEvent=true',
        apply: (context) => {
          context.isEditingEvent = true;
        },
      },
      {
        description: 'isDeleteConfirming=true',
        apply: (context) => {
          context.isDeleteConfirming = true;
        },
      },
      {
        description: 'isSavePending=true',
        apply: (context) => {
          context.isSavePending = true;
        },
      },
      {
        description: 'isErrorRecovering=true',
        apply: (context) => {
          context.isErrorRecovering = true;
        },
      },
      {
        description: 'modalOpen=true',
        apply: (context) => {
          context.modalOpen = true;
        },
      },
      {
        description: 'adState=null',
        apply: (context) => {
          context.adState = null;
        },
      },
      {
        description: 'firstUsedAt=오늘(첫날 규칙 위반)',
        apply: (context) => {
          context.adState = { ...context.adState!, firstUsedAt: NOW };
        },
      },
      {
        description: '세션 지속시간 미달',
        apply: (context) => {
          context.session = {
            ...context.session,
            sessionStartedAt: new Date(
              NOW.getTime() - (INTERSTITIAL_MIN_SESSION_SECONDS - 1) * MS_PER_SECOND,
            ),
          };
        },
      },
      {
        description: 'meaningfulActionCompleted=false',
        apply: (context) => {
          context.session = { ...context.session, meaningfulActionCompleted: false };
        },
      },
      {
        description: '쿨다운 미충족',
        apply: (context) => {
          context.adState = {
            ...context.adState!,
            lastInterstitialAt: new Date(
              NOW.getTime() - (INTERSTITIAL_COOLDOWN_HOURS - 1) * MS_PER_HOUR,
            ),
          };
        },
      },
      {
        description: '일일 최대치 도달',
        apply: (context) => {
          context.adState = {
            ...context.adState!,
            interstitialCountToday: INTERSTITIAL_MAX_PER_DAY,
          };
        },
      },
    ];

    // baseline 자체는 모든 조건을 충족해야 한다(매트릭스의 기준선).
    expect(canShowInterstitial(baselineContext(), NOW)).toBe(true);

    for (const mutation of mutations) {
      const context = baselineContext();
      mutation.apply(context);
      const result = canShowInterstitial(context, NOW);
      expect(
        result,
        `조건 "${mutation.description}"만 실패했는데도 true가 반환됨(나쁜 광고 노출 위험)`,
      ).toBe(false);
    }
  });
});

describe('explainInterstitialEligibility', () => {
  it('모든 조건 충족 시 eligible=true, failedChecks=[]를 반환한다', () => {
    const result = explainInterstitialEligibility(baselineContext(), NOW);
    expect(result.eligible).toBe(true);
    expect(result.failedChecks).toEqual([]);
  });

  it('여러 조건이 동시에 실패하면 실패한 체크 이름을 모두 나열한다', () => {
    const context = baselineContext();
    context.isAuthScreen = true;
    context.modalOpen = true;
    context.session = { ...context.session, meaningfulActionCompleted: false };

    const result = explainInterstitialEligibility(context, NOW);
    expect(result.eligible).toBe(false);
    expect(result.failedChecks).toContain('not-auth-screen');
    expect(result.failedChecks).toContain('no-modal-open');
    expect(result.failedChecks).toContain('meaningful-action-completed');
    expect(result.failedChecks.length).toBe(3);
  });

  it('adState가 null이면 그로부터 파생되는 모든 체크가 함께 실패로 보고된다', () => {
    const context = baselineContext();
    context.adState = null;

    const result = explainInterstitialEligibility(context, NOW);
    expect(result.eligible).toBe(false);
    expect(result.failedChecks).toContain('valid-ad-state');
    expect(result.failedChecks).toContain('first-day-rule');
    expect(result.failedChecks).toContain('cooldown');
    expect(result.failedChecks).toContain('under-daily-max');
  });
});
