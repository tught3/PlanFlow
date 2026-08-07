import { describe, expect, it } from 'vitest';

import {
  createAdSessionState,
  nextAdSessionState,
} from './adSession.ts';

describe('createAdSessionState', () => {
  it('명시적 now를 넣으면 그 값으로 초기 상태를 만든다', () => {
    const now = new Date('2026-08-07T00:00:00.000Z');
    const state = createAdSessionState(now);

    expect(state.sessionStartedAt).toBe(now);
    expect(state.meaningfulActionCompleted).toBe(false);
    expect(state.modalOpen).toBe(false);
  });
});

describe('nextAdSessionState', () => {
  it("'meaningful-action' 이벤트를 받으면 meaningfulActionCompleted가 true가 된다", () => {
    const state = createAdSessionState(new Date('2026-08-07T00:00:00.000Z'));

    const next = nextAdSessionState(state, { type: 'meaningful-action' });

    expect(next.meaningfulActionCompleted).toBe(true);
  });

  it('한 번 true가 되면 이후 다른 이벤트(modal-open)로도 false로 돌아가지 않는다(세션 내 sticky)', () => {
    const state = createAdSessionState(new Date('2026-08-07T00:00:00.000Z'));

    const afterAction = nextAdSessionState(state, { type: 'meaningful-action' });
    const afterModalOpen = nextAdSessionState(afterAction, { type: 'modal-open' });

    expect(afterModalOpen.meaningfulActionCompleted).toBe(true);
  });

  it("'modal-open' 이벤트를 받으면 modalOpen이 true가 된다", () => {
    const state = createAdSessionState(new Date('2026-08-07T00:00:00.000Z'));

    const next = nextAdSessionState(state, { type: 'modal-open' });

    expect(next.modalOpen).toBe(true);
  });

  it("'modal-close' 이벤트를 받으면 modalOpen이 false가 된다", () => {
    const state = createAdSessionState(new Date('2026-08-07T00:00:00.000Z'));
    const opened = nextAdSessionState(state, { type: 'modal-open' });

    const closed = nextAdSessionState(opened, { type: 'modal-close' });

    expect(closed.modalOpen).toBe(false);
  });

  it('매 호출마다 새 객체를 반환한다(불변 업데이트)', () => {
    const state = createAdSessionState(new Date('2026-08-07T00:00:00.000Z'));

    const next = nextAdSessionState(state, { type: 'meaningful-action' });

    expect(next).not.toBe(state);
  });
});
