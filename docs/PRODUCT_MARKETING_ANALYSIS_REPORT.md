# PlanFlow 제품 및 마케팅 분석 보고서

*생성일: 2026-07-10*  
*분석 기준: PlanFlow 코드베이스 v1.1.1+88*

---

## 요약

PlanFlow는 "말만 하면 알아서 정리되고, 준비할 시간까지 챙겨주는 AI 음성 일정 비서"로, Flutter 기반 Android-first 앱으로 개발되었습니다. 현재 183개의 Dart 파일로 구성되어 있으며, 개인 일정 관리와 그룹 일정 공유 기능을 모두 갖춘 상태입니다.

**핵심 차별점:**
- 자연어 음성 → AI 파싱 (단순 받아쓰기가 아닌 의미 이해)
- 역산 알림 (준비를 언제 시작해야 하는지 자동 계산)
- 이동 시간 버퍼 (출발 시각까지 고려한 알림)
- on-device STT (음성이 서버로 전송되지 않음)

---

## 1. 제품 개요

### 1.1 기본 정보
- **제품명**: PlanFlow
- **버전**: 1.1.1+88 (빌드 88)
- **플랫폼**: Flutter (Android-first, iOS 미지원)
- **백엔드**: Supabase (PostgreSQL + Auth + Storage)
- **AI**: GPT-4o-mini (비용 최적화)
- **코드 규모**: 183개 Dart 파일, 3,845줄 SQL 스키마

### 1.2 비즈니스 모델
**Freemium 구독 방식**
- **FREE**: 무료 (기본 기능)
- **PRO**: 4,900원/월
- **MASTER**: 9,900원/월
- **TEAM**: S(19,900원/3인), M(37,400원/6인), L(68,900원/12인)
- **BUSINESS**: 별도 견적

**1차 배포 전략**: 전체 무료 + Early Bird 이메일 수집  
**2차 배포 전략**: 유료화 적용 + Early Bird 쿠폰 발송

---

## 2. 구현 현황 분석

### 2.1 핵심 기능 구현 상태

#### ✅ 완전 구현된 기능

**1. 음성 입력 및 AI 파싱**
- `SttService`: on-device STT (speech_to_text 라이브러리)
- `VoiceCommandPipeline`: 음성 의도 분석 (add/edit/delete/query/choose)
- `VoiceCommandRouter`: 명령 라우팅
- `VoiceTextCleanupService`: 음성 텍스트 정리
- `VoiceCorrectionLearningService`: 사용자 맞춤 보정 학습
- `GptService`: GPT-4o-mini 기반 자연어 파싱

**2. 역산 알림 (Pre-action Reverse-calculation)**
- `EventPreparationService`: 일정 준비 시간 계산
- `SmartPreparationAlarmService`: 스마트 준비 알림
- `pre_actions` 테이블: 준비 사항 저장

**3. 이동 시간 버퍼**
- `DepartureAlarmService`: 출발 알림 스케줄링
- `TravelTimeBufferService`: 이동 시간 계산
- `LocationLookupService`: 위치 좌표 해석 (TMAP POI 검색)
- `MapService`: Google Maps/Naver Map 통합

**4. 캘린더 동기화**
- `CalendarSyncService`: 양방향 동기화 코어
- `DeviceCalendarService`: 기기 캘린더 접근
- `NaverCaldavService`: 네이버 캘린더 CalDAV 연동
- `NaverOpenApiCalendarService`: 네이버 오픈 API 백업
- `CalendarAutoSyncService`: 자동 동기화 스케줄러
- Google Calendar, Naver Calendar 양방향 지원

**5. 브리핑 기능**
- `BriefingSchedulerService`: 아침/저녁 브리핑 스케줄
- 아침/저녁 브리핑 화면 구현 완료
- TTS 기반 음성 브리핑

**6. 그룹 일정 관리 (V2 기능)**
- 24개 테이블 중 8개가 그룹 관련 (`groups`, `group_members`, `group_invites`, `group_role_delegations`, `group_events`, `group_event_comments`, `group_backups`)
- 그룹 생성/초대/멤버 관리
- 그룹 일정 공유/댓글
- 역할 위임 (delegation)
- 그룹 백업
- 홈 위젯 그룹 캘린더 오버레이

