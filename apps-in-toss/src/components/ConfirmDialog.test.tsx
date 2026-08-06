/**
 * ConfirmDialog 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library/react가 설치되어 있지 않아 이벤트를
 * 직접 dispatch하며 렌더링할 수 없다(EventForm.test.tsx/TodayView.test.tsx와
 * 동일한 제약). 그래서 두 갈래로 나눠 검증한다:
 *
 * 1) resolveConfirmState(순수 함수) - open/trigger 조합별 확인/취소/무시 판정을
 *    React 렌더링 없이 직접 검증한다.
 * 2) ConfirmDialog(컴포넌트) - hook은 useEffect(keydown 리스너 등록)뿐이고
 *    렌더 결과 자체는 open prop에만 의존하므로, react-dom/server의
 *    renderToStaticMarkup으로 open=false/true 각각의 마크업을 문자열로 검증한다.
 */
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';

import { ConfirmDialog, resolveConfirmState } from './ConfirmDialog.tsx';

describe('resolveConfirmState', () => {
  it('open=false면 어떤 trigger가 와도 none을 반환한다', () => {
    expect(resolveConfirmState({ open: false, trigger: 'confirm-button' })).toBe('none');
    expect(resolveConfirmState({ open: false, trigger: 'cancel-button' })).toBe('none');
    expect(resolveConfirmState({ open: false, trigger: 'backdrop' })).toBe('none');
    expect(resolveConfirmState({ open: false, trigger: 'escape-key' })).toBe('none');
  });

  it('open=true + confirm-button이면 confirm을 반환한다', () => {
    expect(resolveConfirmState({ open: true, trigger: 'confirm-button' })).toBe('confirm');
  });

  it('open=true + cancel-button/backdrop/escape-key는 모두 cancel을 반환한다', () => {
    expect(resolveConfirmState({ open: true, trigger: 'cancel-button' })).toBe('cancel');
    expect(resolveConfirmState({ open: true, trigger: 'backdrop' })).toBe('cancel');
    expect(resolveConfirmState({ open: true, trigger: 'escape-key' })).toBe('cancel');
  });
});

describe('ConfirmDialog 렌더링', () => {
  it('open=false면 dialog DOM 자체가 존재하지 않는다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog
        open={false}
        title="일정을 삭제할까요?"
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    expect(html).toBe('');
    expect(html).not.toContain('role="dialog"');
    expect(html).not.toContain('pf-modal');
  });

  it('open=true면 role="dialog"와 aria-modal="true"를 가진 패널이 렌더링된다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog
        open={true}
        title="일정을 삭제할까요?"
        message="삭제하면 되돌릴 수 없습니다."
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    expect(html).toContain('role="dialog"');
    expect(html).toContain('aria-modal="true"');
    expect(html).toContain('pf-modal');
    expect(html).toContain('pf-modal__backdrop');
    expect(html).toContain('pf-modal__panel');
    expect(html).toContain('pf-modal__title');
    expect(html).toContain('pf-modal__actions');
    expect(html).toContain('일정을 삭제할까요?');
    expect(html).toContain('삭제하면 되돌릴 수 없습니다.');
  });

  it('취소 버튼이 존재하고 pf-button 계열 클래스를 가진다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog
        open={true}
        title="확인"
        cancelLabel="취소할래요"
        onConfirm={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    expect(html).toContain('취소할래요');
    expect(html).toContain('pf-button pf-button--ghost');
  });

  it('confirmLabel/cancelLabel 기본값은 확인/취소다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog open={true} title="확인" onConfirm={vi.fn()} onCancel={vi.fn()} />,
    );

    expect(html).toContain('>확인<');
    expect(html).toContain('>취소<');
  });

  it('danger=true면 확인 버튼이 pf-button--danger 클래스를 가진다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog open={true} title="삭제" danger={true} onConfirm={vi.fn()} onCancel={vi.fn()} />,
    );

    expect(html).toContain('pf-button pf-button--danger');
    expect(html).not.toContain('pf-button pf-button--primary');
  });

  it('danger=false(기본값)면 확인 버튼이 pf-button--primary 클래스를 가진다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog open={true} title="확인" onConfirm={vi.fn()} onCancel={vi.fn()} />,
    );

    expect(html).toContain('pf-button pf-button--primary');
    expect(html).not.toContain('pf-button pf-button--danger');
  });

  it('message를 생략하면 본문 문단을 렌더링하지 않는다', () => {
    const html = renderToStaticMarkup(
      <ConfirmDialog open={true} title="확인" onConfirm={vi.fn()} onCancel={vi.fn()} />,
    );

    expect(html).not.toContain('pf-modal__message');
  });
});
