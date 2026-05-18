# AGENTS.md for `C:\PlanFlow`

This file is the top-priority working rule for this repo.
Secondary detail sources: `CLAUDE.md` and `docs/agent-rules-*.md`.

## Default language
- Always respond in Korean.

## Default operating order
1. If a request has 2 or more issues, or spans multiple subsystems, plan first with the strongest planner available.
2. Use the plan to execute with worker agents, preferably in parallel when file scopes do not overlap.
3. Always run a separate review/verifier pass after implementation.
4. If review finds anything incomplete or risky, fix it and review again.
5. Only report completion when nothing is left to change.

## Model routing
- Default behavior: route work by task complexity automatically, even if the user names a model.
- Planner/Main for non-trivial work: `gpt-5.5`.
- Worker agents for general execution, code edits, and test updates: `gpt-5.3-codex-spark`.
- Complex refactors, architecture changes, or hard bugs: escalate to `gpt-5.4-mini` or higher.
- Review / verification: default `gpt-5.3-codex-spark`; use `gpt-5.4-mini` for high-risk changes.
- If the exact model cannot be selected in the current environment, keep the same role split and report the limitation.
## Workflow rules
- Mandatory enforcement: for multi-issue or high-risk work, do not report completion unless context hygiene, role/model routing, worker delegation, reviewer verification, fix-after-review loop, tests/build, checkpoint, commit, push, and device run check have all been attempted and explicitly reported.
- Model routing is not advisory. Use `gpt-5.5` for planning, `gpt-5.3-codex-spark` for normal execution/review, and escalate execution/review to `gpt-5.4-mini` for the high-risk areas listed below.
- When the user says "AGENTS.md대로" or asks for subagents/reviewer, treat worker and reviewer agents as required. If a tool/runtime limit blocks spawning, close completed agents and retry; if still blocked, report the blocker and continue with the closest safe fallback.
- Every task must begin with context hygiene: check `.planning/STATE.md`, check `.planning/context/ACTIVE_SUMMARY.md`, and run `node scripts/gsd-context-hygiene.mjs` when it exists. If the script is missing, explicitly record that it is missing and continue.
- Every completed task/logical change must end with verification, a planning-context checkpoint, a Git commit, and a push to the remote repository.
- Every completed task/logical change must also end with a fresh build and, when the target device is available, a real run/launch check before reporting completion.
- For any Flutter run/build/test command in this repo, prefer `scripts/flutter-local.ps1` so `env/local.json` and the local `--dart-define` set are injected automatically. Do not fall back to raw `flutter` unless the wrapper is missing or the user explicitly asks.
- Before starting work, check `.planning/STATE.md` and `.planning/context/ACTIVE_SUMMARY.md`.
- Run `node scripts/gsd-context-hygiene.mjs` at session start, before long work, and before final report. If the script is missing, record that and continue.
- After every completed logical change, update `.planning/context/ACTIVE_SUMMARY.md` with a short checkpoint.
- After every completed logical change, commit and push to the remote repository.
- Do not leave unused helper terminals or sessions open; close them when they are no longer needed.
- Do not commit unrelated or user-created untracked files unless explicitly requested.
- Prefer existing code, shared helpers, and existing docs before creating new structures.
- Create new code only when reuse is clearly worse.
- Do not delete unused code until implementation and verification are fully complete.
- ADB package-destructive commands (`adb uninstall`, `pm uninstall`, `pm clear`, broad app cleanup scripts) must target only this repo's package `com.planflow.app`. Never target FinFlow or other app package names from this workspace while working in PlanFlow, and never use wildcard/broad package deletion.
- For complex work, split into independent subagent tasks and run them in parallel when safe.
- When code changes are needed, prefer worker agents for implementation and a separate reviewer for verification.
- Completed worker/reviewer agents must be closed unless there is a specific reuse plan.
- Keep direct edits narrow; use them only for trivial fixes or repo settings/doc updates.
- If a request has 2 or more issues, the plan-review-implement-review loop is mandatory by default.
- Do not ask for permission between intermediate steps in the same batch unless a real decision is blocked.
- Answer all user questions that appear in the same request, even if they are separate from the code task.
- Do not modify tests unless the task explicitly asks for test changes or the implementation requires test updates.
- Keep the scope tight; do not add unrelated changes, and report known gaps instead.

## Repo-specific rules
- Work from `C:\PlanFlow` unless the user explicitly changes the working path.
- `E:\Project\PlanFlow` is a read-only reference source for files that previously worked, especially login and app flow.
- `G:\AI-automatic-expense-tracker` is reference-only and must not be modified.
- PlanFlow product scope is defined by `PlanFlow_Codex_Prompt_v3.md`.
- Supabase schema source of truth is `supabase/schema.sql`.
- Because of NexusFlow integration, stop and get explicit user confirmation before any DB schema, migration, or RLS change.
- Treat future Flow Core/shared-core files as cross-project contracts for NexusFlow and related apps. If `packages/`, `flow_core/`, shared domain models, shared repositories, shared parsing/routing services, or other Flow Core extraction targets are created or modified, stop first and get explicit user confirmation unless the user has directly requested that exact change.
- For 1st release, do not implement billing, ads, reward ads, Kakao/SMS/call detection, or TEAM/BUSINESS features.
- Naver Calendar is now a 1st-release working feature. Keep OAuth consent, token handling, and calendar export behavior visible and testable.
- Keep all user-facing UI text Korean unless a platform/provider brand requires otherwise.
- If Korean text appears broken/mojibake in terminal output, re-read the file or output explicitly as UTF-8 before interpreting or editing it. Do not make decisions from broken Korean text.
- Voice files must never be sent to external servers. Only STT text may be stored or sent for parsing.
- `speech_to_text` must use `SpeechListenOptions(onDevice: true)` for STT.
- If ADB screenshots or mirroring are black, ask the user to turn on the phone screen before visual verification.
- Keep the PlanFlow Home UI close to the compact card-based reference: clean Korean schedule cards, no large blank first viewport.

## Project structure

```text
lib/
├── core/                # env, routing, theme, constants
├── data/                # models and Supabase repositories
├── providers/           # app/auth/event/settings state
├── screens/             # Flutter screens
├── services/            # STT, GPT, calendar, notification, widget, backup
└── widgets/             # shared UI widgets
android/                 # Android app, widget, manifest
supabase/schema.sql      # DB schema and RLS source of truth
```

## Deployment structure
- Android first for 1st release.
- Supabase: Auth, PostgreSQL, RLS, backup/restore RPC.
- Google Cloud: Google Calendar OAuth and Google Maps travel-time API.

## Detail references
- Workflow details: `docs/agent-rules-workflow.md`
- Validation details: `docs/agent-rules-validation.md`
- Operations details: `docs/agent-rules-operations.md`

