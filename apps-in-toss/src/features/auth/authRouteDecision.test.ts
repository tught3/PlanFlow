import { describe, expect, it } from 'vitest';

import type { SessionState } from './authRouteDecision.ts';
import { resolveAuthGateDecision, resolveLoginRouteDecision } from './authRouteDecision.ts';

const ALL_STATES: SessionState[] = [
  { loading: true, userId: null },
  { loading: true, userId: 'some-user-id' },
  { loading: false, userId: null },
  { loading: false, userId: 'some-user-id' },
];

describe('resolveAuthGateDecision', () => {
  it('loading=true, userId=null -> wait', () => {
    expect(resolveAuthGateDecision({ loading: true, userId: null })).toBe('wait');
  });

  it('loading=true, userId=set -> wait', () => {
    expect(resolveAuthGateDecision({ loading: true, userId: 'some-user-id' })).toBe('wait');
  });

  it('loading=false, userId=null -> redirect', () => {
    expect(resolveAuthGateDecision({ loading: false, userId: null })).toBe('redirect');
  });

  it('loading=false, userId=set -> render', () => {
    expect(resolveAuthGateDecision({ loading: false, userId: 'some-user-id' })).toBe('render');
  });
});

describe('resolveLoginRouteDecision', () => {
  it('loading=true, userId=null -> wait', () => {
    expect(resolveLoginRouteDecision({ loading: true, userId: null })).toBe('wait');
  });

  it('loading=true, userId=set -> wait', () => {
    expect(resolveLoginRouteDecision({ loading: true, userId: 'some-user-id' })).toBe('wait');
  });

  it('loading=false, userId=null -> render', () => {
    expect(resolveLoginRouteDecision({ loading: false, userId: null })).toBe('render');
  });

  it('loading=false, userId=set -> redirect', () => {
    expect(resolveLoginRouteDecision({ loading: false, userId: 'some-user-id' })).toBe('redirect');
  });
});

describe('no simultaneous redirect (redirect-loop proof)', () => {
  it('never both resolve to redirect for any of the 4 states', () => {
    for (const state of ALL_STATES) {
      const gate = resolveAuthGateDecision(state);
      const login = resolveLoginRouteDecision(state);
      const bothRedirect = gate === 'redirect' && login === 'redirect';
      expect(bothRedirect).toBe(false);
    }
  });
});

describe('loading always wins over redirect', () => {
  it('while loading=true, both functions return wait for every userId value, never redirect', () => {
    const loadingStates = ALL_STATES.filter((state) => state.loading);
    expect(loadingStates.length).toBe(2);

    for (const state of loadingStates) {
      expect(resolveAuthGateDecision(state)).toBe('wait');
      expect(resolveLoginRouteDecision(state)).toBe('wait');
    }
  });
});
