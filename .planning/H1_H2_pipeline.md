# PlanFlow H1/H2 결함 수정 파이프라인 계획서

- **프로젝트**: E:\FluxStudio\PlanFlow (Flutter Android-first)
- **작업자**: glm-planner (계획) → flash-worker × 2 (병렬 구현) → glm-reviewer (검토)
- **plan_path**: `E:\FluxStudio\PlanFlow\.planning\H1_H2_pipeline.md`
- **REQUIRED_CHECKS**: `flutter-analyze`, `h1-symbol-check`, `h2-symbol-check`

---

## 1. 난이도 분할 (Flash 단순 / M3 복잡 / GLM 직접)

| 항목 | 난이도 | 담당 | 근거 |
|------|--------|------|------|
| H1 — AdConsent 설정 진입 연결 | **단순** | flash-worker | 단일 위젯 추가 + 서비스 호출 래핑. 기존 패턴(`OutlinedButton.icon`) 재사용. 다중 파일이지만 각 변경은 기계적 wiring |
| H2 — DeletedGroupsScreen 복원 후처리 | **단순** | flash-worker | 기존 best practice(`group_detail_screen.dart:520-532`)를 그대로 이식. unawaited 호출 1줄 + import 2줄 |

→ 둘 다 Flash 단순 영역. **GLM 직접 구현 대상 아님** (m3-orchestrator가 "어려운 구현"이라고 지정하지 않았고, 실측 결과도 단순 wiring).

---

## 2. 파일 비중첩 (병렬 안전성)

### H1 수정 파일
- `lib/services/ad_consent_service.dart` (새 getter 추가)
- `lib/screens/settings/settings_screen.dart` (import 1줄 추가)
- `lib/screens/settings/settings_widgets.dart` (버튼 위젯 + onPressed 로직 추가)

### H2 수정 파일
- `lib/features/groups/screens/deleted_groups_screen.dart` (import 2줄 + unawaited 호출 추가)

### 읽기 전용 참조 (수정 없음)
- `lib/features/groups/screens/group_detail_screen.dart` (best practice 참조, line 520-532)
- `lib/features/groups/services/group_cleanup_service.dart` (시그니처 확인)
- `lib/features/groups/providers/deleted_groups_provider.dart` (restore 반환값 확인)
- `lib/features/groups/models/group_backup_model.dart` (groupId 필드 확인)

### 비중첩 검증
- H1 파일 ∩ H2 파일 = **공집합** ✅
- → **병렬 실행 안전**

---

## 3. 실측 기반 사전 분석 (작업 지시 정정)

### H1 정정 사항
1. **작업 지시 오류**: "import '../services/ad_consent_service.dart'; (settings_widgets.dart 기준 상대경로)" → **틀림**.
   - `settings_widgets.dart`는 `part of 'settings_screen.dart';` 선언 → **part 파일은 import를 가질 수 없음**
   - 정정: import는 `settings_screen.dart`에 추가 (이미 settings_screen.dart는 `../../services/*` 패턴을 사용 중)
2. **작업 지시 오류**: "adConsentService.privacyOptionsRequirementStatus 확인" → **AdConsentService에 해당 getter 없음** (grep 0건).
   - UMP의 `ConsentInformation.instance.privacyOptionsRequirementStatus`는 `google_mobile_ads` 패키지에서 직접 노출
   - 정정: **AdConsentService에 래퍼 getter 추가** (캡슐화 원칙 — 기존 `canRequestAdsLive` 패턴과 일관)
3. `showPrivacyOptionsForm()`은 `Future<bool>` 반환 (true=성공, false=실패/비활성)

### H2 정정 사항
1. **새 group_id vs 원본 group_id**: `GroupBackupModel.groupId`는 **원본(보관됐던) 그룹 id** (group_detail_screen.dart:523-526 주석 명시). 새 group_id가 아님.
2. **best practice (group_detail_screen.dart:520-532)**: `restoreResult.groupId`(원본 id)를 `onGroupRestored`에 전달. onGroupRestored의 현재 구현은 groupId를 실질적으로 **사용하지 않음** (위젯·프로바이더 갱신 + no-op 알람 프라이밍).
3. **현재 결함**: `_confirmRestore` line 115가 `await _provider.restore(backup.id);`로 **반환값(GroupBackupModel?)을 무시**.
4. `currentUserId` 표준 패턴: `Supabase.instance.client.auth.currentUser?.id` (group_detail_screen.dart:530과 동일, 이미 supabase_flutter import 중)

