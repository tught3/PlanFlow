/**
 * 공용 UI 컴포넌트 배럴 파일.
 *
 * 다른 화면(features/*)은 개별 파일 경로 대신 이 배럴을 통해 import한다:
 *   import { Spinner, EmptyState, ErrorMessage, ConfirmDialog } from '../../components/index.ts';
 */
export { Spinner } from './Spinner.tsx';
export type { SpinnerProps } from './Spinner.tsx';

export { EmptyState } from './EmptyState.tsx';
export type { EmptyStateProps } from './EmptyState.tsx';

export { ErrorMessage } from './ErrorMessage.tsx';
export type { ErrorMessageProps } from './ErrorMessage.tsx';

export { ConfirmDialog, resolveConfirmState } from './ConfirmDialog.tsx';
export type {
  ConfirmDialogAction,
  ConfirmDialogProps,
  ConfirmDialogTrigger,
  ResolveConfirmStateInput,
} from './ConfirmDialog.tsx';
