# PlanFlow Final Setup Checklist

이 문서는 사용자가 직접 확인해야 하는 외부 설정과 실기기 검증 항목을 추적하기 위한 체크리스트입니다.

## 1. Code / GitHub

- [x] Flutter 기본 프로젝트 생성
- [x] v2 체크리스트 1-23 구현
- [x] v3 추가 항목 확인
- [x] v3 체크리스트 24: PRO 얼리버드 이메일 수집 기능 구현
- [x] `flutter analyze` 통과
- [x] `flutter test` 통과
- [x] GitHub 원격 저장소 `PlanFlow` 생성 및 push
- [ ] `PlanFlow_Codex_Prompt_v3.md` 커밋 반영 여부 확인

## 2. Supabase

- [x] Supabase 프로젝트 생성
- [x] `.env`에 `SUPABASE_URL` 입력
- [x] `.env`에 `SUPABASE_ANON_KEY` 입력
- [ ] Supabase SQL Editor에서 최신 `supabase/schema.sql` 전체 실행
- [ ] Table Editor에서 `users` 테이블 확인
- [ ] Table Editor에서 `events` 테이블 확인
- [ ] Table Editor에서 `pre_actions` 테이블 확인
- [ ] Table Editor에서 `reminders` 테이블 확인
- [ ] Table Editor에서 `voice_logs` 테이블 확인
- [ ] Table Editor에서 `location_history` 테이블 확인
- [ ] Table Editor에서 `user_settings` 테이블 확인
- [ ] Table Editor에서 `early_bird_emails` 테이블 확인
- [ ] `early_bird_emails` RLS 활성화 확인
- [ ] `early_bird_emails`에는 공개 insert/select policy가 없는지 확인
- [ ] `submit_early_bird_email` RPC 함수가 있는지 확인
- [ ] `anon`, `authenticated` role이 `submit_early_bird_email` 실행 권한을 갖는지 확인

중요: v3에서 `early_bird_emails` 테이블이 추가됐으므로, 예전에 SQL을 실행했어도 최신 `schema.sql`을 다시 실행해야 합니다.

## 3. OpenAI

- [x] OpenAI API key 발급
- [x] `.env`에 `OPENAI_API_KEY` 입력
- [x] 코드에서 `AppEnv.openAiApiKey`로 읽음
- [ ] 실제 앱에서 음성 입력 후 GPT 일정 파싱 확인

## 4. Google Calendar

- [x] Google Cloud 프로젝트 생성
- [x] Android OAuth Client ID 생성
- [x] `.env`에 `GOOGLE_ANDROID_CLIENT_ID` 입력
- [x] 코드에서 `CalendarSyncService`에 Google Client ID 연결
- [ ] Google Cloud에서 Google Calendar API가 사용 설정됨인지 확인
- [ ] OAuth consent screen / Google Auth Platform 설정 완료 확인
- [ ] 테스트 사용자에 본인 Gmail이 들어갔는지 확인
- [ ] Android OAuth Client package name이 `com.example.planflow`인지 확인
- [ ] Android OAuth Client SHA-1이 `D8:A5:47:45:F2:B3:FF:2E:A1:42:B5:07:2A:12:C7:F4:2F:32:5D:06`인지 확인
- [ ] 실제 Android 기기에서 Google Calendar 상태/로그인 확인

## 5. Naver Calendar

- [x] Naver Developers 앱 등록
- [x] Client ID 발급
- [x] Client Secret 발급
- [x] `.env`에 `NAVER_CLIENT_ID` 입력
- [x] `.env`에 `NAVER_CLIENT_SECRET` 입력
- [x] 코드에서 Naver env 값을 읽을 준비 완료
- [ ] Naver Developers API 설정에서 네이버 로그인 사용 확인
- [ ] Naver Developers API 설정에서 캘린더 사용 확인
- [ ] 로그인 오픈 API 서비스 환경에 Android가 등록됐는지 확인
- [ ] Android 패키지 이름이 `com.example.planflow`인지 확인
- [ ] Client Secret이 외부에 노출됐을 가능성이 있으면 재발급
- [ ] 실제 Naver Calendar API 구현은 아직 미완료라 별도 개발 필요

## 6. Android Notifications

- [x] `NotificationService` 코드 구현
- [x] Pre-action `notify_at` 계산 구현
- [ ] Android 실제 기기 연결
- [ ] `flutter run` 실행
- [ ] 앱 알림 권한 허용
- [ ] Android 13+ 알림 권한 허용 확인
- [ ] 정확한 알람 권한 필요 시 허용
- [ ] 일정 생성 후 사전 알림이 실제로 뜨는지 확인
- [ ] 중요 일정 full-screen/critical 알림 동작 확인

## 7. STT / Voice Security

- [x] `speech_to_text` 사용
- [x] `SpeechListenOptions.onDevice: true` 설정
- [x] 음성 파일 외부 전송 금지 원칙 반영
- [ ] 실제 Android 기기에서 한국어 음성 인식 확인
- [ ] 인식된 텍스트만 저장되는지 확인

## 8. TTS / Briefing

- [x] `flutter_tts` 기반 TTS 서비스 구현
- [x] morning/evening briefing scaffold 구현
- [ ] 실제 Android 기기에서 TTS 음성 출력 확인
- [ ] 모닝/이브닝 브리핑 예약 동작 확인

## 9. Home Widget

- [x] Flutter `HomeWidgetService` scaffold 구현
- [x] stale data 방지 테스트 추가
- [ ] Android `AppWidgetProvider` 구현
- [ ] Android widget layout XML 추가
- [ ] `AndroidManifest`에 widget receiver 등록
- [ ] 위젯에서 다음 일정 표시 확인
- [ ] 위젯 마이크 버튼 또는 앱 진입 동작 확인
- [ ] iOS Widget Extension은 추후 Mac/Xcode에서 진행

## 10. App Smoke Test

- [ ] 앱 실행 성공
- [ ] 홈 화면 표시 확인
- [ ] PRO 얼리버드 신청 카드 표시 확인
- [ ] 이메일 입력 후 `early_bird_emails` 저장 확인
- [ ] 음성 입력 화면 진입 확인
- [ ] 음성 입력이 텍스트로 변환되는지 확인
- [ ] GPT가 일정 JSON으로 파싱하는지 확인
- [ ] `ConfirmScreen`에서 일정 수정/저장 확인
- [ ] `HomeScreen`에서 일정 표시 확인
- [ ] `CalendarScreen`에서 일정 표시 확인
- [ ] `EventDetailScreen` 확인
- [ ] `EventEditScreen` 확인
- [ ] `SettingsScreen`에서 Supabase/OpenAI/Google/Naver 상태 확인

## 11. iOS

- [ ] iOS는 추후 진행
- [ ] Mac/Xcode 준비
- [ ] Bundle ID 확정
- [ ] iOS OAuth Client ID 생성
- [ ] iOS 알림 권한 테스트
- [ ] iOS Widget Extension / App Group 설정

## Current Critical Path

1. 최신 Supabase `schema.sql` 다시 실행
2. Supabase에서 `early_bird_emails` 포함 8개 테이블 확인
3. Supabase에서 `submit_early_bird_email` RPC 함수 확인
4. Google Calendar API Enable / 테스트 사용자 확인
5. Naver API 설정 확인
6. Android 실제 기기에서 `flutter run`
7. Android 네이티브 Home Widget 구현

