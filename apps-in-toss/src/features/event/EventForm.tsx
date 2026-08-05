/**
 * 일정 생성/수정 폼 (1차 MVP: 텍스트 입력, 음성 입력 없음).
 *
 * 원본(Flutter) 대응 화면:
 * - lib/features/events/screens/event_edit_screen.dart (필드 구성 참고)
 *
 * UI 컴포넌트는 상태(값/에러/제출중) 관리와 렌더링만 담당하고, 실제 저장 로직은
 * 이 파일이 함께 export하는 순수/비동기 헬퍼(validateEventFormValues,
 * buildNewEventInput, buildEventPatch, buildOptimisticEvent, submitEventForm)로
 * 분리했다. 이렇게 하면 저장소(리포지토리)만 모킹해서 저장 성공/실패/롤백 로직을
 * 컴포넌트 렌더링 없이 단위 테스트할 수 있다.
 *
 * 낙관적 업데이트/롤백은 이 컴포넌트가 직접 상위 리스트 상태를 관리하지 않으므로
 * onOptimisticSave/onRollback 콜백으로 상위(목록 화면)에 위임한다.
 */
import { useState } from 'react';
import type { FormEvent } from 'react';

import { eventRepository } from '../../data/eventRepository.ts';
import type { EventRepository, NewEventInput } from '../../data/eventRepository.ts';
import type { Event } from '../../domain/event.ts';

export type EventFormMode = 'create' | 'update';

export interface EventFormValues {
  title: string;
  /** <input type="datetime-local"> 형식 문자열 ('YYYY-MM-DDTHH:mm'). */
  startAt: string;
  /** 비어 있으면 종료 시각 없음(null)으로 취급한다. */
  endAt: string;
  memo: string;
  isCritical: boolean;
}

export interface EventFormFieldErrors {
  title?: string;
  startAt?: string;
}

const DEFAULT_CATEGORY = '기타';
const DEFAULT_SOURCE = 'manual';
const OPTIMISTIC_ID_PREFIX = 'optimistic-';

