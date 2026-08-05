/**
 * EventForm 저장 로직 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library/react가 설치되어 있지 않아 컴포넌트를
 * 렌더링할 수 없다(다른 테스트 파일(domain/data)도 전부 순수 함수 단위 테스트만
 * 한다). 대신 EventForm.tsx가 컴포넌트와 함께 export하는 순수/비동기 헬퍼
 * (validateEventFormValues, buildNewEventInput, buildEventPatch, submitEventForm)를
 * eventRepository를 모킹해 직접 테스트한다 - 실제 컴포넌트도 이 헬퍼를 그대로
 * 호출하므로 동작 검증에는 충분하다.
 */
import { describe, expect, it, vi } from 'vitest';

import {
  buildEventPatch,
  buildNewEventInput,
  submitEventForm,
  validateEventFormValues,
} from './EventForm.tsx';
import type { EventFormValues } from './EventForm.tsx';
import type { EventRepository } from '../../data/eventRepository.ts';
import type { Event } from '../../domain/event.ts';

function makeValues(overrides: Partial<EventFormValues> = {}): EventFormValues {
  return {
    title: '팀 회의',
    startAt: '2026-08-10T09:00',
    endAt: '2026-08-10T10:00',
    memo: '분기 계획 논의',
    isCritical: false,
    ...overrides,
  };
}

function makeEvent(overrides: Partial<Event> = {}): Event {
  return {
    id: 'evt-1',
    userId: 'user-1',
    title: '기존 회의',
    startAt: new Date('2026-08-05T01:00:00.000Z'),
    endAt: new Date('2026-08-05T02:00:00.000Z'),
    location: null,
    locationLat: null,
    locationLng: null,
    memo: '기존 메모',
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
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  };
}

function makeMockRepository(overrides: Partial<EventRepository> = {}): EventRepository {
  return {
    listEvents: vi.fn(async () => ({ data: [], error: null })),
    getEvent: vi.fn(async () => ({ data: null, error: null })),
    createEvent: vi.fn(async () => ({ data: null, error: null })),
    updateEvent: vi.fn(async () => ({ data: null, error: null })),
    deleteEvent: vi.fn(async () => ({ data: null, error: null })),
    ...overrides,
  };
}

describe('validateEventFormValues', () => {
  it('title이 비어있으면 에러를 반환한다', () => {
    const errors = validateEventFormValues(makeValues({ title: '   ' }));
    expect(errors.title).toBeDefined();
  });

  it('startAt이 비어있으면 에러를 반환한다', () => {
    const errors = validateEventFormValues(makeValues({ startAt: '' }));
    expect(errors.startAt).toBeDefined();
  });

  it('startAt이 파싱 불가능한 문자열이면 에러를 반환한다', () => {
    const errors = validateEventFormValues(makeValues({ startAt: 'not-a-date' }));
    expect(errors.startAt).toBeDefined();
  });

  it('필수 필드가 모두 채워지면 에러가 없다', () => {
    const errors = validateEventFormValues(makeValues());
    expect(errors).toEqual({});
  });
});

describe('buildNewEventInput', () => {
  it('폼 값을 NewEventInput으로 변환한다', () => {
    const input = buildNewEventInput(makeValues(), 'user-1');
    expect(input.userId).toBe('user-1');
    expect(input.title).toBe('팀 회의');
    expect(input.startAt).toEqual(new Date('2026-08-10T09:00'));
    expect(input.endAt).toEqual(new Date('2026-08-10T10:00'));
    expect(input.memo).toBe('분기 계획 논의');
    expect(input.isCritical).toBe(false);
    expect(input.category).toBe('기타');
    expect(input.source).toBe('manual');
  });

  it('endAt/memo가 빈 문자열이면 null로 변환한다', () => {
    const input = buildNewEventInput(makeValues({ endAt: '', memo: '   ' }), 'user-1');
    expect(input.endAt).toBeNull();
    expect(input.memo).toBeNull();
  });
});

describe('buildEventPatch', () => {
  it('폼 값을 Partial<Event> patch로 변환한다', () => {
    const patch = buildEventPatch(makeValues({ isCritical: true }));
    expect(patch.title).toBe('팀 회의');
    expect(patch.startAt).toEqual(new Date('2026-08-10T09:00'));
    expect(patch.endAt).toEqual(new Date('2026-08-10T10:00'));
    expect(patch.isCritical).toBe(true);
  });
});

