/**
 * 일정 상세 표시 + 삭제.
 *
 * 원본(Flutter) 대응 화면:
 * - lib/features/events/screens/event_detail_screen.dart (구성 참고)
 *
 * 삭제 로직은 handleDeleteEvent()로 분리해 리포지토리만 모킹하면 렌더링 없이
 * 성공/실패 케이스를 테스트할 수 있게 했다(EventForm.tsx의 submitEventForm과 동일한 패턴).
 *
 * 삭제 버튼 클릭 -> ConfirmDialog 확인 -> 실제 삭제 흐름은 nextDeletePhase()(순수
 * 상태 전이 함수)와 confirmDeleteEvent()(확인 후에만 handleDeleteEvent를 호출하는
 * 가드 포함 비동기 헬퍼)로 분리해, jsdom 없이도 "확인 전에는 호출 안 됨 / 확인 후
 * 정확히 1회 호출 / 취소 시 0회 유지"를 단위 테스트할 수 있게 했다.
 */
import { useState } from 'react';

import { ConfirmDialog, ErrorMessage } from '../../components/index.ts';
import { eventRepository } from '../../data/eventRepository.ts';
import type { EventRepository } from '../../data/eventRepository.ts';
import type { Event } from '../../domain/event.ts';

export interface DeleteEventResult {
  success: boolean;
  error: string | null;
}

/** repository.deleteEvent를 호출하고 결과를 { success, error } 형태로 정규화한다. */
export async function handleDeleteEvent(repository: EventRepository, id: string): Promise<DeleteEventResult> {
  const { error } = await repository.deleteEvent(id);

  if (error !== null) {
    return { success: false, error: error.message };
  }

  return { success: true, error: null };
}

/** 삭제 버튼 클릭 -> 확인 다이얼로그 -> 삭제 진행/완료까지의 상태. */
export type EventDetailDeletePhase = 'idle' | 'confirming' | 'deleting';

export type DeletePhaseAction = 'click-delete' | 'cancel' | 'confirm' | 'success' | 'failure';

export interface NextDeletePhaseParams {
  phase: EventDetailDeletePhase;
  action: DeletePhaseAction;
}

/**
 * (phase, action) -> 다음 phase를 계산하는 순수 함수. 정의되지 않은 전이(예: idle
 * 상태에서 confirm, confirming이 아닌 상태에서 cancel)는 phase를 그대로 유지해
 * 중복 클릭/중복 이벤트가 상태를 건너뛰지 못하게 방어한다.
 */
export function nextDeletePhase({ phase, action }: NextDeletePhaseParams): EventDetailDeletePhase {
  switch (action) {
    case 'click-delete':
      return phase === 'idle' ? 'confirming' : phase;
    case 'cancel':
      return phase === 'confirming' ? 'idle' : phase;
    case 'confirm':
      return phase === 'confirming' ? 'deleting' : phase;
    case 'success':
      return 'idle';
    case 'failure':
      return phase === 'deleting' ? 'idle' : phase;
    default:
      return phase;
  }
}

export interface ConfirmDeleteEventParams {
  repository: EventRepository;
  id: string;
  /** 호출 시점의 현재 phase. 'confirming'이 아니면 repository를 호출하지 않는다. */
  phase: EventDetailDeletePhase;
  /**
   * phase가 'deleting'으로 전환되는 즉시(await 이전, 동기) 호출된다.
   * 컴포넌트는 이 콜백에서 다이얼로그를 닫고 삭제 버튼을 비활성화한다.
   */
  onDeletingStart?: () => void;
}

export interface ConfirmDeleteEventResult {
  phase: EventDetailDeletePhase;
  /** 가드에 막혀 repository를 호출하지 않았으면 null. */
  result: DeleteEventResult | null;
}

/**
 * ConfirmDialog의 onConfirm에서 호출되는 헬퍼. phase가 'confirming'일 때만
 * 실제로 handleDeleteEvent(repository.deleteEvent)를 호출한다 - "확인해야만
 * 삭제 호출" 계약을 이 가드 하나로 강제한다.
 */
