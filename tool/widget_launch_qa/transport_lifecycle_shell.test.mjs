// Pure Node regression: prove that tool/widget_launch_qa/run_transport.sh
// actually guards observe_process `mv` publication and prove_absent before
// the absent checker. We never execute Darwin/install code, never touch a
// real simulator, never call real simctl. We extract the real function
// bodies from the source file and run them inside a child bash whose
// xcrun, mv, and node are stubs the test fully controls. Temp dir is owned
// and cleaned up by this process.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const scriptPath = path.join(here, 'run_transport.sh');

const isWin = process.platform === 'win32';
const bashExe = isWin
  ? (process.env.WIDGET_QA_BASH || 'C:/Program Files/Git/bin/bash.exe')
  : '/bin/bash';

// Single-brace-depth walker. The observed run_transport.sh keeps every
// function body free of inner `{` or `}` (commands and quoted strings only),
// so brace counting is exact.
function extractBashFunction(source, name) {
  const lines = source.split(/\r?\n/);
  const header = new RegExp('^' + name + '\\s*\\(\\)\\s*\\{\\s*$');
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (header.test(lines[i])) { start = i; break; }
  }
  if (start === -1) throw new Error('function ' + name + ' not found in source');
  let depth = 1;
  let end = -1;
  for (let i = start + 1; i < lines.length; i++) {
    const opens = (lines[i].match(/\{/g) || []).length;
    const closes = (lines[i].match(/\}/g) || []).length;
    depth += opens - closes;
    if (depth <= 0) { end = i; break; }
  }
  if (end === -1) throw new Error('function ' + name + ' body never closed');
  return lines.slice(start, end + 1).join('\n');
}

function makeTempDir(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), label));
}

function cleanRm(dir) {
  try { fs.rmSync(dir, {recursive: true, force: true}); } catch {}
}

// Child bash script shape:
//   1. Sets QA env that observe_process / prove_absent read from globals.
//   2. Defines stubs that shadow xcrun, mv, node exactly how this test wants.
//   3. Provides the extracted real function bodies in this stubbed env.
//   4. Drives an `until prove_absent` loop so errexit semantics are real.
function buildWrapper({tmp, observeText, proveText, xcrunBlock, mvBlock, nodeBlock}) {
  return [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'UDID="${UDID:-11111111-2222-3333-4444-555555555555}"',
    'BUNDLE_ID="${BUNDLE_ID:-com.fluxstudio.planflow}"',
    'RUN_OUT="${RUN_OUT:-' + tmp + '}"',
    'CHECKER="${CHECKER:-' + path.join(here, 'verify_transport_receipts.mjs') + '}"',
    'mkdir -p "$RUN_OUT"',
    xcrunBlock,
    mvBlock,
    nodeBlock,
    observeText,
    proveText,
    'iter=0',
    'until prove_absent; do',
    '  iter=$((iter+1))',
    '  [ "$iter" -gt 5 ] && { echo ITER_LIMIT; exit 2; }',
    '  sleep 0',
    'done',
    'echo PROVE_ABSENT_PASS',
    'exit 0',
  ].join('\n');
}

function runBashScript(scriptFile, env) {
  const res = spawnSync(bashExe, ['--noprofile', '--norc', scriptFile], {
    env: {...process.env, ...env},
    encoding: 'utf8',
    timeout: 30000,
  });
  return res;
}

// xcrun stub. observe_process calls:
//   xcrun simctl spawn "$UDID" launchctl list > "$destination.new"
// xcrun receives: $1=simctl $2=spawn $3=UDID $4=launchctl $5=list.
// Stdout goes to the caller-controlled `>` redirect, so we just write the
// listing to stdout. Listing returned here is complete and ABSENT for the
// target bundle.
const xcrunWriteAbsent = [
  'xcrun() {',
  '  if [ "$1" = "simctl" ] && [ "$2" = "spawn" ] && [ "$4" = "launchctl" ] && [ "$5" = "list" ]; then',
  "    printf 'PID Status Label\\n1 0 com.apple.one\\n2 0 com.apple.two\\n200 0 UIKitApplication:com.apple.somethingelse[xyz]\\n'",
  '    return 0',
  '  fi',
  '  return 1',
  '}',
].join('\n');

// Pre-existing old lifecycle-current.txt shape: valid listing, also ABSENT.
const oldAbsentListing = [
  'PID Status Label',
  '1 0 com.apple.one',
  '2 0 com.apple.two',
].join('\n');

// node stub. The bash-side guard is the regression target here, so the
// validator CLI does not need to run for real. We keep $CHECKER match so
// future hardening (real CLI integration) keeps the same wiring.
const nodeAbsentOk = [
  'node() {',
  '  if [ "$1" = "$CHECKER" ] && [ "$2" = "absent" ]; then',
  '    return 0',
  '  fi',
  '  return 0',
  '}',
].join('\n');

const mvAlwaysFail = 'mv() { return 1; }';

test('extracted observe_process carries the mv-publication guard and BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH enum', () => {
  const src = fs.readFileSync(scriptPath, 'utf8');
  const observe = extractBashFunction(src, 'observe_process');
  assert.match(observe, /observe_process\s*\(\)\s*\{/);
  assert.match(observe, /if ! mv "([^"]+\.new)" "([^"]+)"; then/);
  assert.match(observe, /BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH/);
  assert.match(observe, /\bfi\s*$/m);
  const prove = extractBashFunction(src, 'prove_absent');
  assert.match(prove, /if ! observe_process "([^"]+\/lifecycle-current\.txt)"; then/);
  assert.match(prove, /BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH/);
});