export function createEmptyEventFormValues(): EventFormValues {
  return { title: '', startAt: '', endAt: '', memo: '', isCritical: false };
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

/** Date -> <input type="datetime-local"> 값 문자열 (로컬 시각 기준). */
export function formatDateForInput(date: Date): string {
  const year = date.getFullYear();
  const month = pad2(date.getMonth() + 1);
  const day = pad2(date.getDate());
  const hour = pad2(date.getHours());
  const minute = pad2(date.getMinutes());
  return `${year}-${month}-${day}T${hour}:${minute}`;
}

/** 수정 모드일 때 기존 Event로부터 폼 초기값을 만든다. */
export function toInitialEventFormValues(mode: EventFormMode, initialEvent?: Event): EventFormValues {
  if (mode === 'update' && initialEvent !== undefined) {
    return {
      title: initialEvent.title,
      startAt: formatDateForInput(initialEvent.startAt),
      endAt: initialEvent.endAt !== null ? formatDateForInput(initialEvent.endAt) : '',
      memo: initialEvent.memo ?? '',
      isCritical: initialEvent.isCritical,
    };
  }
  return createEmptyEventFormValues();
}

/** 필수 필드(title, startAt) 검증. 문제 없으면 빈 객체를 반환한다. */
export function validateEventFormValues(values: EventFormValues): EventFormFieldErrors {
  const errors: EventFormFieldErrors = {};

  if (values.title.trim().length === 0) {
    errors.title = '제목을 입력하세요.';
  }

  if (values.startAt.trim().length === 0) {
    errors.startAt = '시작 시각을 입력하세요.';
  } else if (Number.isNaN(new Date(values.startAt).getTime())) {
    errors.startAt = '시작 시각 형식이 올바르지 않습니다.';
  }

  return errors;
}

export function hasFieldErrors(errors: EventFormFieldErrors): boolean {
  return Object.keys(errors).length > 0;
}

/** 폼 값 -> 신규 일정 입력(createEvent용). 1차 MVP 범위 밖 필드는 기본값으로 채운다. */
export function buildNewEventInput(values: EventFormValues, userId: string): NewEventInput {
  const endAt = values.endAt.trim().length > 0 ? new Date(values.endAt) : null;
  const memo = values.memo.trim().length > 0 ? values.memo.trim() : null;

  return {
    userId,
    title: values.title.trim(),
    startAt: new Date(values.startAt),
    endAt,
    location: null,
    locationLat: null,
    locationLng: null,
    memo,
    supplies: [],
    participants: [],
    targets: [],
    isCritical: values.isCritical,
    useStrongAlarm: false,
    recurrenceRule: null,
    recurrenceEndDate: null,
    recurrenceCount: null,
    isAllDay: false,
    isMultiDay: false,
    parentEventId: null,
    overriddenOccurrenceDate: null,
    category: DEFAULT_CATEGORY,
    source: DEFAULT_SOURCE,
  };
}

/** 폼 값 -> 기존 일정 부분 수정(updateEvent patch)용. 1차 MVP가 다루는 필드만 포함한다. */
export function buildEventPatch(values: EventFormValues): Partial<Event> {
  return {
    title: values.title.trim(),
    startAt: new Date(values.startAt),
    endAt: values.endAt.trim().length > 0 ? new Date(values.endAt) : null,
    memo: values.memo.trim().length > 0 ? values.memo.trim() : null,
    isCritical: values.isCritical,
  };
}

/**
 * 저장 요청 전에 UI에 즉시 반영할 낙관적 Event를 만든다.
 * update 모드는 기존 Event에 변경분만 덮어쓰고, create 모드는 임시 id를 부여한다.
 */
export function buildOptimisticEvent(
  mode: EventFormMode,
  values: EventFormValues,
  userId: string,
  initialEvent?: Event,
): Event {
  if (mode === 'update' && initialEvent !== undefined) {
    return { ...initialEvent, ...buildEventPatch(values) };
  }

  const input = buildNewEventInput(values, userId);
  return {
    ...input,
    id: `${OPTIMISTIC_ID_PREFIX}${Date.now()}`,
    createdAt: null,
    updatedAt: null,
  };
}

export interface SubmitEventFormParams {
  repository: EventRepository;
  mode: EventFormMode;
  userId: string;
  values: EventFormValues;
  /** update 모드에서는 필수. */
  initialEvent?: Event;
  /** 저장 요청을 보내기 직전(응답 대기 전)에 호출된다. */
  onOptimisticSave?: (event: Event) => void;
  /** 저장 실패 시 낙관적 업데이트를 되돌리라고 호출된다. update는 원래 Event, create는 null. */
  onRollback?: (previousEvent: Event | null) => void;
}

export interface SubmitEventFormResult {
  event: Event | null;
  error: string | null;
}

/**
 * 검증 -> 낙관적 업데이트 통지 -> 저장소 호출 -> 실패 시 롤백 통지까지 한 번에 처리한다.
 * 컴포넌트에서 분리해두어 리포지토리만 모킹하면 렌더링 없이 테스트할 수 있다.
 */
export async function submitEventForm(params: SubmitEventFormParams): Promise<SubmitEventFormResult> {
  const { repository, mode, userId, values, initialEvent, onOptimisticSave, onRollback } = params;

  const fieldErrors = validateEventFormValues(values);
  if (hasFieldErrors(fieldErrors)) {
    return { event: null, error: '입력값을 확인하세요.' };
  }

  if (mode === 'update' && initialEvent === undefined) {
    return { event: null, error: '수정할 일정 정보가 없습니다.' };
  }

  const optimisticEvent = buildOptimisticEvent(mode, values, userId, initialEvent);
  onOptimisticSave?.(optimisticEvent);

  if (mode === 'create') {
    const input = buildNewEventInput(values, userId);
    const { data, error } = await repository.createEvent(input);

    if (error !== null || data === null) {
      onRollback?.(null);
      return { event: null, error: error?.message ?? '일정 저장에 실패했습니다.' };
    }

    return { event: data, error: null };
  }

  // mode === 'update' (initialEvent는 위에서 undefined 체크를 이미 통과함)
  const patch = buildEventPatch(values);
  const { data, error } = await repository.updateEvent((initialEvent as Event).id, patch);

  if (error !== null || data === null) {
    onRollback?.(initialEvent as Event);
    return { event: null, error: error?.message ?? '일정 수정에 실패했습니다.' };
  }

  return { event: data, error: null };
}

export interface EventFormProps {
  mode: EventFormMode;
  userId: string;
  repository?: EventRepository;
  /** update 모드에서는 필수. */
  initialEvent?: Event;
  onSaved?: (event: Event) => void;
  onOptimisticSave?: (event: Event) => void;
  onRollback?: (previousEvent: Event | null) => void;
  onCancel?: () => void;
}

export function EventForm({
  mode,
  userId,
  repository = eventRepository,
  initialEvent,
  onSaved,
  onOptimisticSave,
  onRollback,
  onCancel,
}: EventFormProps) {
  const [values, setValues] = useState<EventFormValues>(() => toInitialEventFormValues(mode, initialEvent));
  const [errors, setErrors] = useState<EventFormFieldErrors>({});
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  if (mode === 'update' && initialEvent === undefined) {
    return <p role="alert">수정할 일정 정보가 없습니다.</p>;
  }

  function handleFieldChange<K extends keyof EventFormValues>(field: K, value: EventFormValues[K]) {
    setValues((prev) => ({ ...prev, [field]: value }));
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const fieldErrors = validateEventFormValues(values);
    setErrors(fieldErrors);
    if (hasFieldErrors(fieldErrors)) {
      return;
    }

    setSubmitting(true);
    setSubmitError(null);

    const result = await submitEventForm({
      repository,
      mode,
      userId,
      values,
      initialEvent,
      onOptimisticSave,
      onRollback,
    });

    setSubmitting(false);

    if (result.error !== null) {
      setSubmitError(result.error);
      return;
    }

    if (result.event !== null) {
      onSaved?.(result.event);
    }
  }

  return (
    <form onSubmit={(event) => void handleSubmit(event)}>
      <label>
        제목
        <input
          type="text"
          value={values.title}
          onChange={(event) => handleFieldChange('title', event.target.value)}
        />
      </label>
      {errors.title !== undefined ? <p role="alert">{errors.title}</p> : null}

      <label>
        시작 시각
        <input
          type="datetime-local"
          value={values.startAt}
          onChange={(event) => handleFieldChange('startAt', event.target.value)}
        />
      </label>
      {errors.startAt !== undefined ? <p role="alert">{errors.startAt}</p> : null}

      <label>
        종료 시각
        <input
          type="datetime-local"
          value={values.endAt}
          onChange={(event) => handleFieldChange('endAt', event.target.value)}
        />
      </label>

      <label>
        메모
        <textarea value={values.memo} onChange={(event) => handleFieldChange('memo', event.target.value)} />
      </label>

      <label>
        <input
          type="checkbox"
          checked={values.isCritical}
          onChange={(event) => handleFieldChange('isCritical', event.target.checked)}
        />
        중요 일정
      </label>

      {submitError !== null ? <p role="alert">{submitError}</p> : null}

      <button type="submit" disabled={submitting}>
        {mode === 'create' ? '일정 만들기' : '일정 수정'}
      </button>
      {onCancel !== undefined ? (
        <button type="button" onClick={onCancel}>
          취소
        </button>
      ) : null}
    </form>
  );
}
