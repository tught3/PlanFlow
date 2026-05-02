# Checklist 2 - Environment Setup

PlanFlow reads secrets and service endpoints from a local `.env` file.

## Files

- `.env.example`: committed template with placeholder values
- `.env`: local-only file, ignored by git

## Required keys

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`
- `GOOGLE_WEB_CLIENT_ID`
- `GOOGLE_MAPS_API_KEY`

## Optional keys

- `GOOGLE_MAPS_API_KEY`

## Notes

- `lib/main.dart` loads `.env` at startup.
- `lib/core/env.dart` exposes the parsed values for later app wiring.
- If `.env` is empty, the app still starts, but integrations remain inactive.
- `GOOGLE_WEB_CLIENT_ID` is used as Android `serverClientId` for Google Calendar sign-in.
- `GOOGLE_MAPS_API_KEY` is used for 1차 이동시간 버퍼. If it is absent, PlanFlow keeps using the local fallback estimate.
- Naver Calendar is intentionally deferred for 1차 배포.
