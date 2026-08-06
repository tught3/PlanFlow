/**
 * 목록/데이터가 없을 때 보여주는 빈 상태 공용 컴포넌트.
 *
 * actionLabel/onAction을 함께 주면 안내 문구 아래에 액션 버튼(예: "새 일정
 * 추가")을 노출한다. 하나만 주어지면(짝이 없으면) 버튼을 렌더링하지 않는다.
 */
export interface EmptyStateProps {
  /** 빈 상태 안내 문구. */
  message: string;
  /** 액션 버튼 라벨. onAction과 함께 줘야 버튼이 보인다. */
  actionLabel?: string;
  /** 액션 버튼 클릭 핸들러. actionLabel과 함께 줘야 버튼이 보인다. */
  onAction?: () => void;
}

export function EmptyState({ message, actionLabel, onAction }: EmptyStateProps) {
  const showAction = actionLabel !== undefined && onAction !== undefined;

  return (
    <div className="pf-empty">
      <p className="pf-empty__message">{message}</p>
      {showAction ? (
        <button type="button" className="pf-button pf-button--primary" onClick={onAction}>
          {actionLabel}
        </button>
      ) : null}
    </div>
  );
}
