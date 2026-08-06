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
import { useId, useState } from 'react';
import type { FormEvent } from 'react';

import { Spinner } from '../../components/index.ts';
import { eventRepository } from '../../data/eventRepository.ts';
import type { EventRepository, NewEventInput } from '../../data/eventRepository.ts';
import type { Event } from '../../domain/event.ts';

export type EventFormMode = 'create' | 'update';

export interface EventFormValues {
  title: string;
  /**
   * <input type="datetime-local"> 형식 문자열('YYYY-MM-DDTHH:mm') 또는(isAllDay일 때)
   * <input type="date"> 형식 문자열('YYYY-MM-DD').
   */
  startAt: string;
  /** 비어 있으면 종료 시각 없음(null)으로 취급한다. startAt과 동일한 형식 규칙을 따른다. */
  endAt: string;
  memo: string;
  isCritical: boolean;
  /** 종일 일정 여부. true면 startAt/endAt을 날짜 전용 입력으로 다룬다. */
  isAllDay: boolean;
  location: string;
}

export interface EventFormFieldErrors {
  title?: string;
  startAt?: string;
}

const DEFAULT_CATEGORY = '기타';
const DEFAULT_SOURCE = 'manual';
const OPTIMISTIC_ID_PREFIX = 'optimistic-';

