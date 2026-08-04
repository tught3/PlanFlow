# PlanFlow 음성 대화 모드 광고 게이트 — 수정 설계 지시서

> ⚠️ 이 문서는 설계·파일 변경 범위·정책 흐름·테스트 계획을 먼저 보고하기 위한 것이다.
> 승인 전에는 구현하지 마.

---

## 배경

PlanFlow는 Flutter + Supabase 기반 Android 일정 관리 앱이다.
음성 대화 모드(멀티턴 연속 음성 조작)가 완성돼 있으나
직전 감사에서 성공률과 자연어 이해 범위가 충분히 검증되지 않았다.

따라서 다음 구조로 구현한다:
- 홈에 명시적 "대화 모드" 버튼 추가
- 최초 N회(기본 3회)는 광고 없이 무료 체험
- 무료 체험 소진 후 리워드 광고 제안
- 무료 체험 횟수는 Remote Config로 조절 가능
- 기존 단발 음성 입력과 자동 라우팅은 절대 건드리지 않음

---

## STEP 0 — 보고 먼저 (구현 전)

아래 항목을 조사해서 먼저 보고해. 승인 후 구현 진행.

### 0-1. 환경 확인 및 패키지 버전 선정

현재 프로젝트의 아래 항목을 확인해:
```
- Flutter SDK 버전 (flutter --version)
- Dart SDK 버전
- android/app/build.gradle.kts의 compileSdk, minSdk, targetSdk
- Android Gradle Plugin 버전
- 현재 pubspec.yaml의 google_mobile_ads 버전 (있으면)
- 현재 pubspec.yaml의 firebase_core 버전 (있으면)
```

확인 후:
- pub.dev에서 google_mobile_ads 공식 최신 버전 확인
- 현재 환경과 호환 가능한 버전 선정
- 선정 근거 (minSdk 요구사항, Dart 호환성, AGP 호환성)
- 마이그레이션 위험 항목 명시
- `^4.0.0`은 사용하지 말 것 — 환경 확인 후 적합한 버전 직접 선정

### 0-2. 변경 파일 범위 보고

구현 전에 변경이 필요한 파일 목록을 먼저 보고:
```
신규 생성 파일:
- lib/services/reward_ad_service.dart
- lib/services/ump_service.dart
- lib/services/voice_ad_gate_service.dart
- lib/services/voice_conversation_analytics_service.dart
- (보상 DB 필요 시) supabase/migrations/reward_usages.sql

수정 파일:
- pubspec.yaml
- AndroidManifest.xml
- lib/screens/home/home_screen.dart
- lib/screens/settings/settings_screen.dart
- main.dart
- (기타 확인된 파일)
```

### 0-3. 기존 기능 회귀 위험 보고

다음 기존 동작이 변경되지 않음을 확인하고 보고:
- 홈 마이크 버튼 → 단발 음성 입력 (무료, 변경 없음)
- query intent 자동 라우팅 → voice_conversation_screen (변경 없음)
- 기존 딥링크 planflow://voice-conversation (변경 없음)

회귀 위험이 있는 부분이 있으면 명시.

---

## STEP 1 — Remote Config 키 정의

Firebase Remote Config에 아래 키를 추가:

```
# 대화 모드 전체 활성화 여부
voice_conversation_button_enabled: true (bool)
→ false 시 홈에 대화 모드 버튼 자체를 숨김

# 광고 게이트 활성화 여부
reward_ad_enabled: false (bool, 기본 OFF)
→ false 시 광고 없이 바로 대화 모드 진입

# 기능별 광고 토글
reward_ad_voice_conversation_enabled: false (bool, 기본 OFF)

# 무료 체험 횟수
voice_conversation_free_trial_count: 3 (int)
→ 0으로 설정 시 첫 번째 사용부터 광고
→ 99로 설정 시 사실상 무제한 무료

# 광고 실패 시 free pass 여부
reward_ad_failure_free_pass: true (bool)
→ true: 광고 로드/표시 실패 시 대화 모드 바로 진입
→ false: 광고 실패 시 진입 차단
```

---

## STEP 2 — 무료 체험 카운터