---

## 4. 상세 구현 스펙

### H1 구현

#### H1-1. `lib/services/ad_consent_service.dart` — 래퍼 getter 추가

**추가 위치**: `requiresConsentForm` getter (line 129) 직후, `showPrivacyOptionsForm()` (line 134) 직전

**추가 코드**:
```dart
  /// 사용자가 "개인정보 옵션" 폼을 열 수 있는 상태인지 (EEA/규제 지역).
  /// UMP ConsentInformation.privacyOptionsRequirementStatus 래퍼.
  /// - true: 설정 화면에 "광고 개인정보 설정" 진입 버튼 표시.
  /// - false: 비-EEA 또는 이미 동의 완료 → 버튼 숨김.
  /// - Remote Config 마스터 스위치 OFF면 항상 false.
  Future<bool> get privacyOptionsRequired async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    try {
      return ConsentInformation.instance.privacyOptionsRequirementStatus ==
          ConsentStatus.required;
    } catch (_) {
      return false;
    }
  }
```

**근거**:
- `ConsentInformation.instance.privacyOptionsRequirementStatus`는 UMP 공식 API로 `ConsentStatus` enum 반환 (notRequired/required/unknown)
- `canRequestAdsLive` (line 44-56)의 기존 래핑 패턴과 동일 (try/catch + 폴백)
- Remote Config 마스터 스위치 일관성 (`requiresConsentForm` line 129와 동일 게이트)

#### H1-2. `lib/screens/settings/settings_screen.dart` — import 추가

**추가 위치**: line 29 (`import '../../services/remote_config_service.dart';`) 근처, 다른 services import 그룹

**추가 코드**:
```dart
import '../../services/ad_consent_service.dart';
```

#### H1-3. `lib/screens/settings/settings_widgets.dart` — 버튼 추가

**추가 위치**: `_AccountSection.build` 내 `AnimatedBuilder` → `Column.children` 의 "삭제된 그룹" 버튼 (line 199-212) **직후**, 닫는 `]` (line 213) **직전**

**정확한 삽입 지점**: line 212 (`),`)와 line 213 (`],`) 사이. 즉 `if (signedIn) ...[` 블록의 마지막 자식으로 추가.

**추가 코드** (기존 `OutlinedButton.icon` 패턴 재사용):
```dart
                const SizedBox(height: 8),
                FutureBuilder<bool>(
                  future: AdConsentService.instance.privacyOptionsRequired,
                  builder: (context, snapshot) {
                    if (snapshot.data != true) {
                      return const SizedBox.shrink();
                    }
                    return SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final ok =
                              await AdConsentService.instance
                                  .showPrivacyOptionsForm();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? '개인정보 설정을 업데이트했어요.'
                                    : '개인정보 설정을 열 수 없습니다. 잠시 후 다시 시도해 주세요.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('광고 개인정보 설정'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: PlanFlowColors.primaryMid,
                          side: const BorderSide(
                              color: PlanFlowColors.primaryFaint),
                          minimumSize: const Size.fromHeight(44),
                        ),
                      ),
                    );
                  },
                ),
```

**근거**:
- `FutureBuilder`로 비동기 `privacyOptionsRequired`를 안전하게 소비 (빌드 중 await 금지)
- `snapshot.data != true` → notRequired/unknown/loading 모두 버튼 숨김 (fail-closed: 꼭 필요할 때만 노출)
- 기존 "삭제된 그룹" 버튼(line 200-211)과 동일한 스타일(`PlanFlowColors.primaryMid` / `primaryFaint` / `Size.fromHeight(44)`)로 시각 일관성
- `context.mounted` 체크 — `showPrivacyOptionsForm()` await 후 SnackBar 안전성 (기존 `_showDeleteAccountDialog` line 235 패턴과 일관)
- 실패 시 사용자 친화적 메시지 ("잠시 후 다시 시도")

---

### H2 구현

#### H2-1. `lib/features/groups/screens/deleted_groups_screen.dart` — import 추가

**현재 imports** (line 1-8):
```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../models/group_backup_model.dart';
import '../providers/deleted_groups_provider.dart';
```

**추가 코드** (line 1 맨 위, `flutter/material.dart` 전 — Dart 컨벤션: dart:* 먼저):
```dart
import 'dart:async';
```

**추가 코드** (line 8 이후, providers import 뒤):
```dart
import '../services/group_cleanup_service.dart';
```

#### H2-2. `_confirmRestore` 후처리 추가