describe('submitEventForm', () => {
  it('필수 필드 검증 실패 시 저장소를 호출하지 않고 에러를 반환한다', async () => {
    const repository = makeMockRepository();

    const result = await submitEventForm({
      repository,
      mode: 'create',
      userId: 'user-1',
      values: makeValues({ title: '' }),
    });

    expect(result.error).not.toBeNull();
    expect(result.event).toBeNull();
    expect(repository.createEvent).not.toHaveBeenCalled();
  });

  it('생성 성공 시 낙관적 업데이트를 먼저 통지하고 저장된 Event를 반환한다', async () => {
    const savedEvent = makeEvent({ id: 'evt-new' });
    const repository = makeMockRepository({
      createEvent: vi.fn(async () => ({ data: savedEvent, error: null })),
    });
    const onOptimisticSave = vi.fn();
    const onRollback = vi.fn();

    const result = await submitEventForm({
      repository,
      mode: 'create',
      userId: 'user-1',
      values: makeValues(),
      onOptimisticSave,
      onRollback,
    });

    expect(onOptimisticSave).toHaveBeenCalledTimes(1);
    const optimisticEvent = onOptimisticSave.mock.calls[0]?.[0] as Event;
    expect(optimisticEvent.title).toBe('팀 회의');
    expect(optimisticEvent.id.startsWith('optimistic-')).toBe(true);

    expect(repository.createEvent).toHaveBeenCalledTimes(1);
    expect(result.event).toEqual(savedEvent);
    expect(result.error).toBeNull();
    expect(onRollback).not.toHaveBeenCalled();
  });

  it('생성 실패 시 onRollback(null)을 호출하고 에러를 반환한다', async () => {
    const repository = makeMockRepository({
      createEvent: vi.fn(async () => ({ data: null, error: { message: '네트워크 오류' } })),
    });
    const onOptimisticSave = vi.fn();
    const onRollback = vi.fn();

    const result = await submitEventForm({
      repository,
      mode: 'create',
      userId: 'user-1',
      values: makeValues(),
      onOptimisticSave,
      onRollback,
    });

    expect(onOptimisticSave).toHaveBeenCalledTimes(1);
    expect(onRollback).toHaveBeenCalledTimes(1);
    expect(onRollback).toHaveBeenCalledWith(null);
    expect(result.event).toBeNull();
    expect(result.error).toBe('네트워크 오류');
  });

  it('수정 성공 시 updateEvent를 patch와 함께 호출하고 저장된 Event를 반환한다', async () => {
    const initialEvent = makeEvent();
    const updatedEvent = makeEvent({ title: '변경된 회의' });
    const updateEventMock = vi.fn(async () => ({ data: updatedEvent, error: null }));
    const repository = makeMockRepository({ updateEvent: updateEventMock });
    const onRollback = vi.fn();

    const result = await submitEventForm({
      repository,
      mode: 'update',
      userId: initialEvent.userId,
      values: makeValues({ title: '변경된 회의' }),
      initialEvent,
      onRollback,
    });

    expect(updateEventMock).toHaveBeenCalledTimes(1);
    const [calledId, calledPatch] = updateEventMock.mock.calls[0] as unknown as [string, Partial<Event>];
    expect(calledId).toBe(initialEvent.id);
    expect(calledPatch.title).toBe('변경된 회의');

    expect(result.event).toEqual(updatedEvent);
    expect(result.error).toBeNull();
    expect(onRollback).not.toHaveBeenCalled();
  });

  it('수정 실패 시 onRollback(initialEvent)로 원래 값을 되돌리라고 통지한다', async () => {
    const initialEvent = makeEvent();
    const repository = makeMockRepository({
      updateEvent: vi.fn(async () => ({ data: null, error: { message: '충돌 발생' } })),
    });
    const onRollback = vi.fn();

    const result = await submitEventForm({
      repository,
      mode: 'update',
      userId: initialEvent.userId,
      values: makeValues({ title: '변경 시도' }),
      initialEvent,
      onRollback,
    });

    expect(onRollback).toHaveBeenCalledTimes(1);
    expect(onRollback).toHaveBeenCalledWith(initialEvent);
    expect(result.event).toBeNull();
    expect(result.error).toBe('충돌 발생');
  });

  it('수정 모드인데 initialEvent가 없으면 저장소를 호출하지 않고 에러를 반환한다', async () => {
    const repository = makeMockRepository();

    const result = await submitEventForm({
      repository,
      mode: 'update',
      userId: 'user-1',
      values: makeValues(),
    });

    expect(result.error).not.toBeNull();
    expect(repository.updateEvent).not.toHaveBeenCalled();
  });
});