광고 인프라 없이 무료 체험 횟수만 관리.
복잡한 서버 상태 없이 로컬 저장으로 충분.

```dart
// lib/services/voice_trial_service.dart

class VoiceTrialService {
  static const String _key = 'voice_conversation_used_count';

  // 사용 횟수 조회
  static Future<int> getUsedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key) ?? 0;
  }

  // 무료 체험 남아있는지 확인
  static Future<bool> hasFreeTrial(int freeTrialCount) async {
    final used = await getUsedCount();
    return used < freeTrialCount;
  }

  // 사용 횟수 증가
  static Future<void> incrementUsed() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_key) ?? 0;
    await prefs.setInt(_key, current + 1);
  }

  // 초기화 (테스트용, Remote Config로 조작 가능하게)
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
```

---

## STEP 3 — UMP 구현 (공식 Flutter 흐름)

### 원칙
- 앱 실행마다 consent info update
- 필요한 폼 자동 표시
- `canRequestAds()`가 true일 때만 광고 로드
- 동의 오류 시 임의로 비개인화 광고 요청 금지
- 설정 화면에서 개인정보 선택지 재진입 가능

```dart
// lib/services/ump_service.dart

class UmpService {
  static bool _canRequestAds = false;
  static bool get canRequestAds => _canRequestAds;

  // 앱 시작 시 호출
  static Future<void> initialize() async {
    final params = ConsentRequestParameters();

    final completer = Completer<void>();

    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () async {
        // 폼 필요 여부 확인
        if (await ConsentInformation.instance.isConsentFormAvailable()) {
          final status = ConsentInformation.instance.consentStatus;
          if (status == ConsentStatus.required) {
            await _showConsentForm();
          }
        }
        // canRequestAds 업데이트
        _canRequestAds = await ConsentInformation.instance.canRequestAds();
        completer.complete();
      },
      (error) {
        // 오류 시 광고 요청 불가 상태 유지 (비개인화 광고 임의 요청 금지)
        _canRequestAds = false;
        completer.complete();
      },
    );

    await completer.future;
  }

  // 폼 표시
  static Future<void> _showConsentForm() async {
    final completer = Completer<void>();
    ConsentForm.loadConsentForm(
      (form) {
        form.show((error) {
          completer.complete();
        });
      },
      (error) {
        completer.complete();
      },
    );
    await completer.future;
    _canRequestAds = await ConsentInformation.instance.canRequestAds();
  }

  // 설정 화면에서 개인정보 선택지 재진입
  static Future<void> showPrivacyOptionsForm(BuildContext context) async {
    final status = await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
    if (status == PrivacyOptionsRequirementStatus.required) {
      ConsentForm.showPrivacyOptionsForm(context, (error) {
        if (error != null) {
          // 오류 처리
        }
      });
    }
  }
}
```

### main.dart 호출 순서
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(...);
  await Firebase.initializeApp(...);
  await UmpService.initialize(); // UMP 먼저
  // canRequestAds == true 일 때만 AdMob 초기화
  if (UmpService.canRequestAds) {
    await MobileAds.instance.initialize();
  }
  runApp(const ProviderScope(child: PlanFlowApp()));
}
```

---

## STEP 4 — 광고 서비스

### 원칙
- `UmpService.canRequestAds`가 true일 때만 광고 로드
- 광고 로드/표시 실패와 사용자 거절을 반드시 구분
- 중복 초기화/요청 방지

```dart
// lib/services/reward_ad_service.dart

enum AdResult {
  rewarded,      // 광고 완료 → 대화 모드 진입 가능
  userCancelled, // 사용자가 광고 안내 취소 또는 보상 전 종료 → 진입 불가
  failed,        // 광고 로드/표시 실패 → Remote Config 정책에 따라 처리
  notAvailable,  // canRequestAds false 또는 kill switch OFF
}

class RewardAdService {
  RewardedAd? _rewardedAd;
  bool _isLoading = false;
  bool _isLoaded = false;