**7. 알림 시스템**
- `NotificationService`: Android 로컬 알림
- `AlarmService`: 정확한 시간 알람 (android_alarm_manager_plus)
- 다양한 알림 채널 (일정 알림, 출발 알림, 준비 알림, 브리핑)
- 채널 마이그레이션 서비스 포함

**8. 위젯**
- `HomeWidgetService`: 홈 위젯 업데이트
- 개인 캘린더 위젯
- 그룹 캘린더 위젯
- 음성 입력 바로가기

**9. 백업 & 복원**
- `BackupService`: 사용자 데이터 백업
- `user_backups`, `group_backups` 테이블
- 일일 자동 백업 스케줄러

**10. 진단 & 분석**
- `DiagLogger`: 진단 로그 수집
- `AnalyticsService`: 사용자 활동 추적
- `ActivityTrackingService`: 상세 활동 로그
- `TesterDashboardRepository`: 테스터 대시보드용 데이터

#### 🔧 부분 구현/개선 필요

**1. API 사용량 관리**
- `ApiUsageGuardService`: 레이트 리미트 가드 (TMAP POI API 60/60s 제한 대응)
- 현재 목적지 쿼리를 3개로 제한 (최대 18콜)

**2. 권한 관리**
- `AppPermissionService`: Android 권한 요청
- `BatteryOptimizationService`: 배터리 최적화 예외 요청
- 권한 온보딩 플로우 구현됨

**3. 외부 캘린더 가져오기**
- `NaverIcsImportService`: .ics 파일 가져오기
- `ExternalCalendarSyncGuideService`: 동기화 가이드
- `ExternalEventImportClassifier`: 외부 일정 분류

#### ⚠️ 2차 배포 예정 기능 (미구현)

**KakaoTalk/SMS 일정 감지** (Notification Listener API)
**통화 내용 일정 감지** (로컬 call-to-text)

→ 1차 배포에는 포함하지 않음 (권한 민감)

### 2.2 데이터베이스 스키마

**24개 테이블** (3,845줄 SQL)

**핵심 테이블:**
- `users`: 사용자 프로필, 초대 코드
- `events`: 개인 일정 (반복 일정 지원)
- `pre_actions`: 준비 사항
- `reminders`: 알림 설정
- `voice_logs`: 음성 입력 로그
- `location_history`: 위치 이력
- `user_settings`: 사용자 설정
- `voice_correction_rules`: 개인 음성 보정 규칙
- `voice_common_correction_rules`: 공통 음성 보정 규칙
- `calendar_connections`: 외부 캘린더 연결

**그룹 테이블:**
- `groups`: 그룹 정보
- `group_members`: 멤버 관리
- `group_invites`: 초대 링크
- `group_role_delegations`: 역할 위임
- `group_events`: 그룹 일정
- `group_event_comments`: 일정 댓글
- `group_backups`: 그룹 백업

**기타:**
- `user_backups`: 개인 백업
- `feedback_reports`: 피드백
- `admin_roles`: 관리자 역할
- `contact_messages`: 문의 메시지
- `product_early_birds`: Early Bird 이메일 수집
- `backup.daily_snapshots`: 일일 스냅샷

**RLS(Row Level Security)**: 모든 테이블에 활성화됨

### 2.3 기술 스택 상세

#### Flutter 패키지
**상태 관리**: flutter_riverpod (2.4.9)  
**라우팅**: go_router (13.2.0)  
**로컬 알림**: flutter_local_notifications (21.0.0)  
**알람**: android_alarm_manager_plus (5.0.0)  
**음성**: speech_to_text (7.3.0), flutter_tts (3.8.5)  
**지도**: google_maps_flutter (2.10.1), flutter_naver_map (1.4.4)  
**인증**: supabase_flutter (2.0.0), google_sign_in (6.2.1)  
**캘린더**: googleapis (12.0.0), googleapis_auth (1.4.1)  
**위젯**: home_widget (0.9.1)  
**기타**: package_info_plus, in_app_review, in_app_update, firebase_crashlytics, firebase_remote_config

#### 백엔드
**인증**: Supabase Auth (JWT, Google OAuth)  
**데이터베이스**: PostgreSQL (Supabase)  
**저장소**: Supabase Storage  
**AI**: GPT-4o-mini (OpenAI)

