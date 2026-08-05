/**
 * 일정 상세 표시 + 삭제.
 *
 * 원본(Flutter) 대응 화면:
 * - lib/features/events/screens/event_detail_screen.dart (구성 참고)
 *
 * 삭제 로직은 handleDeleteEvent()로 분리해 리포지토리만 모킹하면 렌더링 없이
 * 성공/실패 케이스를 테스트할 수 있게 했다(EventForm.tsx의 submitEventForm과 동일한 패턴).
 */
import { useState } from 'react';

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
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  async function handleDeleteClick() {
    setDeleting(true);
    setDeleteError(null);

    const result = await handleDeleteEvent(repository, event.id);

    setDeleting(false);

    if (!result.success) {
      const message = result.error ?? '일정 삭제에 실패했습니다.';
      setDeleteError(message);
      onDeleteError?.(message);
      return;
    }

    onDeleted?.(event.id);
  }

  return (
    <section>
      <h2>{event.title}</h2>
      <p>{formatEventDisplayDate(event.startAt)}</p>
      {event.endAt !== null ? <p>{formatEventDisplayDate(event.endAt)}</p> : null}
      {event.memo !== null ? <p>{event.memo}</p> : null}
      {event.isCritical ? <p role="status">중요 일정</p> : null}

      {deleteError !== null ? <p role="alert">{deleteError}</p> : null}

      {onEdit !== undefined ? (
        <button type="button" onClick={() => onEdit(event)}>
          수정
        </button>
      ) : null}
      <button type="button" onClick={() => void handleDeleteClick()} disabled={deleting}>
        삭제
      </button>
    </section>
  );
}