  // 광고 미리 로드 (canRequestAds 확인 후)
  Future<void> loadAd(String adUnitId) async {
    if (!UmpService.canRequestAds) return;
    if (_isLoading || _isLoaded) return;
    _isLoading = true;

    await RewardedAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _isLoaded = true;
          _isLoading = false;
        },
        onAdFailedToLoad: (error) {
          _isLoaded = false;
          _isLoading = false;
        },
      ),
    );
  }

  // 광고 표시
  Future<AdResult> showAd() async {
    if (!UmpService.canRequestAds) return AdResult.notAvailable;
    if (!_isLoaded || _rewardedAd == null) return AdResult.failed;

    final completer = Completer<AdResult>();
    bool rewardEarned = false;

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _isLoaded = false;
        _rewardedAd = null;
        // 보상 받기 전 종료 = 사용자 취소
        if (!rewardEarned) {
          completer.complete(AdResult.userCancelled);
        }
        loadAd(_adUnitId); // 다음 광고 미리 로드
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _isLoaded = false;
        _rewardedAd = null;
        completer.complete(AdResult.failed);
      },
    );

    await _rewardedAd!.show(
      onUserEarnedReward: (ad, reward) {
        rewardEarned = true;
        completer.complete(AdResult.rewarded);
      },
    );

    return completer.future;
  }
}
```

---

## STEP 5 — 광고 게이트 흐름

### 진입 흐름 (사용자가 "대화 모드" 버튼 탭)

```
버튼 탭
    ↓
voice_conversation_button_enabled 확인
  → false: 버튼 숨김 (여기까지 안 옴)
    ↓
무료 체험 남아있는지 확인
  (used_count < voice_conversation_free_trial_count)
  → 남아있음: 무료 체험 카운터 증가 → 대화 모드 바로 진입
    ↓
reward_ad_enabled 확인
  → false (kill switch OFF): 광고 코드 경로 없이 바로 진입
    ↓
reward_ad_voice_conversation_enabled 확인
  → false: 광고 없이 바로 진입
    ↓
UmpService.canRequestAds 확인
  → false: AdResult.notAvailable
       → reward_ad_failure_free_pass == true: 바로 진입
       → false: 진입 불가 (안내 메시지 표시)
    ↓
광고 로드 여부 확인
  → 미로드: AdResult.failed
       → reward_ad_failure_free_pass == true: 바로 진입
       → false: 진입 불가
    ↓
광고 안내 다이얼로그 표시:
"AI와 대화하며 일정을 관리할 수 있어요.
 짧은 광고를 시청하면 바로 시작할 수 있어요."
[광고 보고 시작하기] [취소]
    ↓
[취소] → 진입 불가 (AdResult.userCancelled)
    ↓
광고 표시
    ↓
보상 받기 전 광고 종료 → AdResult.userCancelled → 진입 불가
    ↓
AdResult.rewarded → 대화 모드 진입
AdResult.failed → reward_ad_failure_free_pass 정책 따름
```

### 광고 실패 vs 사용자 거절 구분 원칙
```
AdResult.rewarded      → 대화 모드 진입 ✅
AdResult.failed        → Remote Config(reward_ad_failure_free_pass)에 따라
AdResult.userCancelled → 진입 불가 ❌ (안내 없이 그냥 닫힘)
AdResult.notAvailable  → Remote Config(reward_ad_failure_free_pass)에 따라
```

---

## STEP 6 — 보상 DB 필요 여부 판단

### 판단 기준

대화 모드 진입은 즉시 이루어지는 작업이므로
1차에는 복잡한 보상 상태 시스템이 필요하지 않다.

**로컬만으로 충분한 이유:**
- 광고 완료 → 즉시 화면 진입 (보상 복구 필요 없음)
- 보상 가치가 크레딧/재화가 아니라 "화면 진입 1회"
- 앱 종료 후 보상 복구가 필요한 시나리오:
  광고 완료 → 앱 강제 종료 → 재실행 후 대화 모드 진입?
  → 이 경우 사용자는 그냥 다시 광고 보면 됨
  → 복구 필요성 낮음

**보상 DB가 필요해지는 시점:**
- 광고 횟수 기반 일일 한도가 필요할 때
- SSV(서버 측 검증)가 필요할 때
- 보상을 크레딧으로 적립할 때

**1차 결론: 로컬 SharedPreferences로 충분. Supabase reward_usages 테이블 불필요.**

### 만약 보상 DB가 나중에 필요해지면 반드시 포함해야 할 것

```sql
-- p_user_id 파라미터 받지 않고 auth.uid() 사용
-- SECURITY DEFINER + search_path 고정
-- 직접 INSERT 차단 (RPC로만)
-- INSERT/UPDATE WITH CHECK 정책
-- feature_key CHECK 제약
-- status CHECK 제약 ('granted', 'consumed', 'expired')
-- request_id UNIQUE 제약
-- 원자적 consume (UPDATE affected rows 확인)
-- 일일 제한 동시성 보장
-- 클라이언트 콜백으로 광고 완료 검증 불가 한계 명시
-- 필요 시 AdMob SSV 설계
```

---

## STEP 7 — 분석 이벤트 (개인정보 없이)

Firebase Analytics로 아래 이벤트만 기록. 일정 제목·장소·메모 등 개인정보 절대 포함 금지.

```dart
// lib/services/voice_conversation_analytics_service.dart

