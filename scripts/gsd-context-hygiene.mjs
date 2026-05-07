#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const args = new Set(process.argv.slice(2));
const strict = args.has('--strict');

const root = findRepoRoot(process.cwd());
const requiredFiles = [
  'AGENTS.md',
  '.planning/STATE.md',
  '.planning/context/ACTIVE_SUMMARY.md',
];
const optionalFiles = [
  'PlanFlow_Codex_Prompt_v3.md',
  '.planning/codebase/STRUCTURE.md',
  '.planning/codebase/STACK.md',
  '.planning/codebase/CONCERNS.md',
  '.planning/codebase/TESTING.md',
];

const missingRequired = requiredFiles.filter((file) => !existsSync(at(file)));
const presentOptional = optionalFiles.filter((file) => existsSync(at(file)));
const gitStatus = readGitStatus();
const activeSummary = readText('.planning/context/ACTIVE_SUMMARY.md');
const state = readText('.planning/STATE.md');

printHeader();
printLine('Repo', root);
printLine('State', firstMeaningfulLine(state) ?? 'missing');
printLine('Active checkpoint', latestHeading(activeSummary) ?? 'missing');
printLine('Optional context', presentOptional.length === 0
  ? 'none found'
  : presentOptional.join(', '));
printLine('Git worktree', gitStatus.length === 0
  ? 'clean'
  : `${gitStatus.length} changed item(s)`);

if (gitStatus.length > 0) {
  console.log('');
  console.log('Changed files:');
  for (const line of gitStatus.slice(0, 40)) {
    console.log(`  ${line}`);
  }
  if (gitStatus.length > 40) {
    console.log(`  ... ${gitStatus.length - 40} more`);
  }
}

if (missingRequired.length > 0) {
  console.log('');
  console.log('Missing required context:');
  for (const file of missingRequired) {
    console.log(`  - ${file}`);
  }
}

const warnings = [];
if (latestHeading(activeSummary) == null) {
  warnings.push('ACTIVE_SUMMARY.md has no markdown checkpoint heading.');
}
if (presentOptional.length < optionalFiles.length) {
  warnings.push('Some optional planning/codebase docs are absent.');
}
if (gitStatus.length > 0) {
  warnings.push('Worktree is dirty; avoid reverting unrelated user changes.');
}

if (warnings.length > 0) {
  console.log('');
  console.log('Warnings:');
  for (const warning of warnings) {
    console.log(`  - ${warning}`);
  }
}

if (activeSummary) {
  console.log('');
  console.log('Recent ACTIVE_SUMMARY excerpt:');
  for (const line of tailNonEmpty(activeSummary, 8)) {
    console.log(`  ${line}`);
  }
}

if (missingRequired.length > 0 || (strict && gitStatus.length > 0)) {
  process.exitCode = 1;
}

function printHeader() {
  console.log('GSD context hygiene');
  console.log('===================');
}

function printLine(label, value) {
  console.log(`${label}: ${value}`);
}

function at(relativePath) {
  return join(root, relativePath);
}

function readText(relativePath) {
  const path = at(relativePath);
  if (!existsSync(path)) {
    return '';
  }
  return readFileSync(path, 'utf8');
}

function firstMeaningfulLine(text) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0);
}

function latestHeading(text) {
  const headings = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /^##\s+/.test(line));
  return headings.at(-1) ?? null;
}

function tailNonEmpty(text, count) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .slice(-count);
}

function readGitStatus() {
  try {
    return execFileSync('git', ['status', '--short'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
      .split(/\r?\n/)
      .map((line) => line.trimEnd())
      .filter((line) => line.length > 0);
  } catch {
    return ['git status unavailable'];
  }
}

function findRepoRoot(start) {
  let current = resolve(start);
  while (true) {
    if (
      existsSync(join(current, '.planning', 'STATE.md')) ||
      existsSync(join(current, '.git'))
    ) {
      return current;
    }
    const parent = dirname(current);
    if (parent === current) {
      return resolve(start);
    }
    current = parent;
  }
}