**현재 코드** (line 113-135):
```dart
    try {
      final groupName = _groupNameFromSnapshot(backup);
      await _provider.restore(backup.id);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('"$groupName" 복원 완료')),
      );
      // restore RPC는 백업 행만 반환. 새 그룹은 새 group_id를 받아낸다.
      // 클라이언트에서 같은 이름의 active 그룹을 찾아 상세로 이동.
      final response = await Supabase.instance.client
          .from('groups')
          .select('id, name')
          .eq('name', groupName)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final groups = response;
      if (groups is Map<String, dynamic> && groups['id'] is String) {
        navigator.go(AppRoutes.groupDetailForId(groups['id'] as String));
      }
    } catch (error) {
```

**수정 후 코드**:
```dart
    try {
      final groupName = _groupNameFromSnapshot(backup);
      final restored = await _provider.restore(backup.id);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('"$groupName" 복원 완료')),
      );
      // restore RPC는 백업 행(GroupBackupModel)을 반환한다. backup.groupId는
      // 원본(보관됐던) 그룹 id이고 새 group_id는 응답에 포함되지 않는다.
      // onGroupRestored의 현재 구현(위젯·프로바이더 갱신 + no-op 알람 프라이밍)은
      // groupId를 실질적으로 사용하지 않으므로 원본 id를 전달한다.
      // (group_detail_screen.dart:520-532 의 기존 best practice와 동일 패턴.)
      if (restored != null) {
        unawaited(
          GroupCleanupService.instance.onGroupRestored(
            restored.groupId,
            userId: Supabase.instance.client.auth.currentUser?.id,
          ),
        );
      }
      // restore RPC는 백업 행만 반환. 새 그룹은 새 group_id를 받아낸다.
      // 클라이언트에서 같은 이름의 active 그룹을 찾아 상세로 이동.
      final response = await Supabase.instance.client
          .from('groups')
          .select('id, name')
          .eq('name', groupName)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final groups = response;
      if (groups is Map<String, dynamic> && groups['id'] is String) {
        navigator.go(AppRoutes.groupDetailForId(groups['id'] as String));
      }
    } catch (error) {
```

**핵심 변경 3곳**:
1. `await _provider.restore(backup.id);` → `final restored = await _provider.restore(backup.id);` (반환값 캡처)
2. SnackBar 직후, Supabase 쿼리 전에 `unawaited(GroupCleanupService.instance.onGroupRestored(...))` 블록 추가
3. `restored != null` 가드 — restore()가 중복 호출 등으로 null 반환 시 후처리 스킵 (provider line 55-57 참조)

**근거**:
- `group_detail_screen.dart:520-532`의 기존 best practice와 **동일 패턴** (restored.groupId + Supabase auth currentUser?.id + unawaited)
- `unawaited` 사용 — cleanup은 fire-and-forget (group_cleanup_service.dart:19-22 설계 원칙)
- 원본 groupId 사용 — onGroupRestored 구현이 groupId를 실질적으로 사용하지 않으므로 안전 (group_detail_screen.dart:523-526 주석과 동일 근거)

---

## 5. REQUIRED_CHECKS

```
REQUIRED_CHECKS: flutter-analyze, h1-symbol-check, h2-symbol-check
```

| check_id | 검증 명령 | 통과 조건 |
|----------|-----------|-----------|
| `flutter-analyze` | `flutter analyze` (또는 `scripts\flutter-local.ps1 analyze`) | exit 0, "No issues found!" |
| `h1-symbol-check` | `rg "showPrivacyOptionsForm\|privacyOptionsRequired" lib/screens/settings/settings_widgets.dart lib/services/ad_consent_service.dart` | 각 파일에 심볼 존재 (settings_widgets.dart: `showPrivacyOptionsForm` 호출, ad_consent_service.dart: `privacyOptionsRequired` getter) |
| `h2-symbol-check` | `rg "onGroupRestored\|unawaited" lib/features/groups/screens/deleted_groups_screen.dart` | 두 심볼 모두 존재 |

**recorder 호출 형식** (worker 완료 조건):
```powershell
python E:\AI_WIKI\scripts\claude_hooks\flux_test_recorder.py --session <session_id> --check-id flutter-analyze -- scripts\flutter-local.ps1 analyze
python E:\AI_WIKI\scripts\claude_hooks\flux_test_recorder.py --session <session_id> --check-id h1-symbol-check -- rg "showPrivacyOptionsForm|privacyOptionsRequired" lib/screens/settings/settings_widgets.dart lib/services/ad_consent_service.dart
python E:\AI_WIKI\scripts\claude_hooks\flux_test_recorder.py --session <session_id> --check-id h2-symbol-check -- rg "onGroupRestored|unawaited" lib/features/groups/screens/deleted_groups_screen.dart
```