class VoiceConversationAnalytics {

  // 대화 모드 버튼 노출
  static Future<void> logButtonShown() async =>
      _log('vc_button_shown');

  // 대화 모드 버튼 탭
  static Future<void> logButtonTapped() async =>
      _log('vc_button_tapped');

  // 무료 체험 사용
  static Future<void> logFreeTrialUsed(int remainingCount) async =>
      _log('vc_free_trial_used', {'remaining': remainingCount});

  // 무료 체험 소진
  static Future<void> logFreeTrialExhausted() async =>
      _log('vc_free_trial_exhausted');

  // 광고 안내 노출
  static Future<void> logAdPromptShown() async =>
      _log('vc_ad_prompt_shown');

  // 광고 선택 (시청하기 탭)
  static Future<void> logAdChosen() async =>
      _log('vc_ad_chosen');

  // 광고 취소 (안내에서 취소)
  static Future<void> logAdCancelled() async =>
      _log('vc_ad_cancelled');

  // 광고 완료
  static Future<void> logAdCompleted() async =>
      _log('vc_ad_completed');

  // 광고 실패
  static Future<void> logAdFailed(String reason) async =>
      _log('vc_ad_failed', {'reason': reason});

  // 대화 시작 (화면 진입)
  static Future<void> logConversationStarted(String entryType) async =>
      _log('vc_started', {'entry_type': entryType});
      // entry_type: 'free_trial' | 'ad_rewarded' | 'kill_switch_off' | 'failure_free_pass'

  // 명령 완료
  static Future<void> logCommandCompleted(String intentType) async =>
      _log('vc_command_completed', {'intent_type': intentType});
      // intent_type: 'add' | 'edit' | 'delete' | 'query' 등 (개인정보 제외)

  // 재질의 발생
  static Future<void> logRephrase() async =>
      _log('vc_rephrase');

  // 오류 발생
  static Future<void> logError(String errorType) async =>
      _log('vc_error', {'error_type': errorType});

  // 포기 (사용자가 대화 중 나감)
  static Future<void> logAbandoned(int commandCount) async =>
      _log('vc_abandoned', {'command_count': commandCount});

  // 광고 후 대화 작업 완료
  static Future<void> logPostAdTaskCompleted() async =>
      _log('vc_post_ad_task_completed');

  static Future<void> _log(String name, [Map<String, Object>? params]) async {
    await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
  }
}
```

---

## STEP 8 — 품질 게이트 운영 원칙

운영 광고 활성화 전 대화 모드 품질을 확인한다.

### 품질 확인 지표 (분석 이벤트 기반)
```
완료율 = vc_command_completed / vc_started
재질의율 = vc_rephrase / vc_command_completed
포기율 = vc_abandoned / vc_started
```

### 광고 활성화 기준 (예시, 실제 수치는 운영 중 결정)
```
완료율 > 70%
재질의율 < 30%
포기율 < 20%
```

### Remote Config 운영 시나리오
```
품질 미달 시:
1. reward_ad_voice_conversation_enabled: false (광고 게이트만 비활성)
   → 버튼은 보이고 무료로 계속 사용 가능

