# Checklist 2 - Environment Setup

PlanFlow reads local development values from `.env`. The file is ignored by Git.

## Required keys

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`
- `GOOGLE_WEB_CLIENT_ID`
- `GOOGLE_MAPS_API_KEY`
- `TMAP_API_KEY`
- `NAVER_MAP_CLIENT_ID`

## Optional keys

- `GOOGLE_ANDROID_CLIENT_ID`
- `GOOGLE_SERVER_CLIENT_ID`
- `NAVER_MAP_PROXY_URL`
- `NAVER_MAP_CLIENT_SECRET` for local debug only

## Notes

- `GOOGLE_WEB_CLIENT_ID` is used as Android `serverClientId` for Google Calendar sign-in.
- `GOOGLE_MAPS_API_KEY` is used for Google Distance Matrix travel-time fallback.
- `TMAP_API_KEY` is used first for route duration when origin/destination coordinates exist.
- `NAVER_MAP_CLIENT_ID` is used by the Android in-app Naver Dynamic Map SDK.
- Do not ship `NAVER_MAP_CLIENT_SECRET` in a production APK. For release, deploy `supabase/functions/naver-geocode`, store the secret in Supabase, and set `NAVER_MAP_PROXY_URL` to the function URL.
- Naver Calendar is now a 1차 배포 feature through Naver CalDAV/direct sync and phone-calendar import paths. Keep Naver OAuth, CalDAV credentials, and Naver Cloud Maps restrictions visible and testable.