export function createEmptyEventFormValues(): EventFormValues {
  return { title: '', startAt: '', endAt: '', memo: '', isCritical: false, isAllDay: false, location: '' };
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

/** Date -> <input type="date"> 값 문자열 (로컬 시각 기준, 'YYYY-MM-DD'). 종일 일정용. */
export function formatDateOnlyForInput(date: Date): string {
  const year = date.getFullYear();
  const month = pad2(date.getMonth() + 1);
  const day = pad2(date.getDate());
  return `${year}-${month}-${day}`;
}

/** isAllDay 여부에 맞춰 Date를 폼 입력 문자열로 변환한다. */
function formatDateForFormField(date: Date, isAllDay: boolean): string {
  return isAllDay ? formatDateOnlyForInput(date) : formatDateForInput(date);
}

/** 수정 모드일 때 기존 Event로부터 폼 초기값을 만든다. */
export function toInitialEventFormValues(mode: EventFormMode, initialEvent?: Event): EventFormValues {
  if (mode === 'update' && initialEvent !== undefined) {
    const isAllDay = initialEvent.isAllDay;
    return {
      title: initialEvent.title,
      startAt: formatDateForFormField(initialEvent.startAt, isAllDay),
      endAt: initialEvent.endAt !== null ? formatDateForFormField(initialEvent.endAt, isAllDay) : '',
      memo: initialEvent.memo ?? '',
      isCritical: initialEvent.isCritical,
      isAllDay,
      location: initialEvent.location ?? '',
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
  const location = values.location.trim().length > 0 ? values.location.trim() : null;

  return {
    userId,
    title: values.title.trim(),
    startAt: new Date(values.startAt),
    endAt,
    location,
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
    isAllDay: values.isAllDay,
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
    isAllDay: values.isAllDay,
    location: values.location.trim().length > 0 ? values.location.trim() : null,
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

  const titleId = useId();
  const titleErrorId = useId();
  const startAtId = useId();
  const startAtErrorId = useId();
  const endAtId = useId();
  const memoId = useId();
  const locationId = useId();
  const isAllDayId = useId();
  const isCriticalId = useId();

  if (mode === 'update' && initialEvent === undefined) {
    return <p role="alert">수정할 일정 정보가 없습니다.</p>;
  }

  function handleFieldChange<K extends keyof EventFormValues>(field: K, value: EventFormValues[K]) {
    setValues((prev) => ({ ...prev, [field]: value }));
  }

  /**
   * 종일 체크박스 토글 시 startAt/endAt 값의 형식(datetime-local <-> date)을
   * 함께 변환한다 - 단순히 isAllDay 플래그만 바꾸면 <input type="date">가
   * 기존 datetime-local 문자열('YYYY-MM-DDTHH:mm')을 못 읽어 값이 사라진다.
   */
  function handleAllDayToggle(nextIsAllDay: boolean) {
    setValues((prev) => {
      const startAt = prev.startAt.trim().length > 0 ? new Date(prev.startAt) : null;
      const endAt = prev.endAt.trim().length > 0 ? new Date(prev.endAt) : null;
      return {
        ...prev,
        isAllDay: nextIsAllDay,
        startAt:
          startAt !== null && !Number.isNaN(startAt.getTime())
            ? formatDateForFormField(startAt, nextIsAllDay)
            : prev.startAt,
        endAt:
          endAt !== null && !Number.isNaN(endAt.getTime())
            ? formatDateForFormField(endAt, nextIsAllDay)
            : prev.endAt,
      };
    });
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

  const startAtInputType = values.isAllDay ? 'date' : 'datetime-local';
  const endAtInputType = values.isAllDay ? 'date' : 'datetime-local';

  return (
    <form className="event-form" onSubmit={(event) => void handleSubmit(event)}>
      <div className="pf-field">
        <label className="pf-field__label" htmlFor={titleId}>
          제목
        </label>
        <input
          id={titleId}
          className="pf-field__input"
          type="text"
          value={values.title}
          onChange={(event) => handleFieldChange('title', event.target.value)}
          aria-describedby={errors.title !== undefined ? titleErrorId : undefined}
          aria-invalid={errors.title !== undefined}
        />
        {errors.title !== undefined ? (
          <p id={titleErrorId} className="pf-field__error" role="alert">
            {errors.title}
          </p>
        ) : null}
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={isAllDayId}>
          <input
            id={isAllDayId}
            type="checkbox"
            checked={values.isAllDay}
            onChange={(event) => handleAllDayToggle(event.target.checked)}
          />
          종일
        </label>
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={startAtId}>
          시작 {values.isAllDay ? '날짜' : '시각'}
        </label>
        <input
          id={startAtId}
          className="pf-field__input"
          type={startAtInputType}
          value={values.startAt}
          onChange={(event) => handleFieldChange('startAt', event.target.value)}
          aria-describedby={errors.startAt !== undefined ? startAtErrorId : undefined}
          aria-invalid={errors.startAt !== undefined}
        />
        {errors.startAt !== undefined ? (
          <p id={startAtErrorId} className="pf-field__error" role="alert">
            {errors.startAt}
          </p>
        ) : null}
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={endAtId}>
          종료 {values.isAllDay ? '날짜' : '시각'}
        </label>
        <input
          id={endAtId}
          className="pf-field__input"
          type={endAtInputType}
          value={values.endAt}
          onChange={(event) => handleFieldChange('endAt', event.target.value)}
        />
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={locationId}>
          위치
        </label>
        <input
          id={locationId}
          className="pf-field__input"
          type="text"
          value={values.location}
          onChange={(event) => handleFieldChange('location', event.target.value)}
        />
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={memoId}>
          메모
        </label>
        <textarea
          id={memoId}
          className="pf-field__input"
          value={values.memo}
          onChange={(event) => handleFieldChange('memo', event.target.value)}
        />
      </div>

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={isCriticalId}>
          <input
            id={isCriticalId}
            type="checkbox"
            checked={values.isCritical}
            onChange={(event) => handleFieldChange('isCritical', event.target.checked)}
          />
          중요 일정
        </label>
      </div>

      {submitError !== null ? <p role="alert">{submitError}</p> : null}
      {submitting ? <Spinner label="저장 중..." /> : null}

      <div className="event-form__actions">
        <button type="submit" className="pf-button pf-button--primary" disabled={submitting}>
          {mode === 'create' ? '일정 만들기' : '일정 수정'}
        </button>
        {onCancel !== undefined ? (
          <button type="button" className="pf-button pf-button--ghost" onClick={onCancel} disabled={submitting}>
            취소
          </button>
        ) : null}
      </div>
    </form>
  );
}