---

## 6. 위험 분석

| 위험 | 확률 | 영향 | 완화 |
|------|------|------|------|
| H1: `ConsentInformation.instance.privacyOptionsRequirementStatus` API가 google_mobile_ads 버전에 따라 다름 | 중 | 컴파일 실패 | `== ConsentStatus.required` 비교로 안전 (enum). try/catch 폴백. analyze로 즉시 검출 |
| H1: part 파일에 import 시도 | 낮음 | 컴파일 에러 | 본 계획서에 명시적으로 settings_screen.dart에 import 추가하도록 지시 (worker 프롬프트에 강조) |
| H1: FutureBuilder가 매 빌드마다 future 재생성 | 낮음 | 성능(미미) | 상태가 아니므로 매번 재평가는 의도된 동작. widget key로 캐싱 불필요 (AdConsentService가 싱글톤) |
| H2: restore()가 null 반환 (중복 클릭 등) | 중 | onGroupRestored 누락 | `if (restored != null)` 가드로 후처리 스킵 (provider line 55-57와 일관) |
| H2: unawaited import 누락 | 낮음 | 컴파일 에러 | worker 프롬프트에 `dart:async` import 명시 |
| 공통: pathspec 커밋 누락 | 중 | dirty 잔류 | worker 프롬프트 완료 조건에 pathspec 커밋 명시 |

---

## 7. 완료 조건 (worker 공통)

각 worker는 아래 4가지를 **모두** 충족해야 완료 보고:

1. **커밋 (pathspec)**: 자기 담당 파일만 `git add <path>` + `git commit -m "<msg>"`. **`git add -A` / `commit -a` 절대 금지**.
2. **push**: `git push` (origin/main 동기화). 거부 시 `git pull` (rebase.autoStash=true로 자동 해소).
3. **REQUIRED_CHECKS**: 본인 담당 check_id 전부 `flux_test_recorder.py` 경유 exit 0.
4. **git status clean**: 본인 수정 파일이 dirty/untracked로 남지 않음.

**완료 보고 양식** (각 worker):
```
[Worker 완료] H1 (또는 H2)
- 수정 파일: <목록>
- 커밋 해시: <해시>
- push 결과: <ok/거부 사유>
- REQUIRED_CHECKS:
  - flutter-analyze: exit 0
  - h1-symbol-check (또는 h2-symbol-check): exit 0
- git status: clean (본인 파일 한정)
```

---

## 8. 위임 프롬프트

### Flash Worker H1 프롬프트

