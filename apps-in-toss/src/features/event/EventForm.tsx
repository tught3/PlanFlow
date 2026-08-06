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
  /** 반복 프리셋. 'none'이면 반복 없음. */
  recurrencePreset: RecurrencePreset;
  /** <input type="date"> 형식 문자열('YYYY-MM-DD'). 비어 있으면 종료일 없음(무기한 반복). */
  recurrenceUntilDate: string;
  /**
   * false면 initialEvent.recurrenceRule이 5개 프리셋으로 표현할 수 없는 규칙(BYDAY/
   * INTERVAL/COUNT 포함)이라는 뜻이다 - 이 경우 select를 비활성화하고, 저장 시에도
   * recurrenceRule/recurrenceEndDate를 patch에서 아예 제외해 기존 값을 덮어쓰지 않는다.
   * create 모드(initialEvent 없음)에서는 항상 true.
   */
  recurrenceEditable: boolean;
}

/** 앱이 폼으로 편집할 수 있는 반복 프리셋. 'none'은 반복 없음을 뜻한다. */
export type RecurrencePreset = 'none' | 'daily' | 'weekly' | 'monthly' | 'yearly';

const PRESET_TO_FREQ: Record<Exclude<RecurrencePreset, 'none'>, string> = {
  daily: 'DAILY',
  weekly: 'WEEKLY',
  monthly: 'MONTHLY',
  yearly: 'YEARLY',
};

const FREQ_TO_PRESET: Record<string, RecurrencePreset> = {
  DAILY: 'daily',
  WEEKLY: 'weekly',
  MONTHLY: 'monthly',
  YEARLY: 'yearly',
};

/**
 * 반복 프리셋(+선택적 종료일) -> RRULE 문자열. 화이트리스트를 엄격히 지킨다:
 * FREQ=DAILY|WEEKLY|MONTHLY|YEARLY(+;UNTIL=YYYYMMDDTHHMMSSZ)만 생성하고,
 * COUNT=/BYDAY=/INTERVAL=는 절대 넣지 않는다(domain/recurrence.ts의
 * expandOccurrences가 COUNT를 파싱하지 못하므로 COUNT 기반 종료는 표현하지 않는다).
 */
export function buildRecurrenceRule(preset: RecurrencePreset, untilDate: string): string | null {
  if (preset === 'none') {
    return null;
  }

  const freq = PRESET_TO_FREQ[preset];
  const trimmedUntil = untilDate.trim();
  if (trimmedUntil.length === 0) {
    return `FREQ=${freq}`;
  }

  const digits = trimmedUntil.replace(/-/g, '');
  return `FREQ=${freq};UNTIL=${digits}T235959Z`;
}

export interface ParsedRecurrence {
  preset: RecurrencePreset;
  untilDate: string;
  /** false면 프리셋으로 표현할 수 없는 규칙(BYDAY/INTERVAL/COUNT 등)이라 편집을 막아야 한다. */
  editable: boolean;
}

const NO_RECURRENCE: ParsedRecurrence = { preset: 'none', untilDate: '', editable: true };
const UNEDITABLE_RECURRENCE: ParsedRecurrence = { preset: 'none', untilDate: '', editable: false };

/**
 * 기존 recurrenceRule(RRULE 문자열) -> 폼이 다루는 5개 프리셋 중 하나로 역파싱한다.
 * BYDAY/INTERVAL/COUNT가 포함돼 있거나 FREQ를 알 수 없으면 편집 불가(editable=false)로
 * 판정해, 컴포넌트가 select를 비활성화하고 규칙을 절대 덮어쓰지 않게 한다
 * (데이터 파괴 방지 - 표현 못하는 규칙을 프리셋으로 대충 저장하면 원래 규칙이 사라진다).
 */
export function parseRecurrencePreset(rule: string | null | undefined): ParsedRecurrence {
  if (rule === null || rule === undefined || rule.trim().length === 0) {
    return NO_RECURRENCE;
  }

  const upper = rule.toUpperCase();

  if (/BYDAY=/.test(upper) || /INTERVAL=/.test(upper) || /COUNT=/.test(upper)) {
    return UNEDITABLE_RECURRENCE;
  }

  const freqMatch = /FREQ=([A-Z]+)/.exec(upper);
  const freq = freqMatch?.[1];
  const preset = freq !== undefined ? FREQ_TO_PRESET[freq] : undefined;
  if (preset === undefined) {
    return UNEDITABLE_RECURRENCE;
  }

  const untilMatch = /UNTIL=(\d{8})/.exec(upper);
  const untilDate =
    untilMatch !== null
      ? `${untilMatch[1].slice(0, 4)}-${untilMatch[1].slice(4, 6)}-${untilMatch[1].slice(6, 8)}`
      : '';

  return { preset, untilDate, editable: true };
}

