/**
 * 확인/취소 모달 다이얼로그 공용 컴포넌트.
 *
 * 코딩 표준(모달 버튼 규칙)에 맞춰 액션 버튼을 가로 배치(pf-modal__actions)하고,
 * 취소 버튼을 포함한 모든 버튼에 테두리가 보이는 pf-button 계열 클래스를 쓴다
 * (실제 테두리 색/두께는 다른 그룹이 채우는 components.css 담당이고, 이 파일은
 * 클래스명 부여까지만 책임진다).
 *
 * 열기/닫기는 open prop으로 완전히 부모가 제어한다(uncontrolled 상태 없음).
 * 백드롭 클릭·ESC 키·취소 버튼은 전부 onCancel을, 확인 버튼은 onConfirm을
 * 호출한다 - 그 판정 로직을 resolveConfirmState라는 순수 함수로 분리해
 * jsdom 없이도(react-dom/server 조합 없이도) 단위 테스트할 수 있게 했다.
 */
import { useEffect, useId } from 'react';

export type ConfirmDialogTrigger = 'confirm-button' | 'cancel-button' | 'backdrop' | 'escape-key';

export type ConfirmDialogAction = 'confirm' | 'cancel' | 'none';

export interface ResolveConfirmStateInput {
  /** 다이얼로그가 현재 열려 있는지. 닫혀 있으면 어떤 trigger가 와도 무시한다. */
  open: boolean;
  /** 어떤 상호작용이 발생했는지. */
  trigger: ConfirmDialogTrigger;
}

/**
 * (open, trigger) -> 실행해야 할 액션으로 변환하는 순수 함수.
 *
 * open=false일 때 'none'을 반환하는 것은, 닫힌 다이얼로그에 남아있을 수 있는
 * 이벤트 리스너(예: 언마운트 경합 중인 keydown 핸들러)가 실수로 onConfirm/
 * onCancel을 다시 호출하지 않도록 방어하는 역할을 한다.
 */
export function resolveConfirmState({ open, trigger }: ResolveConfirmStateInput): ConfirmDialogAction {
  if (!open) return 'none';
  if (trigger === 'confirm-button') return 'confirm';
  // cancel-button / backdrop / escape-key는 전부 취소로 수렴한다.
  return 'cancel';
}

export interface ConfirmDialogProps {
  /** 다이얼로그 표시 여부. */
  open: boolean;
  /** 다이얼로그 제목. */
  title: string;
  /** 다이얼로그 본문(선택). */
  message?: string;
  /** 확인 버튼 라벨. 기본값 "확인". */
  confirmLabel?: string;
  /** 취소 버튼 라벨. 기본값 "취소". */
  cancelLabel?: string;
  /** true면 확인 버튼을 위험 동작 스타일(pf-button--danger)로 표시한다. */
  danger?: boolean;
  /** 확인 버튼 클릭 시 호출. */
  onConfirm: () => void;
  /** 취소 버튼/백드롭 클릭/ESC 키 입력 시 호출. */
  onCancel: () => void;
}

export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = '확인',
  cancelLabel = '취소',
  danger = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const titleId = useId();

  useEffect(() => {
    if (!open) return;

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== 'Escape') return;
      const action = resolveConfirmState({ open, trigger: 'escape-key' });
      if (action === 'cancel') onCancel();
    }

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [open, onCancel]);

  if (!open) return null;

  function handleBackdropClick() {
    const action = resolveConfirmState({ open, trigger: 'backdrop' });
    if (action === 'cancel') onCancel();
  }

  function handleCancelClick() {
    const action = resolveConfirmState({ open, trigger: 'cancel-button' });
    if (action === 'cancel') onCancel();
  }

  function handleConfirmClick() {
    const action = resolveConfirmState({ open, trigger: 'confirm-button' });
    if (action === 'confirm') onConfirm();
  }

  const confirmButtonClassName = danger
    ? 'pf-button pf-button--danger'
    : 'pf-button pf-button--primary';

  return (
    <div className="pf-modal">
      <div className="pf-modal__backdrop" onClick={handleBackdropClick} />
      <div className="pf-modal__panel" role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <h2 id={titleId} className="pf-modal__title">
          {title}
        </h2>
        {message !== undefined ? <p className="pf-modal__message">{message}</p> : null}
        <div className="pf-modal__actions">
          <button type="button" className="pf-button pf-button--ghost" onClick={handleCancelClick}>
            {cancelLabel}
          </button>
          <button type="button" className={confirmButtonClassName} onClick={handleConfirmClick}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