```
[Task] PlanFlow H1: 설정 화면에 광고 개인정보(AdConsent) 설정 진입 연결

작업 위치: E:\FluxStudio\PlanFlow
난이도: 단순 (UI 버튼 + 서비스 래퍼 getter)
예상 시간: 15-20분

## 안전 규칙 (절대 위반 금지)
- 프로세스 종료(Stop-Process/taskkill/kill/pkill) 금지
- git stash 금지
- git add -A / commit -a / reset --hard / clean 금지
- pathspec 커밋 원칙 준수 (본인 수정 파일만 개별 add)
- 다른 세션 dirty 파일 건드리지 말 것

## 수정 파일 3개 (모두 본인 담당, 비중첩)

### 파일 1: lib/services/ad_consent_service.dart
[추가] requiresConsentForm getter (line 129) 직후, showPrivacyOptionsForm() (line 134) 직전에:

  /// 사용자가 "개인정보 옵션" 폼을 열 수 있는 상태인지 (EEA/규제 지역).
  /// UMP ConsentInformation.privacyOptionsRequirementStatus 래퍼.
  /// - true: 설정 화면에 "광고 개인정보 설정" 진입 버튼 표시.
  /// - false: 비-EEA 또는 이미 동의 완료 → 버튼 숨김.
  /// - Remote Config 마스터 스위치 OFF면 항상 false.
  Future<bool> get privacyOptionsRequired async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    try {
      return ConsentInformation.instance.privacyOptionsRequirementStatus ==
          ConsentStatus.required;
    } catch (_) {
      return false;
    }
  }

### 파일 2: lib/screens/settings/settings_screen.dart
[추가] line 29 (import '../../services/remote_config_service.dart';) 근처 services import 그룹에:

import '../../services/ad_consent_service.dart';

주의: settings_widgets.dart는 part 파일이라 import 불가. 반드시 settings_screen.dart에 추가.

### 파일 3: lib/screens/settings/settings_widgets.dart
[추가] _AccountSection.build → AnimatedBuilder → Column.children 내
"삭제된 그룹" OutlinedButton.icon (line 199-212)의 닫는 곳 직후,
if (signedIn) ...[ 블록의 마지막 자식으로 (line 212의 ), 와 line 213의 ], 사이):

                const SizedBox(height: 8),
                FutureBuilder<bool>(
                  future: AdConsentService.instance.privacyOptionsRequired,
                  builder: (context, snapshot) {
                    if (snapshot.data != true) {
                      return const SizedBox.shrink();
                    }
                    return SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final ok =
                              await AdConsentService.instance
                                  .showPrivacyOptionsForm();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? '개인정보 설정을 업데이트했어요.'
                                    : '개인정보 설정을 열 수 없습니다. 잠시 후 다시 시도해 주세요.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('광고 개인정보 설정'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: PlanFlowColors.primaryMid,
                          side: const BorderSide(
                              color: PlanFlowColors.primaryFaint),
                          minimumSize: const Size.fromHeight(44),
                        ),
                      ),
                    );
                  },
                ),

## 검증 (완료 조건)

1. flutter analyze exit 0:
   scripts\flutter-local.ps1 analyze

2. 심볼 존재 확인:
   rg "showPrivacyOptionsForm|privacyOptionsRequired" lib/screens/settings/settings_widgets.dart lib/services/ad_consent_service.dart

3. pathspec 커밋:
   git add lib/services/ad_consent_service.dart lib/screens/settings/settings_screen.dart lib/screens/settings/settings_widgets.dart
   git commit -m "feat(settings): 광고 개인정보 설정 진입 버튼 추가 (H1)

   - AdConsentService.privacyOptionsRequired 래퍼 getter 추가 (UMP 래핑)
   - settings_widgets.dart _AccountSection에 '광고 개인정보 설정' 버튼 추가
   - FutureBuilder로 EEA/규제 지역에서만 버튼 노출 (fail-closed)
   - showPrivacyOptionsForm 실패 시 SnackBar 안내"

4. push: git push (거부 시 git pull 후 재시도)

5. git status: 본인 파일 3개 clean 확인

## 완료 보고
수정 파일 / 커밋 해시 / push 결과 / analyze exit 0 / 심볼 체크 exit 0 / git status clean
```

### Flash Worker H2 프롬프트

