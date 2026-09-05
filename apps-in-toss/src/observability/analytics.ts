/**
 * analytics.ts
 *
 * Minimal analytics stub. `track()` currently only logs to
 * console.debug — no network calls, no third-party SDK wired in yet.
 * Kept as a stable call-site so feature code can start emitting events
 * now without churn once a real analytics backend is chosen.
 */

export type AnalyticsProps = Record<string, string | number | boolean | null | undefined>;

/**
 * Records an analytics event. Currently a no-op beyond a debug log —
 * intentionally does not send PII-bearing props anywhere. Callers should
 * still avoid passing raw PII (title/memo/participants/etc.) in `props`.
 */
export function track(eventName: string, props?: AnalyticsProps): void {
  // eslint-disable-next-line no-console
  console.debug("[analytics]", eventName, props ?? {});
}