test('mv failure exits non-zero with BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH and never silently consumes the old snapshot', () => {
  const tmp = makeTempDir('lifecycle-mvfail-');
  try {
    const lifecycle = path.join(tmp, 'lifecycle-current.txt');
    // Pre-existing valid old snapshot. With a broken guard, prove_absent
    // would parse THIS old file and could false-PASS. The test asserts that
    // does not happen even though the old listing already satisfies absent.
    fs.writeFileSync(lifecycle, oldAbsentListing + '\n');

    const src = fs.readFileSync(scriptPath, 'utf8');
    const observeText = extractBashFunction(src, 'observe_process');
    const proveText = extractBashFunction(src, 'prove_absent');

    const wrapper = buildWrapper({
      tmp,
      observeText,
      proveText,
      xcrunBlock: xcrunWriteAbsent,
      mvBlock: mvAlwaysFail,
      nodeBody: undefined,
      nodeBlock: nodeAbsentOk,
    });
    const scriptFile = path.join(tmp, 'run_under_test.sh');
    fs.writeFileSync(scriptFile, wrapper, {mode: 0o644});

    const res = runBashScript(scriptFile, {
      UDID: '11111111-2222-3333-4444-555555555555',
      BUNDLE_ID: 'com.fluxstudio.planflow',
      RUN_OUT: tmp,
    });

    assert.notEqual(res.status, 0,
      'shell must exit non-zero when mv publication fails. got status=' + res.status +
      ' stdout=' + JSON.stringify(res.stdout) + ' stderr=' + JSON.stringify(res.stderr));
    assert.match((res.stdout || '') + (res.stderr || ''), /BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH/);
    // Must NOT have emitted the false-positive pass marker.
    assert.doesNotMatch((res.stdout || '') + (res.stderr || ''), /PROVE_ABSENT_PASS/);
    // Old snapshot must NOT have been replaced. The sidecar $destination.new
    // is acceptable; the destination itself is the original bytes only.
    assert.equal(fs.readFileSync(lifecycle, 'utf8'), oldAbsentListing + '\n',
      'old valid absence listing must remain untouched at destination');
  } finally {
    cleanRm(tmp);
  }
});

test('positive case: real mv publishes new listing and prove_absent reaches PROVE_ABSENT_PASS', () => {
  const tmp = makeTempDir('lifecycle-mvok-');
  try {
    const lifecycle = path.join(tmp, 'lifecycle-current.txt');
    fs.writeFileSync(lifecycle, oldAbsentListing + '\n');

    const src = fs.readFileSync(scriptPath, 'utf8');
    const observeText = extractBashFunction(src, 'observe_process');
    const proveText = extractBashFunction(src, 'prove_absent');

    // Leave `mv` untouched so the real bash builtin / external is exercised.
    const noMvStub = '# mv: real (builtin / external) — proves successful path';

    const wrapper = buildWrapper({
      tmp,
      observeText,
      proveText,
      xcrunBlock: xcrunWriteAbsent,
      mvBlock: noMvStub,
      nodeBlock: nodeAbsentOk,
    });
    const scriptFile = path.join(tmp, 'run_under_test.sh');
    fs.writeFileSync(scriptFile, wrapper, {mode: 0o644});

    const res = runBashScript(scriptFile, {
      UDID: '11111111-2222-3333-4444-555555555555',
      BUNDLE_ID: 'com.fluxstudio.planflow',
      RUN_OUT: tmp,
    });

    assert.equal(res.status, 0,
      'positive case must exit 0. status=' + res.status +
      ' stdout=' + JSON.stringify(res.stdout) + ' stderr=' + JSON.stringify(res.stderr));
    assert.match((res.stdout || '') + (res.stderr || ''), /PROVE_ABSENT_PASS/);
    const after = fs.readFileSync(lifecycle, 'utf8');
    assert.match(after, /200 0 UIKitApplication:com\.apple\.somethingelse/);
  } finally {
    cleanRm(tmp);
  }
});

test('observe_process failure (xcrun returns 1) blocks before checker', () => {
  const tmp = makeTempDir('lifecycle-xcrun-');
  try {
    const lifecycle = path.join(tmp, 'lifecycle-current.txt');
    fs.writeFileSync(lifecycle, oldAbsentListing + '\n');

    const src = fs.readFileSync(scriptPath, 'utf8');
    const observeText = extractBashFunction(src, 'observe_process');
    const proveText = extractBashFunction(src, 'prove_absent');

    const wrapper = buildWrapper({
      tmp,
      observeText,
      proveText,
      xcrunBlock: 'xcrun() { return 1; }',
      mvBlock: '# mv real',
      nodeBlock: nodeAbsentOk,
    });
    const scriptFile = path.join(tmp, 'run_under_test.sh');
    fs.writeFileSync(scriptFile, wrapper, {mode: 0o644});

    const res = runBashScript(scriptFile, {
      UDID: '11111111-2222-3333-4444-555555555555',
      BUNDLE_ID: 'com.fluxstudio.planflow',
      RUN_OUT: tmp,
    });

    assert.notEqual(res.status, 0);
    assert.match((res.stdout || '') + (res.stderr || ''), /BLOCKED_TRANSPORT_PROCESS_OBSERVATION/);
    assert.doesNotMatch((res.stdout || '') + (res.stderr || ''), /PROVE_ABSENT_PASS/);
  } finally {
    cleanRm(tmp);
  }
});