#### 외부 API
- **Google Calendar API**: 일정 동기화
- **Naver Calendar API**: CalDAV + Open API
- **TMAP POI API**: 위치 검색 (레이트 리미트: 60/60s)
- **Google Maps API**: 경로/이동시간
- **Naver Maps API**: 경로/이동시간 (백업)

---

## 3. 타겟 사용자 분석

### 3.1 주 타겟 (우선순위순)

**1순위: 약속·미팅이 많은 직장인**
- 외근, 영업, 미팅이 잦은 사람
- 이동 중 손 안 대고 음성 등록 니즈
- 출발 시각 계산이 핵심 가치

**2순위: 캘린더 입력이 귀찮아서 안 쓰는 사람**
- 입력 노동 제거가 핵심 후크
- "적기 귀찮아서 결국 안 쓰게 됨"

**3순위: 준비물·출발 시각을 자주 깜빡하는 사람**
- 역산 알림이 핵심 가치
- "또 늦겠다", "또 까먹었다" 스트레스

### 3.2 Jobs to be Done

**"일정 입력 노동에서 벗어나고 싶다"**
- 말 한마디로 끝내기
- 타이핑 스트레스 제거

**"약속에 늦거나 준비를 깜빡하고 싶지 않다"**
- 역산 알림이 대신 챙겨줌
- 이동 시간 버퍼 자동 계산

**"흩어진 일정을 한눈에 정리해서 마음 편하게 하루를 시작하고 싶다"**
- 아침/저녁 브리핑
- 음성으로 듣는 하루 일정

### 3.3 구체적 시나리오

**운전 중**
- "다음 주 화요일 3시 강남에서 김부장 미팅"
- → 자동 등록 + 이동시간 고려 출발 알림

**반복 일정**
- "내일 아침 약 먹기"
- → 반복 알림 등록

**그룹 일정**
- "이번 주 토요일 팀 워크샵"
- → 팀원 전체에게 공유

### 3.4 Anti-persona

❌ 일정이 거의 없는 사람  
❌ 종이 다이어리로 충분히 만족하는 사람  
❌ 음성 인터페이스를 신뢰하지 않는 사람

---

## 4. 경쟁 환경 분석

### 4.1 핵심 포지셔닝

**"또 다른 일정앱"이 아닙니다**

사용자는 TimeTree, Siri 같은 일정앱을 경쟁으로 인식하지 않습니다.  
진짜 경쟁은:
1. **기본 캘린더** (입력 노동)
2. **아날로그 습관** (카톡 나에게 보내기, 종이 다이어리, 머릿속 기억)

→ "캘린더를 안 쓰게 만드는 근본 원인(입력 귀찮음)을 없앤다"

### 4.2 경쟁 대체재

| 대체재 | 문제점 | PlanFlow 해결 |
|--------|--------|---------------|
| 구글/네이버 캘린더 | 타이핑 입력 귀찮음 | 음성 한마디로 등록 |
| 카톡 나에게 보내기 | 알림 없음, 검색 불편 | 자동 알림, 구조화된 일정 |
| 종이 다이어리 | 알림 없음, 휴대 불편 | 스마트폰 항상 소지 |
| 머릿속 기억 | 깜빡함 | AI가 대신 기억 |

### 4.3 차별화 요소

**기능 차별화:**
- ✅ 자연어 이해 (단순 받아쓰기 X)
- ✅ 역산 알림 (준비 시간 자동 계산)
- ✅ 이동 시간 버퍼 (TMAP/Google Maps 연동)
- ✅ on-device STT (프라이버시)
- ✅ 그룹 일정 공유 (역할 위임까지)

**경험 차별화:**
- "기록" 도구 → "챙겨주는" 비서
- "내 편인 앱" 철학

### 4.4 시장 기회

**한국 시장에 음성+AI파싱+역산알림을 결합한 직접 경쟁이 뚜렷하지 않음**  
→ **카테고리 선점 기회**

---

## 5. 마케팅 전략 분석

### 5.1 고객 언어 (Customer Language)

**⚠️ 중요: 실제 테스터 피드백으로 채워야 함**

**문제를 표현하는 말 (추정):**
- "적기 귀찮아서 안 쓰게 돼요"
- "맨날 깜빡해요"
- "또 늦었어"