2. voice_conversation_button_enabled: false (버튼 자체 숨김)
   → 대화 모드 완전 비활성

3. voice_conversation_free_trial_count: 99 (무제한 무료)
   → 광고 없이 계속 체험 가능

품질 달성 시:
1. reward_ad_enabled: true
2. reward_ad_voice_conversation_enabled: true
→ 무료 체험 소진 사용자부터 광고 게이트 활성
```

---

## STEP 9 — 홈 화면 버튼 추가

```
위치: 기존 마이크 FAB 근처 또는 홈 화면 상단 퀵액션 영역
디자인: 기존 PlanFlow 디자인 시스템 따를 것
텍스트: "대화 모드" 또는 "AI 대화"

Remote Config voice_conversation_button_enabled == false 시
버튼 자체를 렌더링하지 않음 (숨김 처리)

버튼 노출 시 VoiceConversationAnalytics.logButtonShown() 호출
버튼 탭 시 VoiceConversationAnalytics.logButtonTapped() 호출
이후 STEP 5 광고 게이트 흐름 진행
```

---

## STEP 10 — 설정 화면 개인정보 진입점

```dart
// lib/screens/settings/settings_screen.dart 에 추가

// 개인정보 설정 재진입 (UMP)
ListTile(
  title: const Text('광고 개인정보 설정'),
  subtitle: const Text('광고 맞춤 설정을 변경할 수 있어요'),
  onTap: () => UmpService.showPrivacyOptionsForm(context),
)

// PrivacyOptionsRequirementStatus.required 일 때만 표시
// 아닐 때는 타일 숨김
```

---

## STEP 11 — 회귀 테스트 목록

구현 후 반드시 수행:

```
[ ] 홈 마이크 버튼 → 단발 음성 입력 정상 동작 (변경 없음 확인)
[ ] query intent 자동 라우팅 → voice_conversation_screen 정상 동작
[ ] 딥링크 planflow://voice-conversation 정상 동작
[ ] 대화 모드 버튼 탭 → 무료 체험 (3회)
[ ] 무료 체험 3회 소진 → 광고 안내 표시
[ ] 광고 취소 → 대화 모드 진입 불가 확인
[ ] 광고 완료 → 대화 모드 진입 확인
[ ] kill switch OFF (reward_ad_enabled: false) → 광고 없이 바로 진입
[ ] 버튼 kill switch (voice_conversation_button_enabled: false) → 버튼 숨김
[ ] 광고 로드 실패 + failure_free_pass: true → 바로 진입
[ ] 광고 로드 실패 + failure_free_pass: false → 진입 불가
[ ] UMP 동의 거부 → 광고 로드 안 됨 확인
[ ] 설정 화면 개인정보 설정 재진입 동작 확인
[ ] 분석 이벤트 Firebase DebugView 확인
[ ] 개인정보 포함 이벤트 없음 확인
```

---

## 절대 규칙

```
1. 기존 단발 음성 입력 버튼 건드리지 말 것
2. 기존 query intent 자동 라우팅 건드리지 말 것
3. 광고 취소(userCancelled)는 반드시 진입 불가
4. 광고 실패(failed)와 취소(userCancelled)는 코드로 명확히 분리
5. kill switch OFF 시 광고 코드 경로 자체를 타지 않을 것
6. UmpService.canRequestAds == false 시 광고 로드 시도 금지
7. 동의 오류 시 비개인화 광고 임의 요청 금지
8. 개인정보(일정 제목, 장소, 메모)를 분석 이벤트에 포함 금지
9. 테스트 빌드는 반드시 테스트 광고 ID 사용
10. 구현 전 STEP 0 보고 먼저, 승인 후 구현
```

---

## Play 정책 준비 (사용자 직접 처리)

```
[ ] AdMob 앱 등록 + 광고 단위 ID 발급
[ ] AdMob Privacy & Messaging 설정
[ ] 개인정보처리방침 광고 SDK 항목 추가
[ ] Play Data Safety → 광고 ID 수집 신고
[ ] 광고 포함 신고
[ ] AD_ID 권한 최종 AAB 확인
    (aapt dump badging app-release.aab | grep AD_ID)
[ ] 대상 연령 광고 등급 설정
```
