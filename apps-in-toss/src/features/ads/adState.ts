/**
 * 광고 노출 빈도 판단에 쓰는 영속 상태.
 *
 * adSession.ts(세션 스코프, 인메모리)와 달리 이 상태는 앱 재시작/페이지
 * 재로드 후에도 유지되어야 한다(하루 인터스티셜 노출 횟수 제한, 최초 사용일
 * 기록 등). 영속화는 브라우저 raw `window.localStorage`가 아니라
 * `@apps-in-toss/web-framework`의 `Storage`(getItem/setItem, 모두 Promise
 * 기반)를 쓴다 - router.tsx:113의 "이 앱은 별도 로컬 캐시를 쓰지 않는다"
 * 불변식 주석에 대한 의도적/문서화된 예외이며, Toss 네이티브 영속 경로다.
 *
 * PII를 저장하지 않는다: 날짜/카운트 필드만 둔다.
 */

import { toKstWall } from '../../domain/datetime';

/** 광고 관련 값만 담는다. 사용자 식별 정보(PII)는 절대 넣지 않는다. */
export interface AdFrequencyState {
  /** 이 사용자가 앱을 처음 사용한 날짜(최초 기록 시각). 기록 전이면 null. */
  firstUsedAt: Date | null;
  /** 가장 최근 인터스티셜 노출 시각. 노출 전이면 null. */
  lastInterstitialAt: Date | null;
  /** 가장 최근 인터스티셜이 노출된 KST 캘린더 일자 문자열('YYYY-MM-DD'). 일일 카운트 리셋 판단용. */
  lastInterstitialKstDay: string | null;
  /** lastInterstitialKstDay 기준 그 날 노출된 인터스티셜 횟수. */
  interstitialCountForDay: number;
}

/** 최초 사용(=아직 아무 기록도 없음) 상태와 동일한 안전 기본값. */
function safeDefaultState(): AdFrequencyState {
  return {
    firstUsedAt: null,
    lastInterstitialAt: null,
    lastInterstitialKstDay: null,
    interstitialCountForDay: 0,
  };
}

/**
 * `@apps-in-toss/web-framework`의 `Storage`와 형태만 맞춘 최소 포트.
 * 테스트에서 in-memory 구현으로 쉽게 대체할 수 있도록 인터페이스로 분리한다.
 */
export interface AdStatePort {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
}

const STORAGE_KEY = 'planflow_ad_frequency_v1';

interface PersistedAdFrequencyStateV1 {
  firstUsedAt: string | null;
  lastInterstitialAt: string | null;
  lastInterstitialKstDay: string | null;
  interstitialCountForDay: number;
}

/** ISO 문자열을 Date로 파싱한다. null/빈 값/Invalid Date는 모두 null로 취급한다. */
function parseIsoOrNull(value: unknown): Date | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== 'string' || value.length === 0) {
    return null;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return parsed;
}

/**
 * 저장된 JSON 페이로드가 기대하는 스키마(필드 존재 + 타입)를 만족하는지
 * 검증한다. 여기서 통과해도 각 필드의 "의미"(예: Invalid Date)는
 * parseIsoOrNull이 추가로 걸러낸다.
 */
function isPersistedShape(value: unknown): value is PersistedAdFrequencyStateV1 {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const record = value as Record<string, unknown>;
  const firstUsedAtOk =
    record.firstUsedAt === null || typeof record.firstUsedAt === 'string';
  const lastInterstitialAtOk =
    record.lastInterstitialAt === null || typeof record.lastInterstitialAt === 'string';
  const lastInterstitialKstDayOk =
    record.lastInterstitialKstDay === null ||
    typeof record.lastInterstitialKstDay === 'string';
  const countOk = typeof record.interstitialCountForDay === 'number';
  return (
    'firstUsedAt' in record &&
    'lastInterstitialAt' in record &&
    'lastInterstitialKstDay' in record &&
    'interstitialCountForDay' in record &&
    firstUsedAtOk &&
    lastInterstitialAtOk &&
    lastInterstitialKstDayOk &&
    countOk
  );
}

