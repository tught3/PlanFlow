import { describe, expect, it, vi } from 'vitest';

import {
  loadAdFrequencyState,
  recordFirstUseIfAbsent,
  recordInterstitialShown,
  type AdStatePort,
} from './adState.ts';

/** 테스트용 in-memory AdStatePort 구현. */
function createMemoryPort(initial?: Record<string, string>): AdStatePort {
  const store = new Map<string, string>(Object.entries(initial ?? {}));
  return {
    async getItem(key: string): Promise<string | null> {
      return store.has(key) ? store.get(key)! : null;
    },
    async setItem(key: string, value: string): Promise<void> {
      store.set(key, value);
    },
  };
}

const STORAGE_KEY = 'planflow_ad_frequency_v1';

describe('loadAdFrequencyState', () => {
  it('정상 round-trip: setItem 후 loadAdFrequencyState가 동일한 값을 반환한다', async () => {
    const port = createMemoryPort();
    const now = new Date('2026-08-07T01:00:00.000Z');

    await recordFirstUseIfAbsent(port, now);
    const state = await loadAdFrequencyState(port);

    expect(state.firstUsedAt).toEqual(now);
    expect(state.lastInterstitialAt).toBeNull();
    expect(state.lastInterstitialKstDay).toBeNull();
    expect(state.interstitialCountForDay).toBe(0);
  });

  it('저장된 값이 없으면 안전 기본값(최초 사용 상태)을 반환한다', async () => {
    const port = createMemoryPort();

    const state = await loadAdFrequencyState(port);

    expect(state).toEqual({
      firstUsedAt: null,
      lastInterstitialAt: null,
      lastInterstitialKstDay: null,
      interstitialCountForDay: 0,
    });
  });

  it('손상된 JSON 문자열이면 throw하지 않고 안전 기본값을 반환한다', async () => {
    const port = createMemoryPort({ [STORAGE_KEY]: '{not valid json' });

    const state = await loadAdFrequencyState(port);

    expect(state.firstUsedAt).toBeNull();
    expect(state.interstitialCountForDay).toBe(0);
  });

  it('파싱된 JSON에 필드가 누락돼 있으면 안전 기본값을 반환한다', async () => {
    const port = createMemoryPort({
      [STORAGE_KEY]: JSON.stringify({ firstUsedAt: '2026-08-01T00:00:00.000Z' }),
    });

    const state = await loadAdFrequencyState(port);

    expect(state).toEqual({
      firstUsedAt: null,
      lastInterstitialAt: null,
      lastInterstitialKstDay: null,
      interstitialCountForDay: 0,
    });
  });

  it('필드 타입이 잘못되면(firstUsedAt이 number) 안전 기본값을 반환한다', async () => {
    const port = createMemoryPort({
      [STORAGE_KEY]: JSON.stringify({
        firstUsedAt: 12345,
        lastInterstitialAt: null,
        lastInterstitialKstDay: null,
        interstitialCountForDay: 0,
      }),
    });

    const state = await loadAdFrequencyState(port);

    expect(state.firstUsedAt).toBeNull();
  });

  it('저장된 타임스탬프가 Invalid Date로 파싱되면 안전 기본값(null)으로 처리한다', async () => {
    const port = createMemoryPort({
      [STORAGE_KEY]: JSON.stringify({
        firstUsedAt: 'not-a-real-date',
        lastInterstitialAt: null,
        lastInterstitialKstDay: null,
        interstitialCountForDay: 0,
      }),
    });

    const state = await loadAdFrequencyState(port);

    expect(state.firstUsedAt).toBeNull();
  });

  it('port.getItem()이 예외를 던지면 그 예외를 전파하지 않고 안전 기본값을 반환한다', async () => {
    const port: AdStatePort = {
      getItem: vi.fn().mockRejectedValue(new Error('SDK unavailable')),
      setItem: vi.fn().mockResolvedValue(undefined),
    };

    const state = await loadAdFrequencyState(port);

    expect(state).toEqual({
      firstUsedAt: null,
      lastInterstitialAt: null,
      lastInterstitialKstDay: null,
      interstitialCountForDay: 0,
    });
  });
});

describe('recordFirstUseIfAbsent', () => {
  it('firstUsedAt이 이미 설정돼 있으면 덮어쓰지 않는다', async () => {
    const port = createMemoryPort();
    const originalNow = new Date('2026-08-01T00:00:00.000Z');
    await recordFirstUseIfAbsent(port, originalNow);

    const laterNow = new Date('2026-08-07T00:00:00.000Z');
    await recordFirstUseIfAbsent(port, laterNow);

    const state = await loadAdFrequencyState(port);
    expect(state.firstUsedAt).toEqual(originalNow);
  });

  it('firstUsedAt이 없으면 now로 기록한다', async () => {
    const port = createMemoryPort();
    const now = new Date('2026-08-07T00:00:00.000Z');

    await recordFirstUseIfAbsent(port, now);

    const state = await loadAdFrequencyState(port);
    expect(state.firstUsedAt).toEqual(now);
  });
});

describe('recordInterstitialShown', () => {
  it('같은 KST 날짜에 두 번 호출하면 카운트가 1 -> 2로 증가한다', async () => {
    const port = createMemoryPort();
    // KST 2026-08-07 10:00, 20:00 (둘 다 같은 KST 날짜)
    const first = new Date('2026-08-07T01:00:00.000Z'); // KST 10:00
    const second = new Date('2026-08-07T11:00:00.000Z'); // KST 20:00

    await recordInterstitialShown(port, first);
    let state = await loadAdFrequencyState(port);
    expect(state.interstitialCountForDay).toBe(1);
    expect(state.lastInterstitialKstDay).toBe('2026-08-07');

    await recordInterstitialShown(port, second);
    state = await loadAdFrequencyState(port);
    expect(state.interstitialCountForDay).toBe(2);
    expect(state.lastInterstitialAt).toEqual(second);
  });

  it('KST 날짜가 바뀌면 카운트가 1로 리셋된다', async () => {
    const port = createMemoryPort();
    const day1 = new Date('2026-08-07T01:00:00.000Z'); // KST 2026-08-07 10:00
    const day2 = new Date('2026-08-08T01:00:00.000Z'); // KST 2026-08-08 10:00

    await recordInterstitialShown(port, day1);
    await recordInterstitialShown(port, day1);
    let state = await loadAdFrequencyState(port);
    expect(state.interstitialCountForDay).toBe(2);

    await recordInterstitialShown(port, day2);
    state = await loadAdFrequencyState(port);
    expect(state.interstitialCountForDay).toBe(1);
    expect(state.lastInterstitialKstDay).toBe('2026-08-08');
  });

  it('port.setItem()이 예외를 던져도 전파하지 않는다(앱이 크래시하면 안 됨)', async () => {
    const port: AdStatePort = {
      getItem: vi.fn().mockResolvedValue(null),
      setItem: vi.fn().mockRejectedValue(new Error('write failed')),
    };

    await expect(recordInterstitialShown(port, new Date('2026-08-07T00:00:00.000Z'))).resolves.toBeUndefined();
  });
});