**해결을 표현하는 말 (추정):**
- "말만 하면 되니까 편해요"

**사용할 단어:**
- 챙겨주다, 알아서, 편하게, 말만 하면, 내 편

**피해야 할 단어:**
- 생산성 극대화, 효율, 관리 (딱딱한 톤)
- B2B 느낌의 용어

### 5.2 브랜드 보이스

**Tone**: 따뜻하고, 부담 없고, 챙겨주는 (잔소리 아님)  
**Style**: 대화체, 친근, 솔직 (과장 광고 톤 금지)  
**Personality**: 다정한 / 든든한 / 똑똑한 / 편안한 / 진솔한

### 5.3 핵심 메시지

**One-liner**:  
"말만 하면 알아서 정리되고, 준비할 시간까지 챙겨주는 AI 음성 일정 비서"

**Value Propositions:**
1. 입력 부담 0 → 말만 하면 끝
2. 늦을 걱정 0 → 준비/출발 시각까지 챙겨줌
3. 프라이버시 보호 → 음성이 서버로 안 나감
4. 기존 캘린더와 동기화 → 대체가 아닌 보완

### 5.4 Objections & Responses

| 반대 의견 | 대응 |
|-----------|------|
| 음성 인식 정확도 못 믿겠다 | on-device STT + AI 파싱, 등록 전 확인 UI로 교정 가능 |
| 또 다른 일정 앱일 뿐 | 기존 캘린더와 양방향 동기화, 대체 아닌 보완 |
| 음성 데이터 프라이버시 걱정 | 음성은 기기 안에서만 처리, 서버 전송 안 함 |

### 5.5 Switching Dynamics

**Push (밀어내는 힘)**:
- 캘린더 입력이 귀찮아서 안 쓰게 됨
- 자꾸 약속/준비를 깜빡함

**Pull (당기는 힘)**:
- 말만 하면 끝
- 준비 타이밍까지 챙겨주는 편안함

**Habit (기존 습관)**:
- 머릿속으로 기억
- 카톡 나에게 보내기
- 기본 캘린더

**Anxiety (불안)**:
- 음성 인식이 틀리면?
- 또 새 앱 배우기 귀찮은데?
- 내 일정 데이터 안전한가?

---

## 6. 출시 전략

### 6.1 1차 배포 (Public Beta)

**목표**: 사용자 확보 + Early Bird 이메일 수집

**전략**:
- ✅ 전체 기능 무료 제공
- ✅ Early Bird 이메일 수집 (PRO 쿠폰 약속)
- ✅ 테스터 피드백 수집
- ✅ 버그 수정 및 안정화

**핵심 지표**:
- 일정 음성 등록 첫 성공률 (활성화)
- Early Bird 이메일 수집 수
- 일 활성 사용자 (DAU)
- 평균 일정 등록 수

### 6.2 2차 배포 (정식 출시)

**목표**: PRO 구독 전환

**전략**:
- ✅ 유료화 적용
- ✅ Early Bird 쿠폰 발송
- ✅ 권한 민감 기능 추가 (KakaoTalk/SMS/통화 감지)
- ✅ 명시적 온보딩 + 개별 토글

**핵심 지표**:
- PRO 전환율
- 월간 반복 매출 (MRR)
- 이탈률 (Churn)
- NPS (Net Promoter Score)

### 6.3 마케팅 채널

**초기 (비공개 테스트)**:
- ✅ 지인 네트워크
- ✅ 테스터 모집 (온라인 커뮤니티)

**1차 배포**:
- Google Play 스토어 ASO
- 네이버 블로그/카페
- 페이스북/인스타그램 광고
- 지역 커뮤니티 (외근/영업 직장인)

**2차 배포 이후**:
- 앱 리뷰 사이트 제휴
- 인플루언서 협업 (생산성 유튜버)
- B2B 팀 플랜 마케팅 (LinkedIn, 스타트업 커뮤니티)

---

## 7. 리스크 & 개선 과제

### 7.1 기술 리스크

**1. API 레이트 리미트**
- TMAP POI API: 60/60s 제한
- 현재 쿼리 3개로 제한 (최대 18콜)
- **개선**: 캐싱 강화, 사용자 위치 기반 우선순위