/**
 * 저장된 광고 빈도 상태를 읽는다. 저장 값이 없거나, 손상됐거나, 스키마가
 * 안 맞거나, 포트 자체가 예외를 던지는 어떤 경우든 "최초 사용" 안전
 * 기본값으로 폴백한다 - 절대 throw하지 않고, 절대 "광고를 더 많이 보여주는"
 * 방향으로 기본값을 잡지 않는다.
 */
export async function loadAdFrequencyState(port: AdStatePort): Promise<AdFrequencyState> {
  try {
    const raw = await port.getItem(STORAGE_KEY);
    if (raw === null) {
      return safeDefaultState();
    }

    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(raw);
    } catch {
      return safeDefaultState();
    }

    if (!isPersistedShape(parsedJson)) {
      return safeDefaultState();
    }

    return {
      firstUsedAt: parseIsoOrNull(parsedJson.firstUsedAt),
      lastInterstitialAt: parseIsoOrNull(parsedJson.lastInterstitialAt),
      lastInterstitialKstDay: parsedJson.lastInterstitialKstDay,
      interstitialCountForDay: parsedJson.interstitialCountForDay,
    };
  } catch {
    // port.getItem() 자체가 throw/reject하는 경우(SDK 미지원 환경 등)도
    // 안전 기본값으로 폴백한다.
    return safeDefaultState();
  }
}

async function persist(port: AdStatePort, state: AdFrequencyState): Promise<void> {
  const payload: PersistedAdFrequencyStateV1 = {
    firstUsedAt: state.firstUsedAt ? state.firstUsedAt.toISOString() : null,
    lastInterstitialAt: state.lastInterstitialAt ? state.lastInterstitialAt.toISOString() : null,
    lastInterstitialKstDay: state.lastInterstitialKstDay,
    interstitialCountForDay: state.interstitialCountForDay,
  };
  try {
    await port.setItem(STORAGE_KEY, JSON.stringify(payload));
  } catch {
    // 광고 상태 쓰기 실패가 앱 기능을 깨뜨려서는 안 된다 - 조용히 무시한다.
  }
}

/**
 * 아직 firstUsedAt이 기록되지 않았을 때만 `now`로 기록한다. 이미 값이
 * 있으면 절대 덮어쓰지 않는다(no-op).
 */
export async function recordFirstUseIfAbsent(
  port: AdStatePort,
  now: Date = new Date(),
): Promise<void> {
  const state = await loadAdFrequencyState(port);
  if (state.firstUsedAt !== null) {
    return;
  }
  await persist(port, { ...state, firstUsedAt: now });
}

/** now가 속한 KST 날짜를 'YYYY-MM-DD' 문자열로 만든다. datetime.ts의 toKstWall을 재사용한다. */
function kstDayString(now: Date): string {
  const wall = toKstWall(now);
  const year = wall.getUTCFullYear();
  const month = String(wall.getUTCMonth() + 1).padStart(2, '0');
  const day = String(wall.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/**
 * 인터스티셜 노출을 기록한다. lastInterstitialAt을 now로 갱신하고,
 * 같은 KST 날짜 내 노출이면 카운트를 증가, 날짜가 바뀌었으면 1로 리셋한다.
 */
export async function recordInterstitialShown(
  port: AdStatePort,
  now: Date = new Date(),
): Promise<void> {
  const state = await loadAdFrequencyState(port);
  const today = kstDayString(now);
  const nextCount = state.lastInterstitialKstDay === today ? state.interstitialCountForDay + 1 : 1;
  await persist(port, {
    ...state,
    lastInterstitialAt: now,
    lastInterstitialKstDay: today,
    interstitialCountForDay: nextCount,
  });
}
