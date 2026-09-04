import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/core/region_settings.dart';
import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/screens/voice/confirm_screen.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/schedule_parse_ad_gate.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '_harness/checkpoint_logger.dart';

/// PlanFlow iOS Simulator E2E Phase P7 — FLOW8: 회복력(오프라인/권한)과
/// 접근성(텍스트 배율·키보드·방향·화면 크기) 상태전이·레이아웃 검증.
///
/// docs/ios/SIMULATOR_QA_MATRIX.md 분류 매트릭스 항목 30(offline/network
/// failure, SIMULATOR_FULL), 33(permission denial/recovery,
/// SIMULATOR_PARTIAL), 34(text scaling, SIMULATOR_FULL), 35(keyboard,
/// SIMULATOR_FULL), 36(orientation, SIMULATOR_FULL), 37/38(small/large
/// screen, SIMULATOR_FULL)이 다루는 항목 중 하드웨어·OS 상호작용이 필요
/// 없는 부분만 이 파일이 검증한다. 실제 `simctl` 디바이스 회전·권한 강제
/// 전환·시뮬레이터 실행은 Windows 환경에서 불가능하므로 `scripts/ios/*.sh`
/// (P9)와 P8(macOS 러너) 몫이며, 여기서는 `dart analyze`로만 검증 가능한
/// 순수 위젯 레벨 상태전이·레이아웃만 다룬다.
// E2E run-2 행(hang) 조사(P8) 방지책: 인자 없는 pumpAndSettle()는
// pump 간격만 기본 100ms로 남기고, 실제 타임아웃은 WidgetTester.
// pumpAndSettle의 3번째 positional 인자(기본 10분, Flutter
// 3.41.9/3.47.2 SDK 소스로 확인)에 그대로 걸린다. 이 파일의
// _FailThenSucceedGptService/권한 fake들은 전부 지연 없이 즉시
// 완료되고, 텍스트 배율·키보드·방향·화면 크기 테스트는 순수
// 레이아웃 렌더링만 다룬다 — ConfirmScreen/VoiceInputScreen/
// PermissionOnboardingScreen의 CircularProgressIndicator는
// 스킵되는 네트워크 게이트 뒤에만 있고 무한 반복 애니메이션도 없다
// (소스 확인). 그래서 10초면 충분히 여유롭다. 반드시 3-positional
// 전체를 채워 호출한다 — pumpAndSettle(Duration(seconds: N))처럼
// 1-positional로 바꾸면 그건 pump 간격만 늘릴 뿐 타임아웃은
// 여전히 기본 10분으로 남아 오히려 역효과다.
const Duration _kSettleTimeout = Duration(seconds: 10);