**2. 음성 인식 정확도**
- on-device STT 한계
- 방언, 전문 용어 인식 어려움
- **개선**: 사용자 맞춤 보정 학습 (voice_correction_rules)

**3. 배터리 소모**
- 백그라운드 알람, 위치 추적
- **개선**: 배터리 최적화 예외 요청, 효율적 스케줄링

### 7.2 사용자 경험 리스크

**1. 음성 입력 학습 곡선**
- 처음 사용자는 어떻게 말해야 할지 모를 수 있음
- **개선**: 온보딩 튜토리얼, 예시 문구 제공

**2. 권한 요청 피로**
- 알림, 위치, 캘린더, 정확한 알람 등 다수 권한
- **개선**: 단계별 권한 요청, 명확한 이유 설명

**3. 기존 캘린더와의 동기화 혼란**
- 중복 일정, 삭제 동기화 실패 등
- **개선**: 동기화 상태 명확히 표시, 충돌 해결 UI

### 7.3 비즈니스 리스크

**1. 무료→유료 전환율**
- 1차 배포에서 전체 무료 → 2차에서 유료화
- 사용자 반발 가능성
- **개선**: Early Bird 쿠폰, 충분한 무료 기능 유지

**2. 경쟁 진입**
- 카카오, 네이버 등 대형 플랫폼의 유사 기능 추가 가능
- **개선**: 빠른 시장 선점, 커뮤니티 구축, 차별화된 경험

**3. iOS 미지원**
- 한국 시장 iOS 점유율 ~30%
- **개선**: Android 검증 후 iOS 개발 (Stage 3)

### 7.4 개선 과제

**단기 (1~3개월)**:
- [ ] 테스터 피드백 기반 UX 개선
- [ ] 음성 인식 정확도 개선 (보정 규칙 확대)
- [ ] API 레이트 리미트 최적화
- [ ] ASO (앱 스토어 최적화)

**중기 (3~6개월)**:
- [ ] 2차 배포 (유료화)
- [ ] KakaoTalk/SMS 일정 감지 추가
- [ ] B2B 팀 플랜 강화
- [ ] 인플루언서 마케팅

**장기 (6~12개월)**:
- [ ] iOS 앱 개발
- [ ] 웹 버전 (캘린더 뷰)
- [ ] AI 음성 비서 고도화 (대화형 인터페이스)
- [ ] 글로벌 시장 진출 (영어 버전)

---

## 8. 데이터 기반 의사결정 준비

### 8.1 필수 측정 지표

**활성화 지표**:
- 첫 음성 등록 성공률
- 첫 알림 수신률
- 7일 유지율 (7-day retention)

**참여 지표**:
- DAU/WAU/MAU
- 평균 일정 등록 수/주
- 음성 입력 vs 수동 입력 비율
- 브리핑 청취율

**전환 지표**:
- Early Bird 이메일 수집률
- 무료→PRO 전환율
- 이탈률 (Churn)

**만족도 지표**:
- NPS (Net Promoter Score)
- 앱 스토어 평점
- 피드백 제출 수

### 8.2 현재 구축된 분석 인프라

✅ `AnalyticsService`: 사용자 활동 추적  
✅ `ActivityTrackingService`: 상세 활동 로그  
✅ `TesterDashboardRepository`: 테스터 대시보드  
✅ `voice_logs`, `location_history` 테이블: 사용 로그  
✅ Firebase Crashlytics: 충돌 리포트  
✅ Firebase Remote Config: A/B 테스트 준비

### 8.3 A/B 테스트 후보

**온보딩**:
- 음성 입력 튜토리얼 vs 바로 시작
- 권한 요청 순서 (알림 먼저 vs 위치 먼저)

**음성 입력**:
- 자동 시작 vs 버튼 탭
- 확인 UI 스타일 (간단 vs 상세)

**알림**:
- 출발 알림 기본 여유 시간 (10분 vs 20분 vs 30분)
- 브리핑 기본 시간 (아침 7시 vs 8시)

**가격**:
- PRO 가격 (4,900원 vs 5,900원)
- 무료 기능 범위

---

## 9. 결론 및 권장사항

### 9.1 강점

