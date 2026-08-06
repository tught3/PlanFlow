/**
 * devPreview.ts / previewRepository.ts 테스트.
 *
 * 게이트(resolveDevPreviewEnabled)와 세션 mock 여부(resolvePreviewSessionState)는
 * import.meta.env를 직접 읽지 않는 순수 함수라 env 스터빙 없이 결정적으로
 * 테스트한다(ConfirmDialog.resolveConfirmState와 동일한 패턴). 이 테스트가
 * "게이트 off일 때 mock 미반환 / on일 때 반환" 계약을 고정한다.
 */
import { describe, expect, it } from 'vitest';

import {
  DEV_PREVIEW_USER_ID,
  PLANFLOW_DEV_PREVIEW_MARKER,
  isDevPreviewEnabled,
  resolveDevPreviewEnabled,
  resolvePreviewSessionState,
} from './devPreview.ts';
import { createPreviewRepository } from './previewRepository.ts';

describe('resolveDevPreviewEnabled', () => {
  it('isDev=true + VITE_DEV_PREVIEW="1"이면 활성이다', () => {
    expect(resolveDevPreviewEnabled({ isDev: true, viteDevPreviewFlag: '1' })).toBe(true);
  });

  it('isDev=false면 VITE_DEV_PREVIEW="1"이어도 비활성이다(production 안전장치)', () => {
    expect(resolveDevPreviewEnabled({ isDev: false, viteDevPreviewFlag: '1' })).toBe(false);
  });

  it('isDev=true인데 VITE_DEV_PREVIEW가 설정되어 있지 않으면 비활성이다(기본값)', () => {
    expect(resolveDevPreviewEnabled({ isDev: true, viteDevPreviewFlag: undefined })).toBe(false);
  });

  it('VITE_DEV_PREVIEW가 "1"이 아닌 다른 값(예: "true")이면 비활성이다 - 정확히 "1"만 허용', () => {
    expect(resolveDevPreviewEnabled({ isDev: true, viteDevPreviewFlag: 'true' })).toBe(false);
    expect(resolveDevPreviewEnabled({ isDev: true, viteDevPreviewFlag: true })).toBe(false);
  });
});

describe('isDevPreviewEnabled (실제 import.meta.env 경유)', () => {
  it('boolean을 반환한다 - 이 저장소의 vitest 실행 환경에서 VITE_DEV_PREVIEW를 별도 설정하지 않았으므로 기본은 false다', () => {
    expect(typeof isDevPreviewEnabled()).toBe('boolean');
    expect(isDevPreviewEnabled()).toBe(false);
  });
});

describe('resolvePreviewSessionState', () => {
  it('게이트 off(false)면 mock 세션을 반환하지 않는다(null)', () => {
    expect(resolvePreviewSessionState(false)).toBeNull();
  });

  it('게이트 on(true)이면 즉시 완료된 mock 세션을 반환한다', () => {
    const state = resolvePreviewSessionState(true);
    expect(state).not.toBeNull();
    expect(state?.userId).toBe(DEV_PREVIEW_USER_ID);
    expect(state?.loading).toBe(false);
  });
});

describe('PLANFLOW_DEV_PREVIEW_MARKER', () => {
  it('고정 마커 문자열이다(scan-bundle.mjs가 production dist에서 이 값을 찾으면 빌드를 실패시킨다)', () => {
    expect(PLANFLOW_DEV_PREVIEW_MARKER).toBe('PLANFLOW_DEV_PREVIEW_ENABLED');
  });
});

