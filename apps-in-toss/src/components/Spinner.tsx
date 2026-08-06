/**
 * 로딩 스피너 공용 컴포넌트.
 *
 * role="status"로 스크린리더에 로딩 상태를 알리고, label을 화면에도 함께
 * 노출한다(아이콘만 있고 텍스트가 없는 스피너는 시각장애인뿐 아니라 저사양
 * 회선에서 아이콘 렌더링이 늦는 사용자에게도 불친절하다).
 */
export interface SpinnerProps {
  /** 화면과 스크린리더에 함께 노출할 안내 문구. */
  label?: string;
}

export function Spinner({ label = '불러오는 중...' }: SpinnerProps = {}) {
  return (
    <div className="pf-spinner" role="status">
      <span className="pf-spinner__label">{label}</span>
    </div>
  );
}