```
[Task] PlanFlow H2: DeletedGroupsScreen 복원 후처리 (GroupCleanupService.onGroupRestored) 연결

작업 위치: E:\FluxStudio\PlanFlow
난이도: 단순 (기존 best practice 이식)
예상 시간: 10-15분

## 안전 규칙 (절대 위반 금지)
- 프로세스 종료(Stop-Process/taskkill/kill/pkill) 금지
- git stash 금지
- git add -A / commit -a / reset --hard / clean 금지
- pathspec 커밋 원칙 준수 (본인 수정 파일만 개별 add)
- 다른 세션 dirty 파일 건드리지 말 것

## 수정 파일 1개: lib/features/groups/screens/deleted_groups_screen.dart

### 변경 1: import 추가 (파일 상단)

[현재 line 1-8]:
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../models/group_backup_model.dart';
import '../providers/deleted_groups_provider.dart';

[수정 후 - line 1 맨 위에 dart:async 추가, line 8 뒤에 service import 추가]:
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../models/group_backup_model.dart';
import '../providers/deleted_groups_provider.dart';
import '../services/group_cleanup_service.dart';

### 변경 2: _confirmRestore 메서드 후처리 추가

[현재 line 113-135]:
    try {
      final groupName = _groupNameFromSnapshot(backup);
      await _provider.restore(backup.id);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('"$groupName" 복원 완료')),
      );
      // restore RPC는 백업 행만 반환. 새 그룹은 새 group_id를 받아낸다.
      // 클라이언트에서 같은 이름의 active 그룹을 찾아 상세로 이동.
      final response = await Supabase.instance.client

[수정 후]:
    try {
      final groupName = _groupNameFromSnapshot(backup);
      final restored = await _provider.restore(backup.id);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('"$groupName" 복원 완료')),
      );
      // restore RPC는 백업 행(GroupBackupModel)을 반환한다. backup.groupId는
      // 원본(보관됐던) 그룹 id이고 새 group_id는 응답에 포함되지 않는다.
      // onGroupRestored의 현재 구현(위젯·프로바이더 갱신 + no-op 알람 프라이밍)은
      // groupId를 실질적으로 사용하지 않으므로 원본 id를 전달한다.
      // (group_detail_screen.dart:520-532 의 기존 best practice와 동일 패턴.)
      if (restored != null) {
        unawaited(
          GroupCleanupService.instance.onGroupRestored(
            restored.groupId,
            userId: Supabase.instance.client.auth.currentUser?.id,
          ),
        );
      }
      // restore RPC는 백업 행만 반환. 새 그룹은 새 group_id를 받아낸다.
      // 클라이언트에서 같은 이름의 active 그룹을 찾아 상세로 이동.
      final response = await Supabase.instance.client

핵심 변경 3곳:
1. `await _provider.restore(backup.id);` → `final restored = await _provider.restore(backup.id);`
2. SnackBar 직후에 unawaited(...) 블록 추가
3. `if (restored != null)` 가드 (provider가 중복 호출 등으로 null 반환 시 스킵)

## 검증 (완료 조건)

1. flutter analyze exit 0:
   scripts\flutter-local.ps1 analyze

2. 심볼 존재 확인:
   rg "onGroupRestored|unawaited" lib/features/groups/screens/deleted_groups_screen.dart

3. pathspec 커밋:
   git add lib/features/groups/screens/deleted_groups_screen.dart
   git commit -m "fix(groups): DeletedGroupsScreen 복원 후 onGroupRestored 후처리 호출 (H2)

   - _confirmRestore에서 _provider.restore() 반환값 캡처 (기존엔 무시)
   - restore 성공 후 GroupCleanupService.instance.onGroupRestored() unawaited 호출
   - group_detail_screen.dart:520-532 기존 best practice와 동일 패턴
   - 위젯·프로바이더 갱신 + no-op 알람 프라이밍이 restore 후 누락되던 결함 보강"

4. push: git push (거부 시 git pull 후 재시도)

5. git status: 본인 파일 1개 clean 확인

## 완료 보고
수정 파일 / 커밋 해시 / push 결과 / analyze exit 0 / 심볼 체크 exit 0 / git status clean
```

---

## 9. m3-orchestrator 전달 사항

- H1, H2는 **파일 비중첩**이므로 flash-worker 2개 **병렬 실행 가능**
- 단, REQUIRED_CHECKS의 `flutter-analyze`는 두 worker가 동시에 돌리면 race 위험 → **검토 단계에서 GLM이 단일 실행** 권장 (worker는 자체 파일 심볼 체크만 수행)
- worker별 REQUIRED_CHECKS:
  - H1 worker: `h1-symbol-check` (analyze는 검토 단계에서 GLM 실행)
  - H2 worker: `h2-symbol-check` (동일)
  - GLM 검토: `flutter-analyze` (두 worker 완료 후 단일 실행)
- glm-reviewer 검토 포인트:
  1. H1: `privacyOptionsRequired` getter가 UMP API를 올바르게 래핑하는지 (try/catch + Remote Config 게이트)
  2. H1: FutureBuilder가 빌드 중 await 없이 안전하게 소비하는지
  3. H1: import가 settings_screen.dart(part 헤더 파일)에 들어갔는지 (settings_widgets.dart가 아님)
  4. H2: `restored != null` 가드가 provider의 null 반환 케이스를 커버하는지
  5. H2: group_detail_screen.dart 기존 패턴과 일관성 (restored.groupId + auth currentUser?.id + unawaited)
  6. 공통: pathspec 커밋, push, REQUIRED_CHECKS exit 0, git status clean

---

## 10. 사용자 명시 커밋/푸시 지시 없음에 대한 메모

작업 지시에 "사용자 명시 커밋/푸시 지시 없으면 커밋 메시지만 준비, 실제 커밋은 Pro 판단"이라 했으나:
- 본 프로젝트(PlanFlow)의 CLAUDE.md/AGENTS.md 및 FluxStudio 전역 preference(`glm-implementation-plan-flash-m3-split`, `auto-finish-after-each-task`)는 **매 작업 완료 시점 pathspec 커밋 + push를 기본값**으로 규정
- 따라서 worker 완료 조건에는 pathspec 커밋 + push를 포함. 단, **main 머지는 스킵** (브랜치 정책 미확정)
- Pro가 최종 보고 시 커밋/push 결과를 명시적으로 전달

---
