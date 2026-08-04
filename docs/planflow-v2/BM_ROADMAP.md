# PlanFlow 1차 BM(Business Model) 로드맵

이 문서는 PlanFlow 1차 출시에서 시작해 2차 BM으로 이어지는 수익 모델의
로드맵을 정리한 문서다. 1차 출시 정책(전체 무료, 광고 금지)과 충돌하지 않는
범위에서 `rewarded_ad` 제도를 통한 매출화를 점진적으로 적용한다.

## 1차 출시 (현재 진행)

### 1.1 무료 모델 — 핵심 BM
- 1차 출시 전 기능은 **전체 무료** 제공 (AGENTS.md 금지 정책).
- 결제는 의도적으로 코드에 포함하지 않는다.
- 광고는 **기본 OFF** (Remote Config `rewarded_ad_enabled = false`).

### 1.2 광고 실험 (사용자 동의 기반)
- 대상: GPT 일정 파싱 (음성 → 일정 변환)
- 형태: 사용자가 명시적으로 "광고 보고 분석하기" 선택 시 리워드 광고 1편
- 미시청/실패 시: 광고 없이 수동 입력으로 fallback (기본 기능 차단 X)
- 정책: 배너/네이티브/인터스티셜/자동재생/강제 광고 **금지**
- Remote Config 마스터 스위치: `rewarded_ad_enabled` (default false)
- 운영 ID: `rewarded_ad_unit_id_android` (Remote Config, 코드 미포함)

### 1.3 그룹 백업/복원 (이번 작업)
- 그룹 삭제 전 자동 백업 (스냅샷: 그룹+멤버+이벤트+댓글+권한위임+초대+개인↔그룹 일정 연결)
- 보관 기간: 30일 (Remote Config `group_backup_retention_days`)
- 동일 사용자가 만든 backup RLS 강제 (created_by = auth.uid())
- 감사 보존: 복원된 백업은 영구 삭제 불가 (`restored_at IS NOT NULL` 체크)

## 2차 BM (이후)

### 2.1 PRO/팀 구독 (구현 보류, 의사결정 필요)
- 의도: 도입부 결제로 1차 무료 사용자 중 일반화 가능한 가치를 지불할 의사가
  있는 사용자만 전환. 팀/가족 단위 결제자.
- 후보 모델: 월 정액 (KRW 3,900 / KRW 6,900) 또는 가족 6인 풀 (KRW 9,900)
- **1차 출시 코드에 billing SDK/결제 의존성 포함 금지** (AGENTS.md).
- 활성화 시점: `BUILD_FOR_PRO=true` 환경 변수 + Remote Config `pro_enabled` 동시 ON.

### 2.2 광고 채우기 (1차의 점진적 확대)
- 1차와 동일 정책 강제: 선택형 리워드, 강제 금지, 1회/기능.
- 가능한 신규 대상 (제품 분석 후 결정):
  - AI 일정 추천 (예: "이번 주 빈 시간에 운동 추가할까요?")
  - 캘린더 자동 동기화 브리핑
  - 일정 충돌 해결 제안
- 절대 추가 금지: 일정 CRUD, 기본 알림, 캘린더 조회, 개인 데이터 복원, 로그인/계정/설정.
- 정책 변경 시 새로 evaluator 작성 (현재 `analytics_service.dart` 광고 이벤트 명세).

### 2.3 그룹 백업 보관 정책 확장
- 보관 만료 백업 자동 삭제 (현재: 사용자 수동 영구 삭제만).
- "팀 단위 백업" (가족 단위 PRO 가입 시 멤버 머지).
- 클라우드 외부 백업 export (Google Drive / iCloud) — 보안 검토 후.

## 보류 과제 (CEO 결정 필요)

1. **운영 광고 ID 발급**: AdMob 콘솔에서 단위 ID 발급 후 Remote Config 등록.
2. **AdMob 앱 등록**: Android 앱 등록 + 결제 프로필 연결 (수익금 출금용).
3. **개인정보처리방침**: `docs/privacy-policy.md`에 AdMob UMP, 광고 데이터 항목 추가.
4. **Play Console 데이터 안전**: ads SDK 사용 사실 + 데이터 외부 전송 명시.
5. **구독 모델 가격**: KRW 3,900/6,900/9,900 중 어느 묶음을 1차에 노출할지.
6. **광고 OFF → ON 시점**: 출시 후 사용자 지표(리텐션·DAU)를 보고 결정.

## 참고 파일 위치

- 광고 코드
  - `lib/services/ad_service.dart` — 광고 로드/표시 (5.2.0 dynamic 호출 격리)
  - `lib/services/ad_consent_service.dart` — GDPR/EEA UMP 동의
  - `lib/services/ad_reward_state.dart` — 보상 상태 영속 저장
  - `lib/widgets/rewarded_ad_dialog.dart` — "광고 보고 분석하기" 다이얼로그
  - `lib/core/analytics_service.dart` — 광고 이벤트 10종
- 그룹 백업/복원
  - `supabase/migrations/20260804000000_group_restore_support.sql` — RPC 4종 + RLS
  - `lib/features/groups/repositories/group_backup_repository.dart`
  - `lib/features/groups/screens/deleted_groups_screen.dart`
  - `lib/features/groups/providers/deleted_groups_provider.dart`
- 정책
  - `lib/services/remote_config_service.dart` — kill-switch 키
  - `android/app/src/main/AndroidManifest.xml` — AdMob app ID(테스트 placeholder)
