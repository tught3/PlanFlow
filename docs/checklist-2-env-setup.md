# Checklist 2 - Environment Setup

PlanFlow reads secrets and service endpoints from a local `.env` file.

## Files

- `.env.example`: committed template with placeholder values
- `.env`: local-only file, ignored by git

## Required keys

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`

## Notes

- `lib/main.dart` loads `.env` at startup.
- `lib/core/env.dart` exposes the parsed values for later app wiring.
- If `.env` is empty, the app still starts, but integrations remain inactive.