describe('createPreviewRepository', () => {
  it('시드 데이터를 최소 5건 이상 포함한다', async () => {
    const repo = createPreviewRepository();
    const result = await repo.listEvents({
      start: new Date(0).toISOString(),
      end: new Date(Date.UTC(9999, 0, 1)).toISOString(),
    });
    expect(result.error).toBeNull();
    expect(result.data).not.toBeNull();
    expect((result.data ?? []).length).toBeGreaterThanOrEqual(5);
  });

  it('시드 데이터 안에 일반/중요/종일/반복/다일 케이스가 모두 존재한다', async () => {
    const repo = createPreviewRepository();
    const result = await repo.listEvents({
      start: new Date(0).toISOString(),
      end: new Date(Date.UTC(9999, 0, 1)).toISOString(),
    });
    const events = result.data ?? [];

    expect(events.some((event) => !event.isCritical && !event.isAllDay && !event.isMultiDay && event.recurrenceRule === null)).toBe(true);
    expect(events.some((event) => event.isCritical)).toBe(true);
    expect(events.some((event) => event.isAllDay)).toBe(true);
    expect(events.some((event) => event.recurrenceRule !== null)).toBe(true);
    expect(events.some((event) => event.isMultiDay)).toBe(true);
  });

  it('모든 시드 일정의 userId는 DEV_PREVIEW_USER_ID다', async () => {
    const repo = createPreviewRepository();
    const result = await repo.listEvents({
      start: new Date(0).toISOString(),
      end: new Date(Date.UTC(9999, 0, 1)).toISOString(),
    });
    for (const event of result.data ?? []) {
      expect(event.userId).toBe(DEV_PREVIEW_USER_ID);
    }
  });

  it('getEvent(id)로 시드 일정을 단건 조회할 수 있다', async () => {
    const repo = createPreviewRepository();
    const list = await repo.listEvents({
      start: new Date(0).toISOString(),
      end: new Date(Date.UTC(9999, 0, 1)).toISOString(),
    });
    const first = (list.data ?? [])[0];
    expect(first).toBeDefined();

    const result = await repo.getEvent(first.id);
    expect(result.error).toBeNull();
    expect(result.data?.id).toBe(first.id);
  });

  it('존재하지 않는 id를 조회하면 data:null, error:null을 반환한다(eventRepository.getEvent와 동일한 계약)', async () => {
    const repo = createPreviewRepository();
    const result = await repo.getEvent('없는-id');
    expect(result.data).toBeNull();
    expect(result.error).toBeNull();
  });

  it('createEvent -> updateEvent -> deleteEvent 순서로 메모리 상태를 변형한다(외부 호출 없음)', async () => {
    const repo = createPreviewRepository();

    const created = await repo.createEvent({
      userId: DEV_PREVIEW_USER_ID,
      title: '새 미리보기 일정',
      startAt: new Date(),
      endAt: null,
      location: null,
      locationLat: null,
      locationLng: null,
      memo: null,
      supplies: [],
      participants: [],
      targets: [],
      isCritical: false,
      useStrongAlarm: false,
      recurrenceRule: null,
      recurrenceEndDate: null,
      recurrenceCount: null,
      isAllDay: false,
      isMultiDay: false,
      parentEventId: null,
      overriddenOccurrenceDate: null,
      category: '기타',
      source: 'manual',
    });
    expect(created.error).toBeNull();
    expect(created.data?.title).toBe('새 미리보기 일정');
    const id = created.data?.id;
    expect(id).toBeDefined();
    if (id === undefined) {
      return;
    }

    const updated = await repo.updateEvent(id, { title: '수정된 제목' });
    expect(updated.data?.title).toBe('수정된 제목');

    const deleted = await repo.deleteEvent(id);
    expect(deleted.error).toBeNull();

    const afterDelete = await repo.getEvent(id);
    expect(afterDelete.data).toBeNull();
  });

  it('두 인스턴스는 서로 독립된 시드 상태를 가진다(팩토리 함수) - repoA를 비워도 repoB는 영향받지 않는다', async () => {
    // nextSeedId()는 전역 카운터를 쓰므로 두 인스턴스의 시드 id는 서로 다르다
    // (인스턴스 간 id가 우연히 겹치는 걸 기대해선 안 된다) - 그래서 id로
    // 직접 대조하지 않고, repoA의 이벤트를 전부 지워도 repoB의 개수가
    // 줄지 않는다는 것으로 격리를 검증한다.
    const range = { start: new Date(0).toISOString(), end: new Date(Date.UTC(9999, 0, 1)).toISOString() };
    const repoA = createPreviewRepository();
    const repoB = createPreviewRepository();

    const listB = await repoB.listEvents(range);
    const countB = (listB.data ?? []).length;
    expect(countB).toBeGreaterThanOrEqual(5);

    const listA = await repoA.listEvents(range);
    for (const event of listA.data ?? []) {
      await repoA.deleteEvent(event.id);
    }
    const afterDeleteA = await repoA.listEvents(range);
    expect((afterDeleteA.data ?? []).length).toBe(0);

    const listBAfter = await repoB.listEvents(range);
    expect((listBAfter.data ?? []).length).toBe(countB);
  });
});