✅ **완성도 높은 코어 기능**: 음성 입력, AI 파싱, 역산 알림, 이동 시간 버퍼 모두 구현 완료  
✅ **차별화된 가치**: "입력 노동 제거" + "늦지 않게 챙겨주기"  
✅ **프라이버시 우선**: on-device STT  
✅ **그룹 기능까지 완성**: 개인→팀 확장 가능  
✅ **탄탄한 인프라**: Supabase + RLS, 백업, 진단, 분석 모두 구축됨

### 9.2 약점

⚠️ **고객 언어 부족**: 실제 테스터 피드백(verbatim) 기반 메시지 필요  
⚠️ **iOS 미지원**: 한국 시장 ~30% 잠재 고객 제외  
⚠️ **API 레이트 리미트**: TMAP POI 제한으로 일부 사용자 경험 저하 가능  
⚠️ **무료→유료 전환**: 2차 배포에서 반발 리스크

### 9.3 기회

📈 **카테고리 선점**: 한국 시장에 직접 경쟁 없음  
📈 **코로나 이후 이동 재개**: 외근/미팅 증가, 출발 알림 니즈 ↑  
📈 **AI 트렌드**: "AI 비서" 키워드 관심도 상승  
📈 **팀 플랜**: B2B 시장 확장 가능

### 9.4 위협

🚨 **대형 플랫폼 진입**: 카카오/네이버가 유사 기능 추가 가능  
🚨 **음성 UI 거부감**: 일부 사용자는 타이핑 선호  
🚨 **경쟁 심화**: TimeTree, Skedda 등 기존 플레이어 강화

### 9.5 권장 Next Steps

**즉시 (1주)**:
1. 비공개 테스터 피드백 수집 (verbatim 인용)
2. 고객 언어로 ASO 키워드 최적화
3. 온보딩 플로우 UX 테스트

**단기 (1개월)**:
1. 1차 배포 (전체 무료 + Early Bird)
2. 초기 사용자 활성화 모니터링
3. 핵심 지표 대시보드 구축

**중기 (3개월)**:
1. 사용 데이터 기반 개선
2. 2차 배포 준비 (유료화 전략 확정)
3. 마케팅 채널 테스트 (페이스북 광고, 블로그)

**장기 (6개월)**:
1. iOS 앱 개발 착수
2. B2B 팀 플랜 고도화
3. 글로벌 진출 검토

---

## 부록

### A. 기술 아키텍처 요약

**클라이언트**: Flutter (Dart) + Riverpod + GoRouter  
**백엔드**: Supabase (PostgreSQL + Auth + Storage)  
**AI**: GPT-4o-mini (OpenAI)  
**지도**: Google Maps + Naver Maps  
**위치 검색**: TMAP POI API  
**캘린더**: Google Calendar API + Naver CalDAV  
**음성**: speech_to_text (on-device) + flutter_tts  
**알림**: android_alarm_manager_plus + flutter_local_notifications  
**분석**: Firebase Crashlytics + Remote Config + 자체 로그

### B. 주요 서비스 목록

**음성**: SttService, VoiceCommandPipeline, VoiceCommandRouter, GptService  
**일정**: EventRepository, EventPreparationService, EventRefreshBus  
**알림**: AlarmService, NotificationService, DepartureAlarmService, SmartPreparationAlarmService  
**위치**: LocationLookupService, MapService, TravelTimeBufferService  
**캘린더**: CalendarSyncService, DeviceCalendarService, NaverCaldavService  
**브리핑**: BriefingSchedulerService, TtsService  
**그룹**: GroupRepository, GroupEventRepository, GroupInviteService  
**백업**: BackupService, DailyBackupSchedulerService  
**진단**: DiagLogger, AnalyticsService, ActivityTrackingService

### C. 참고 문서

- `.agents/product-marketing-context.md`: 기존 마케팅 컨텍스트
- `pubspec.yaml`: 패키지 의존성
- `supabase/schema.sql`: 데이터베이스 스키마
- `lib/core/constants.dart`: 상수 정의
- `lib/core/env.dart`: 환경 변수

---

**이 보고서는 2026-07-10 기준 PlanFlow 코드베이스를 직접 조사하여 작성되었습니다.**  
**실제 테스터 피드백, 사용 데이터, 시장 조사 결과를 반영하여 지속적으로 업데이트해야 합니다.**