export async function confirmDeleteEvent({
  repository,
  id,
  phase,
  onDeletingStart,
}: ConfirmDeleteEventParams): Promise<ConfirmDeleteEventResult> {
  const deletingPhase = nextDeletePhase({ phase, action: 'confirm' });
  if (deletingPhase !== 'deleting') {
    return { phase, result: null };
  }

  onDeletingStart?.();
  const result = await handleDeleteEvent(repository, id);
  const finalPhase = nextDeletePhase({
    phase: deletingPhase,
    action: result.success ? 'success' : 'failure',
  });
  return { phase: finalPhase, result };
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

/** 상세 화면 표시용 날짜 포맷 (로컬 시각 기준, 'YYYY-MM-DD HH:mm'). */
export function formatEventDisplayDate(date: Date): string {
  const year = date.getFullYear();
  const month = pad2(date.getMonth() + 1);
  const day = pad2(date.getDate());
  const hour = pad2(date.getHours());
  const minute = pad2(date.getMinutes());
  return `${year}-${month}-${day} ${hour}:${minute}`;
}

export interface EventDetailProps {
  event: Event;
  repository?: EventRepository;
  onDeleted?: (id: string) => void;
  onDeleteError?: (message: string) => void;
  onEdit?: (event: Event) => void;
}

export function EventDetail({
  event,
  repository = eventRepository,
  onDeleted,
  onDeleteError,
  onEdit,
}: EventDetailProps) {
  const [phase, setPhase] = useState<EventDetailDeletePhase>('idle');
  const [deleteError, setDeleteError] = useState<string | null>(null);

  function handleDeleteClick() {
    setPhase((prev) => nextDeletePhase({ phase: prev, action: 'click-delete' }));
  }

  function handleCancelDelete() {
    setPhase((prev) => nextDeletePhase({ phase: prev, action: 'cancel' }));
  }

  async function handleConfirmDelete() {
    setDeleteError(null);

    const { phase: finalPhase, result } = await confirmDeleteEvent({
      repository,
      id: event.id,
      phase,
      onDeletingStart: () => setPhase('deleting'),
    });

    setPhase(finalPhase);

    if (result === null) {
      return;
    }

    if (!result.success) {
      const message = result.error ?? '일정 삭제에 실패했습니다.';
      setDeleteError(message);
      onDeleteError?.(message);
      return;
    }

    onDeleted?.(event.id);
  }

  return (
    <section className="pf-card event-detail">
      <h2 className="event-detail__title">{event.title}</h2>
      <div className="event-detail__meta">
        <p>{formatEventDisplayDate(event.startAt)}</p>
        {event.endAt !== null ? <p>{formatEventDisplayDate(event.endAt)}</p> : null}
      </div>
      {event.memo !== null ? <p className="event-detail__memo">{event.memo}</p> : null}
      {event.location !== null ? <p className="event-detail__memo">{event.location}</p> : null}
      {event.isCritical ? (
        <p className="event-detail__badge event-detail__badge--critical" role="status">
          중요 일정
        </p>
      ) : null}

      {deleteError !== null ? <ErrorMessage message={deleteError} /> : null}

      <div className="event-detail__actions">
        {onEdit !== undefined ? (
          <button
            type="button"
            className="pf-button pf-button--ghost"
            onClick={() => onEdit(event)}
          >
            수정
          </button>
        ) : null}
        <button
          type="button"
          className="pf-button pf-button--danger"
          onClick={handleDeleteClick}
          disabled={phase !== 'idle'}
        >
          삭제
        </button>
      </div>

      <ConfirmDialog
        open={phase === 'confirming'}
        title="이 일정을 삭제할까요?"
        message="삭제한 일정은 되돌릴 수 없습니다."
        confirmLabel="삭제"
        cancelLabel="취소"
        danger
        onConfirm={() => void handleConfirmDelete()}
        onCancel={handleCancelDelete}
      />
    </section>
  );
}
