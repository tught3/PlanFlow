/**
 * 에러 메시지 공용 컴포넌트.
 *
 * role="alert"는 이 저장소 여러 화면(EventForm/EventDetail/router 등)이 이미
 * 쓰고 있는 패턴을 그대로 계승한다 - 스크린리더가 즉시 읽어주는 assertive
 * live region이라 폼 검증/저장 실패 안내에 적합하다.
 */
export interface ErrorMessageProps {
  /** 사용자에게 보여줄 에러 문구. */
  message: string;
}

export function ErrorMessage({ message }: ErrorMessageProps) {
  return (
    <p className="pf-error" role="alert">
      {message}
    </p>
  );
}
