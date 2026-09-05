/**
 * P10: 배너 광고 컨테이너 CSS(`src/styles/layout.css`의 `.ad-banner-slot`) 정적 계약 테스트.
 *
 * 이 프로젝트에는 jsdom이 설치되어 있지 않아 실제 브라우저 레이아웃(뷰포트
 * overflow, computed style 등)을 검증할 수 없다. 그래서 이 테스트는 CSS
 * 파일을 텍스트로 읽어 정규식으로 규칙 블록을 추출한 뒤, Toss SDK가 요구하는
 * 핵심 계약(전체 너비 100%, position: fixed 금지, 고정 px 너비 금지)이 소스
 * 텍스트에 존재/부재하는지만 확인하는 정적(static) 검증이다. 실제 렌더링된
 * 레이아웃이 이 계약대로 동작함을 증명하지는 않는다.
 *
 * tsconfig.app.json의 "types"가 ["vite/client"]만 지정해 src/ 트리 전체에는
 * Node 전역/모듈 타입이 기본으로 안 잡힌다(node:fs 등은 tsconfig.node.json
 * 쪽에만 있음, vite.config.ts 전용). tsconfig.app.json을 고치는 건 이 작업의
 * 범위를 벗어나므로, 이 테스트 파일 안에서만 triple-slash reference로
 * @types/node(이미 devDependency로 설치돼 있음)를 끌어와 타입 에러 없이
 * node:fs/node:path/node:url을 사용한다.
 */
/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const __dirname = dirname(fileURLToPath(import.meta.url));
const layoutCssPath = resolve(__dirname, '../../styles/layout.css');
const layoutCss = readFileSync(layoutCssPath, 'utf-8');

/**
 * `.ad-banner-slot { ... }` 규칙 블록 하나만 추출한다. 파일 전체를 대상으로
 * 검사하면 다른 규칙(예: `.app-layout__nav`)에 있는 `position: fixed`나
 * 우연히 320px 같은 값이 있는 다른 규칙에 false-positive로 걸릴 수 있어,
 * 이 규칙 블록 안쪽 텍스트만 잘라내어 검사 대상으로 삼는다.
 */
function extractRuleBlock(css: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = new RegExp(`${escaped}\\s*\\{([^}]*)\\}`).exec(css);
  if (!match || match[1] === undefined) {
    throw new Error(`CSS 규칙 블록을 찾지 못했다: ${selector}`);
  }
  return match[1];
}

describe('.ad-banner-slot CSS 계약 (정적 텍스트 검증)', () => {
  const bannerRule = extractRuleBlock(layoutCss, '.ad-banner-slot');

  it('width: 100%를 포함한다 (Toss SDK: 컨테이너 폭은 항상 화면 전체 너비)', () => {
    expect(/width\s*:\s*100%/.test(bannerRule)).toBe(true);
  });

  it('position: fixed를 포함하지 않는다 (Toss SDK: 배너는 fixed 배치 금지)', () => {
    expect(/position\s*:\s*fixed/.test(bannerRule)).toBe(false);
  });

  it('고정 px 너비 값(예: width: 320px)을 포함하지 않는다', () => {
    expect(/width\s*:\s*\d+px/.test(bannerRule)).toBe(false);
  });
});
