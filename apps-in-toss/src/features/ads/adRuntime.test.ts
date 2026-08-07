import { describe, expect, it } from 'vitest';

import { buildInterstitialEligibilityContext, realAdSdk, realAdStatePort } from './adRuntime.ts';
import { createAdSessionState } from './adSession.ts';
import type { AdFrequencyState } from './adState.ts';

const NOW = new Date('2026-08-07T10:00:00.000Z');

function emptyFrequency(): AdFrequencyState {
  return {
    firstUsedAt: null,
    lastInterstitialAt: null,
    lastInterstitialKstDay: null,
    interstitialCountForDay: 0,
  };
}

describe('buildInterstitialEligibilityContext', () => {
  it('세션/빈도 상태를 InterstitialEligibilityContext 필드로 정확히 매핑한다', () => {
    const session = createAdSessionState(NOW);
    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session,
      frequency: emptyFrequency(),
      now: NOW,
    });

    expect(context.authenticated).toBe(true);
    expect(context.isAuthScreen).toBe(false);
    expect(context.isEditingEvent).toBe(false);
    expect(context.isDeleteConfirming).toBe(false);
    expect(context.isSavePending).toBe(false);
    expect(context.isErrorRecovering).toBe(false);
    expect(context.modalOpen).toBe(false);
    expect(context.session.sessionStartedAt).toBe(NOW);
    expect(context.session.meaningfulActionCompleted).toBe(false);
    expect(context.adState).not.toBeNull();
  });

  it('session.modalOpen이 true면 context.modalOpen도 true다', () => {
    const session = { ...createAdSessionState(NOW), modalOpen: true };
    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session,
      frequency: emptyFrequency(),
      now: NOW,
    });

    expect(context.modalOpen).toBe(true);
  });

  it('adState는 null이 아니다(호출부가 항상 로드된 frequency를 넘긴다는 계약)', () => {
    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session: createAdSessionState(NOW),
      frequency: emptyFrequency(),
      now: NOW,
    });

    expect(context.adState).toEqual({
      firstUsedAt: null,
      lastInterstitialAt: null,
      interstitialCountToday: 0,
    });
  });

  it('firstUsedAt/lastInterstitialAt은 frequency 값을 그대로 옮긴다', () => {
    const firstUsedAt = new Date('2026-08-01T00:00:00.000Z');
    const lastInterstitialAt = new Date('2026-08-07T09:00:00.000Z');
    const frequency: AdFrequencyState = {
      firstUsedAt,
      lastInterstitialAt,
      lastInterstitialKstDay: '2026-08-07',
      interstitialCountForDay: 1,
    };

    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session: createAdSessionState(NOW),
      frequency,
      now: NOW,
    });

    expect(context.adState?.firstUsedAt).toBe(firstUsedAt);
    expect(context.adState?.lastInterstitialAt).toBe(lastInterstitialAt);
  });

  it('lastInterstitialAt이 now와 같은 KST 날짜면 저장된 카운트를 그대로 쓴다', () => {
    const lastInterstitialAt = new Date('2026-08-07T01:00:00.000Z'); // 같은 KST 날짜(2026-08-07)
    const frequency: AdFrequencyState = {
      firstUsedAt: null,
      lastInterstitialAt,
      lastInterstitialKstDay: '2026-08-07',
      interstitialCountForDay: 1,
    };

    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session: createAdSessionState(NOW),
      frequency,
      now: NOW,
    });

    expect(context.adState?.interstitialCountToday).toBe(1);
  });

  it('lastInterstitialAt이 now와 다른 KST 날짜면 카운트를 0으로 취급한다(날짜 경계 리셋)', () => {
    // NOW=2026-08-07T10:00:00Z는 KST로 2026-08-07 19:00. 아래 값은
    // KST로 2026-08-06 19:00(전날)이라 명확히 다른 KST 날짜다.
    const lastInterstitialAt = new Date('2026-08-06T10:00:00.000Z');
    const frequency: AdFrequencyState = {
      firstUsedAt: null,
      lastInterstitialAt,
      lastInterstitialKstDay: '2026-08-06',
      interstitialCountForDay: 1,
    };

    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session: createAdSessionState(NOW),
      frequency,
      now: NOW,
    });

    expect(context.adState?.interstitialCountToday).toBe(0);
  });

  it('lastInterstitialAt이 null(한 번도 노출 안 됨)이면 카운트는 0이다', () => {
    const context = buildInterstitialEligibilityContext({
      authenticated: true,
      session: createAdSessionState(NOW),
      frequency: emptyFrequency(),
      now: NOW,
    });

    expect(context.adState?.interstitialCountToday).toBe(0);
  });

  it('authenticated=false를 그대로 전달한다', () => {
    const context = buildInterstitialEligibilityContext({
      authenticated: false,
      session: createAdSessionState(NOW),
      frequency: emptyFrequency(),
      now: NOW,
    });

    expect(context.authenticated).toBe(false);
  });
});

describe('realAdSdk / realAdStatePort', () => {
  it('실제 SDK로 조립된 AdSdk가 필요한 함수를 전부 갖고 있다', () => {
    expect(typeof realAdSdk.initialize).toBe('function');
    expect(typeof realAdSdk.isInitializeSupported).toBe('function');
    expect(typeof realAdSdk.isMinVersionSupported).toBe('function');
    expect(typeof realAdSdk.attachBanner).toBe('function');
    expect(typeof realAdSdk.loadFullScreenAd).toBe('function');
    expect(typeof realAdSdk.showFullScreenAd).toBe('function');
  });

  it('실제 Storage로 조립된 AdStatePort가 필요한 함수를 전부 갖고 있다', () => {
    expect(typeof realAdStatePort.getItem).toBe('function');
    expect(typeof realAdStatePort.setItem).toBe('function');
  });
});