export interface EventFormFieldErrors {
  title?: string;
  startAt?: string;
}

const DEFAULT_CATEGORY = '기타';
const DEFAULT_SOURCE = 'manual';
const OPTIMISTIC_ID_PREFIX = 'optimistic-';

export function createEmptyEventFormValues(): EventFormValues {
  return {
    title: '',
    startAt: '',
    endAt: '',
    memo: '',
    isCritical: false,
    isAllDay: false,
    location: '',
    recurrencePreset: 'none',
    recurrenceUntilDate: '',
    recurrenceEditable: true,
  };
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
    const recurrence = parseRecurrencePreset(initialEvent.recurrenceRule);
    return {
      title: initialEvent.title,
      startAt: formatDateForFormField(initialEvent.startAt, isAllDay),
      endAt: initialEvent.endAt !== null ? formatDateForFormField(initialEvent.endAt, isAllDay) : '',
      memo: initialEvent.memo ?? '',
      isCritical: initialEvent.isCritical,
      isAllDay,
      location: initialEvent.location ?? '',
      recurrencePreset: recurrence.preset,
      recurrenceUntilDate: recurrence.untilDate,
      recurrenceEditable: recurrence.editable,
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
  const recurrenceRule = buildRecurrenceRule(values.recurrencePreset, values.recurrenceUntilDate);
  const recurrenceEndDate =
    recurrenceRule !== null && values.recurrenceUntilDate.trim().length > 0
      ? values.recurrenceUntilDate.trim()
      : null;

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
    recurrenceRule,
    recurrenceEndDate,
    recurrenceCount: null,
    isAllDay: values.isAllDay,
    isMultiDay: false,
    parentEventId: null,
    overriddenOccurrenceDate: null,
    category: DEFAULT_CATEGORY,
    source: DEFAULT_SOURCE,
  };
}

/**
 * 폼 값 -> 기존 일정 부분 수정(updateEvent patch)용. 1차 MVP가 다루는 필드만 포함한다.
 *
 * recurrenceEditable이 false면(기존 규칙이 프리셋으로 표현 불가) patch 객체에
 * recurrenceRule/recurrenceEndDate 키 자체를 넣지 않는다 - eventRepository는
 * Object.keys(patch)에 있는 키만 UPDATE 문에 반영하므로, 키를 아예 빼면 기존 DB
 * 값이 그대로 보존된다(값을 null이나 기존값으로 "다시 쓰는" 것과는 다르다).
 */
export function buildEventPatch(values: EventFormValues): Partial<Event> {
  const patch: Partial<Event> = {
    title: values.title.trim(),
    startAt: new Date(values.startAt),
    endAt: values.endAt.trim().length > 0 ? new Date(values.endAt) : null,
    memo: values.memo.trim().length > 0 ? values.memo.trim() : null,
    isCritical: values.isCritical,
    isAllDay: values.isAllDay,
    location: values.location.trim().length > 0 ? values.location.trim() : null,
  };

  if (values.recurrenceEditable) {
    const recurrenceRule = buildRecurrenceRule(values.recurrencePreset, values.recurrenceUntilDate);
    patch.recurrenceRule = recurrenceRule;
    patch.recurrenceEndDate =
      recurrenceRule !== null && values.recurrenceUntilDate.trim().length > 0
        ? values.recurrenceUntilDate.trim()
        : null;
  }

  return patch;
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
  const recurrencePresetId = useId();
  const recurrenceUntilId = useId();

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

      <div className="pf-field">
        <label className="pf-field__label" htmlFor={recurrencePresetId}>
          반복
        </label>
        <select
          id={recurrencePresetId}
          className="pf-field__input"
          value={values.recurrencePreset}
          disabled={!values.recurrenceEditable}
          onChange={(event) => handleFieldChange('recurrencePreset', event.target.value as RecurrencePreset)}
        >
          <option value="none">반복 안 함</option>
          <option value="daily">매일</option>
          <option value="weekly">매주</option>
          <option value="monthly">매월</option>
          <option value="yearly">매년</option>
        </select>
        {!values.recurrenceEditable ? (
          <p className="event-form__hint" role="status">
            이 반복 규칙은 앱에서 편집할 수 없습니다.
          </p>
        ) : null}
      </div>

      {values.recurrenceEditable && values.recurrencePreset !== 'none' ? (
        <div className="pf-field">
          <label className="pf-field__label" htmlFor={recurrenceUntilId}>
            반복 종료일 (선택)
          </label>
          <input
            id={recurrenceUntilId}
            className="pf-field__input"
            type="date"
            value={values.recurrenceUntilDate}
            onChange={(event) => handleFieldChange('recurrenceUntilDate', event.target.value)}
          />
        </div>
      ) : null}

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