void main() {
  logCheckpoint('FLOW8_START');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('FLOW8(a): 오프라인/네트워크 실패 — 에러 배너와 재시도', () {
    setUp(() {
      PlanFlowRegionController.instance.reset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(() {
      ScheduleParseAdGate.instance.delegateForTest = null;
    });

    testWidgets(
      'AI 일정 정리가 네트워크 오류로 실패하면 에러 배너와 재시도 버튼을 '
      '보여주고, 재시도하면 정상 결과로 복구된다',
      (tester) async {
        logCheckpoint('FLOW8_OFFLINE_TEST_START');
        // ScheduleParseAdGate의 무료 진입 정책 계산(peek/consume RPC)은
        // Supabase가 필요하므로, 이 시나리오와 무관한 게이트 로직을
        // delegateForTest로 완전히 우회한다(어떤 실제 provider도 호출하지
        // 않는 순수 free-pass 진입 — consume()도 호출되지 않으므로
        // ScheduleParseEntitlementService의 delegate도 필요 없다).
        ScheduleParseAdGate.instance.delegateForTest =
            _FreePassAdGateDelegate();
        final gpt = _FailThenSucceedGptService();

        await tester.pumpWidget(
          MaterialApp(
            home: ConfirmScreen(
              userId: 'e2e-user',
              parsedSchedule: <String, dynamic>{
                'title': '',
                'start_at': DateTime.now()
                    .add(const Duration(hours: 3))
                    .toIso8601String(),
                'end_at': null,
                'location': '',
                'memo': null,
                'supplies': <String>[],
                'is_critical': false,
                'recurrence_rule': null,
                'pre_actions': <Map<String, dynamic>>[],
                'raw_text': '내일 오전 9시에 팀 회의',
                'parse_pending': true,
              },
              gptService: gpt,
            ),
          ),
        );

        // ConfirmScreen의 hydrate 시도는 initState의
        // addPostFrameCallback에서 시작되므로 최소 한 프레임을 더 pump해야
        // 발화한다.
        await tester.pump();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          _kSettleTimeout,
        );

        expect(gpt.calls, 1);
        expect(
          find.text('일정을 바로 정리하지 못했어요. 필요한 내용만 직접 수정해 주세요.'),
          findsOneWidget,
        );
        final retryButton = find.byKey(const ValueKey('retry-ai-parse'));
        expect(retryButton, findsOneWidget);

        await tester.tap(retryButton);
        await tester.pump();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          _kSettleTimeout,
        );

        expect(gpt.calls, 2);
        expect(
          find.text('일정을 바로 정리하지 못했어요. 필요한 내용만 직접 수정해 주세요.'),
          findsNothing,
        );
        expect(find.textContaining('팀 회의'), findsWidgets);
      },
    );
  });

  group(
    'FLOW8(b): 위치 권한 거부/복구 (FLOW6의 마이크 권한과 다른 권한으로 '
    '동일 분기 재검증)',
    () {
      testWidgets(
        '위치 권한 요청이 거부되면 안내 문구를 보여주고, 재요청해서 '
        '허용되면 허용 상태로 전환된다',
        (tester) async {
          logCheckpoint('FLOW8_LOCATION_PERMISSION_TEST_START');
          SharedPreferencesAsyncPlatform.instance =
              InMemorySharedPreferencesAsync.empty();
          addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

          final permissionService = _LocationPermissionOnboardingFake();

          await tester.pumpWidget(
            MaterialApp(
              home: PermissionOnboardingScreen(
                permissionService: permissionService,
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          final locationTile = find.ancestor(
            of: find.text('위치'),
            matching: find.byType(Card),
          );
          expect(locationTile, findsOneWidget);

          await tester.tap(
            find.descendant(of: locationTile, matching: find.text('요청')),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(permissionService.locationRequestCalls, 1);
          expect(
            find.text(
              '위치 권한이 아직 허용되지 않았습니다. 다시 요청하거나 Android 앱 설정에서 켜 주세요.',
            ),
            findsOneWidget,
          );

          permissionService.locationGranted = true;
          await tester.tap(
            find.descendant(of: locationTile, matching: find.text('요청')),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(permissionService.locationRequestCalls, 2);
          expect(find.text('위치 권한이 허용되었습니다.'), findsOneWidget);
        },
      );
    },
  );

  group('FLOW8(c): 텍스트 배율(Dynamic Type) 접근성', () {
    for (final scale in <double>[1.3, 2.0]) {
      testWidgets(
        '텍스트 배율 ${scale}x에서도 음성 입력 화면이 오버플로우 없이 렌더링된다',
        (tester) async {
          logCheckpoint('FLOW8_TEXT_SCALE_GROUP_START');
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) {
                final mediaQuery = MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                );
                return MediaQuery(
                  data: mediaQuery,
                  child: child ?? const SizedBox.shrink(),
                );
              },
              home: const VoiceInputScreen(
                autoStartOverride: false,
                sttService: _LayoutSafeSttService(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: '텍스트 배율 ${scale}x에서 VoiceInputScreen 렌더 오류 발생',
          );
        },
      );

      testWidgets(
        '텍스트 배율 ${scale}x에서도 권한 온보딩 화면이 오버플로우 없이 렌더링된다',
        (tester) async {
          SharedPreferencesAsyncPlatform.instance =
              InMemorySharedPreferencesAsync.empty();
          addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) {
                final mediaQuery = MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                );
                return MediaQuery(
                  data: mediaQuery,
                  child: child ?? const SizedBox.shrink(),
                );
              },
              home: PermissionOnboardingScreen(
                permissionService: _MinimalPermissionServiceFake(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: '텍스트 배율 ${scale}x에서 PermissionOnboardingScreen 렌더 오류 발생',
          );
        },
      );
    }
  });

  group('FLOW8(d): 소프트웨어 키보드 표시 시 레이아웃 대응', () {
    testWidgets(
      '키보드가 올라와 뷰포트가 줄어들어도 음성 입력 화면은 오버플로우 없이 '
      '스크롤/리사이즈로 대응한다',
      (tester) async {
        logCheckpoint('FLOW8_KEYBOARD_TEST_START');
        await tester.pumpWidget(
          const MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: false,
              sttService: _LayoutSafeSttService(),
            ),
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          _kSettleTimeout,
        );

        // 원문 입력 TextField를 탭해 실제로 포커스·소프트 키보드 요청을
        // 발생시킨다(Scaffold.resizeToAvoidBottomInset=true 경로).
        await tester.tap(find.byType(TextField));
        await tester.pump();

        // 위젯 테스트 하네스는 실제 OS 키보드를 띄우지 않으므로, 키보드가
        // 올라왔을 때 실제 iOS가 주는 뷰포트 축소(viewInsets.bottom)를
        // MediaQuery로 직접 주입해 재현한다
        // (test/screens/permission_onboarding_screen_test.dart의
        // MaterialApp.builder + MediaQuery.copyWith 패턴 재사용).
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) {
              final mediaQuery = MediaQuery.of(context).copyWith(
                viewInsets: const EdgeInsets.only(bottom: 300),
              );
              return MediaQuery(
                data: mediaQuery,
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: const VoiceInputScreen(
              autoStartOverride: false,
              sttService: _LayoutSafeSttService(),
            ),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), '키보드 표시 중 입력 테스트');
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('키보드 표시 중 입력 테스트'), findsOneWidget);
      },
    );
  });

  group(
    'FLOW8(e): 방향 전환 레이아웃 (iPad는 4방향 회전 허용, iPhone은 세로 '
    '고정이 Info.plist 네이티브 설정 — 여기서는 앱 레이아웃이 landscape '
    '비율에서도 깨지지 않는지만 검증한다)',
    () {
      testWidgets(
        '가로 방향(iPad landscape 비율)에서도 음성 입력·권한 온보딩 화면이 '
        '오버플로우 없이 렌더링된다',
        (tester) async {
          logCheckpoint('FLOW8_ORIENTATION_TEST_START');
          addTearDown(() => tester.binding.setSurfaceSize(null));

          // iPad Pro 11형 landscape 논리 해상도에 준하는 비율.
          await tester.binding.setSurfaceSize(const Size(1194, 834));

          await tester.pumpWidget(
            const MaterialApp(
              home: VoiceInputScreen(
                autoStartOverride: false,
                sttService: _LayoutSafeSttService(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );
          expect(tester.takeException(), isNull);

          SharedPreferencesAsyncPlatform.instance =
              InMemorySharedPreferencesAsync.empty();
          addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

          await tester.pumpWidget(
            MaterialApp(
              home: PermissionOnboardingScreen(
                permissionService: _MinimalPermissionServiceFake(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  group('FLOW8(f): 소형/대형 화면 레이아웃', () {
    // physicalSizeTestValue와 동등한 목적으로, 이 코드베이스가 이미 쓰는
    // setSurfaceSize 규약을 그대로 따른다
    // (test/screens/permission_onboarding_screen_test.dart 참고).
    const sizes = <String, Size>{
      'iPhone SE급(소형)': Size(375, 667),
      'iPad Pro 12.9형급(대형)': Size(1024, 1366),
    };

    for (final entry in sizes.entries) {
      testWidgets(
        '${entry.key} 화면에서도 음성 입력 화면이 오버플로우 없이 렌더링된다',
        (tester) async {
          logCheckpoint('FLOW8_SCREEN_SIZE_GROUP_START');
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.binding.setSurfaceSize(entry.value);

          await tester.pumpWidget(
            const MaterialApp(
              home: VoiceInputScreen(
                autoStartOverride: false,
                sttService: _LayoutSafeSttService(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.key}(${entry.value})에서 렌더 오류 발생',
          );
        },
      );

      testWidgets(
        '${entry.key} 화면에서도 권한 온보딩 화면이 오버플로우 없이 렌더링된다',
        (tester) async {
          SharedPreferencesAsyncPlatform.instance =
              InMemorySharedPreferencesAsync.empty();
          addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.binding.setSurfaceSize(entry.value);

          await tester.pumpWidget(
            MaterialApp(
              home: PermissionOnboardingScreen(
                permissionService: _MinimalPermissionServiceFake(),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            _kSettleTimeout,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.key}(${entry.value})에서 렌더 오류 발생',
          );
          logCheckpoint('FLOW8_DONE');
        },
      );
    }
  });
}

/// `ScheduleParseAdGate.tryEnterScheduleParse`의 delegate 백도어를 이용해
/// 실제 무료 잔여 조회(peek)/소비(consume) RPC를 전혀 호출하지 않는
/// free-pass 진입을 재현한다. `adFailedFreePass` 출처는 ConfirmScreen이
/// consume()을 호출하지 않는 유일한 grant 출처라서(`confirm_screen.dart`의
/// `if (... grant.source != ScheduleParseEntitlementSource.adFailedFreePass)`
/// 분기), 이 fake만으로 gptService 실패/재시도 시나리오 전체를 어떤 실제
/// provider도 없이 안전하게 재현할 수 있다
/// (`test/screens/confirm_screen_test.dart`의 `_FreePassAdGateDelegate`
/// 패턴 재사용).
class _FreePassAdGateDelegate implements ScheduleParseAdGateDelegate {
  @override
  Future<void> tryEnter({
    required BuildContext context,
    required void Function(ScheduleParseEntryGrant grant) onEnterAllowed,
    void Function(ScheduleParseGateDenialReason reason)? onDenied,
    required ScheduleParseAdGate gate,
  }) async {
    onEnterAllowed(
      ScheduleParseEntryGrant(
        sessionId: ScheduleParseSessionIdGenerator.next(),
        source: ScheduleParseEntitlementSource.adFailedFreePass,
        dailyRemainingAtGate: 0,
      ),
    );
  }
}

/// 첫 호출은 오프라인/네트워크 실패를 재현하기 위해 [SocketException]을
/// 던지고, 재시도 시에는 성공한 파싱 결과를 반환하는 fake.
/// `confirm_screen.dart`의 `_hydrateParsedSchedule` catch 블록
/// (gptService.parseSchedule이 던진 예외를 잡는 지점)을 그대로 검증한다.
class _FailThenSucceedGptService extends GptService {
  int calls = 0;

  @override
  Future<Map<String, dynamic>> parseSchedule(String rawText) async {
    calls += 1;
    if (calls == 1) {
      throw const SocketException('E2E fixture: offline');
    }
    return <String, dynamic>{
      'title': '팀 회의',
      'location': '',
      'memo': null,
      'start_at': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
      'end_at': null,
      'supplies': <String>[],
      'is_critical': false,
      'pre_actions': <Map<String, dynamic>>[],
      'parse_failed': false,
    };
  }
}

/// `PermissionOnboardingScreen`의 위치 권한 타일 거부→재요청→허용 흐름을
/// 재현하는 fake. `checkAll()`을 완전히 오버라이드해 실제
/// `NotificationService`/배터리 최적화 채널을 전혀 호출하지 않는다.
class _LocationPermissionOnboardingFake extends AppPermissionService {
  bool locationGranted = false;
  int locationRequestCalls = 0;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: true,
      locationGranted: locationGranted,
      calendarGranted: true,
      notificationStatus: const NotificationPermissionStatus(
        notificationsEnabled: true,
        exactAlarmsEnabled: true,
        fullScreenIntentStatus: PermissionCheckState.granted,
      ),
      batteryOptimizationIgnored: true,
    );
  }

  @override
  Future<bool> requestLocationPermission() async {
    locationRequestCalls += 1;
    return locationGranted;
  }

  @override
  Future<void> markOnboardingCompleted(String userId) async {}
}

/// 레이아웃/접근성 검증에서만 쓰는 `SttService` fake. 실제 네이티브
/// `speech_to_text`/MethodChannel을 건드리지 않도록 `warmUp()`만 no-op으로
/// 바꾼다(레이아웃 확인이 목적이라 리스닝 자체는 필요 없다). `SttService`가
/// 상수 생성자(`const SttService()`)이므로 이 fake도 상수 생성자를 유지해
/// 기존 `const VoiceInputScreen(...)` 사용 패턴을 그대로 둘 수 있게 한다.
class _LayoutSafeSttService extends SttService {
  const _LayoutSafeSttService();

  @override
  Future<void> warmUp() async {}
}

/// 레이아웃/접근성 검증(텍스트 배율·방향·화면 크기)에서만 쓰는 최소
/// 권한 서비스 fake. 모든 권한을 허용 상태로 두어(레이아웃 자체가
/// 목적이므로) 요청 다이얼로그나 실채널 호출 없이 화면이 조용히
/// 렌더링되게 한다.
class _MinimalPermissionServiceFake extends AppPermissionService {
  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return const AppPermissionSnapshot(
      microphoneGranted: true,
      locationGranted: true,
      calendarGranted: true,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: true,
        exactAlarmsEnabled: true,
        fullScreenIntentStatus: PermissionCheckState.granted,
      ),
      batteryOptimizationIgnored: true,
    );
  }

  @override
  Future<void> markOnboardingCompleted(String userId) async {}
}
