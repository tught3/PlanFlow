# Checklist 2 - Environment Setup

PlanFlow 앱 런타임은 더 이상 `.env`를 읽지 않습니다. 로컬 실행/빌드 값은
`--dart-define` 또는 `--dart-define-from-file=env/local.json`으로 전달합니다.

`SUPABASE_URL`과 `SUPABASE_ANON_KEY`는 클라이언트 앱에 들어가는 공개 설정값입니다.
데이터 보호는 anon key 자체가 아니라 Supabase RLS 정책으로 보장해야 합니다.

## Required client defines

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `GOOGLE_WEB_CLIENT_ID`
- `GOOGLE_MAPS_API_KEY`
- `TMAP_API_KEY`
- `NAVER_MAP_CLIENT_ID`

## Optional client defines

- `GOOGLE_ANDROID_CLIENT_ID`
- `GOOGLE_SERVER_CLIENT_ID`
- `NAVER_MAP_PROXY_URL`

## Local file example

Copy `env/local.example.json` to `env/local.json`, fill local values, and run:

```powershell
flutter run --dart-define-from-file=env/local.json
```

One-off values can also be passed directly:

```powershell
flutter run --dart-define=SUPABASE_URL=https://your-project.supabase.co --dart-define=SUPABASE_ANON_KEY=your-supabase-anon-key
```

Do not commit `env/local.json`.

## Notes

- `GOOGLE_WEB_CLIENT_ID` is used as Android `serverClientId` for Google Calendar sign-in.
- Never put `service_role`, OpenAI API keys, provider client secrets, or other server-only secrets in Flutter app defines, `.env`, APK assets, or any client bundle.
- GPT/OpenAI calls that require a secret key must go through a trusted backend such as a Supabase Edge Function.
- `GOOGLE_MAPS_API_KEY` is used for Google Distance Matrix travel-time fallback.
- `TMAP_API_KEY` is used first for route duration when origin/destination coordinates exist.
- `NAVER_MAP_CLIENT_ID` is used by the Android in-app Naver Dynamic Map SDK.
- Do not ship `NAVER_MAP_CLIENT_SECRET` in any APK. For release, deploy `supabase/functions/naver-geocode`, store the secret in Supabase, and set `NAVER_MAP_PROXY_URL` to the function URL.
- Naver Calendar is now a 1차 배포 feature through Naver CalDAV/direct sync and phone-calendar import paths. Keep Naver OAuth, CalDAV credentials, and Naver Cloud Maps restrictions visible and testable.
