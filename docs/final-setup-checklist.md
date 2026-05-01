# PlanFlow 1차/2차 개발 상태 체크리스트

이 문서는 v3 프롬프트 기준으로 1차 개발, 2차 개발, 지금 당장 확인할 일을 분리한 최종 점검표입니다.

## 결론

- 현재 개발 방향은 1차 배포까지가 맞습니다.
- 1차 범위는 v3 구현 체크리스트 1-24입니다.
- 2차 범위는 v3 구현 체크리스트 25-31입니다.
- 2차 기능은 지금 구현하지 않고, 1차 실기기 검증 후 별도 단계로 진행합니다.

## 1차 개발 범위

1차 목표는 수익구조 없이 전체 기능을 무료로 열고, 앱 안에는 `PRO 얼리버드 신청`만 노출하는 MVP입니다.

### 1차 코드 구현 상태

- [x] 1. Supabase 프로젝트 생성 및 SQL 스키마 준비
- [x] 2. `.env` 파일 생성 및 API 키 입력
- [x] 3. Flutter 프로젝트 생성 및 패키지 설치
- [x] 4. 폴더 구조 생성
- [x] 5. `main.dart` Supabase 초기화
- [x] 6. `core/router.dart` 라우팅
- [x] 7. `core/theme.dart` 테마
- [x] 8. `SttService` 구현 및 테스트
- [x] 9. `GptService` 구현 및 파싱 테스트
- [x] 10. `EventRepository` Supabase CRUD
- [x] 11. `VoiceInputScreen` 구현
- [x] 12. `ConfirmScreen` 구현
- [x] 13. `HomeScreen` 구현 및 얼리버드 카드
- [x] 14. `CalendarScreen` 구현
- [x] 15. `EventDetailScreen` / `EventEditScreen`
- [x] 16. `NotificationService` 구현
- [x] 17. 선행행동 역산 알림 로직
- [x] 18. 이브닝/모닝 브리핑 scaffold
- [x] 19. Google Calendar 연동 scaffold 및 env 연결
- [x] 20. Naver Calendar env 준비 및 placeholder
- [x] 21. 이동시간 버퍼 scaffold
- [x] 22. Flutter Home Widget service scaffold
- [x] 23. `SettingsScreen`
- [x] 24. `early_bird_emails` 기반 PRO 얼리버드 이메일 수집

### 1차 코드 보강 완료

- [x] Android `INTERNET` 권한 선언
- [x] Android `RECORD_AUDIO` 권한 선언
- [x] Android `POST_NOTIFICATIONS` 권한 선언
- [x] Android `SCHEDULE_EXACT_ALARM` 권한 선언
- [x] Android `USE_FULL_SCREEN_INTENT` 권한 선언
- [x] Android `VIBRATE` 권한 선언
- [x] Android `RECEIVE_BOOT_COMPLETED` 권한 선언
- [x] Android `WAKE_LOCK` 권한 선언
- [x] Android AlarmManager service/receiver 선언
- [x] MainActivity lock-screen wake 속성 선언
- [x] `flutter_local_notifications` 예약 알림/부팅 복구 receiver 선언
- [x] Critical alarm 예약 전 full-screen intent 권한 요청
- [x] Gradle wrapper 파일 세트 커밋 준비

### 1차에서 아직 실제 검증이 필요한 것

- [ ] Supabase SQL Editor에서 최신 `supabase/schema.sql` 전체 실행
- [ ] Supabase에서 `early_bird_emails` 포함 8개 테이블 확인
- [ ] Supabase에서 `submit_early_bird_email` RPC 함수 확인
- [ ] `early_bird_emails`에 공개 insert/select policy가 없는지 확인
- [ ] Google Calendar API Enable 확인
- [ ] Google OAuth 테스트 사용자 등록 확인
- [ ] Naver Developers API 설정 확인
- [ ] Android 실제 기기에서 `flutter run`
- [ ] 앱 알림 권한 허용 확인
- [ ] 정확한 알람 권한 허용 확인
- [ ] 중요 일정 full-screen/critical 알림 동작 확인
- [ ] 한국어 음성 입력 확인
- [ ] GPT 일정 파싱 확인
- [ ] 일정 저장 플로우 확인
- [ ] PRO 얼리버드 이메일 저장 확인
- [ ] TTS 브리핑 음성 출력 확인
- [ ] Android Home Widget 네이티브 구현 및 실제 표시 확인

## 1차에서 주의할 점

- Google Calendar는 Android Client ID와 env 연결까지 되어 있습니다. 실제 로그인/동기화는 Google API Enable, 테스트 사용자 등록, 실기기 실행으로 확인해야 합니다.
- Naver Calendar는 키/env 준비까지 되어 있지만 실제 캘린더 API 구현은 아직 placeholder입니다.
- Home Widget은 Flutter service scaffold와 테스트는 있지만 Android 네이티브 AppWidgetProvider/XML/manifest receiver는 아직 미완료입니다.
- iOS는 1차 Android 우선 전략상 추후 진행입니다.

## 2차 개발 범위

2차는 1차 배포 후 구현합니다. 현재는 계획만 유지하고 코드 구현하지 않습니다.

- [ ] 25. 온보딩 권한 동의 화면
- [ ] 26. 카톡/문자 감지 서비스
- [ ] 27. 통화 텍스트 파일 감지 서비스
- [ ] 28. GPT 통화 텍스트 품질 개선 로직
- [ ] 29. 감지 모달 UI
- [ ] 30. `detection_logs` 테이블 추가 및 RLS 적용
- [ ] 31. 설정 화면에 감지 기능 ON/OFF 토글 추가

## 지금 당장 해야 할 일

1. Supabase SQL Editor에서 최신 `supabase/schema.sql` 전체 실행
2. Supabase Table Editor에서 8개 테이블 확인
3. Supabase Database Functions에서 `submit_early_bird_email` 확인
4. Google Cloud에서 Calendar API Enable 및 테스트 사용자 확인
5. Naver Developers에서 네이버 로그인/캘린더/API 환경 확인
6. Android 기기 연결 후 `flutter run`

## 현재 검증 기준

- [x] `flutter analyze` 통과
- [x] `flutter test` 통과
- [x] Android debug APK build 통과
- [ ] 이번 v3/Android 보강분 GitHub `main` push
