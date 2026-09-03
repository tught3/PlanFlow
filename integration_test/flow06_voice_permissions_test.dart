import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:planflow/services/voice_conversation_ad_gate.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// PlanFlow iOS Simulator E2E Phase P7 — FLOW6: 마이크 권한 거부/복구
/// 상태머신·화면분기 검증.
///
/// docs/ios/SIMULATOR_QA_MATRIX.md 매트릭스 항목 18(microphone permission
/// flow, SIMULATOR_PARTIAL, 담당 FLOW6 — 리뷰 수정으로 실제 구현 파일
/// 기준 재정정됨)이 다루는 두 부분 중, "앱 로직 분기" 부분만 이 파일이
/// 검증한다:
///
/// - `simctl privacy grant/revoke microphone <UDID> com.fluxstudio.planflow`로
///   실제 iOS 시뮬레이터 OS 권한 상태를 전환하는 것은 `scripts/ios/*.sh`(P9,
///   이미 완료)와 P8(macOS 러너에서 실제 시뮬레이터 실행)의 몫이다. Windows
///   환경에서는 시뮬레이터 자체를 실행할 수 없어 이 부분은 이 파일에서
///   재현하지 않는다.
/// - 권한이 이미 거부/허용된 것으로 "가정한" 상태에서 앱이 실제로 어떤
///   화면 분기를 타는지(에러 배너 표시, 재요청 버튼, 재시도 성공 흐름)는
///   순수 Dart/Flutter 위젯 레벨에서 100% 재현 가능하며, 이 부분을
///   `dart analyze`로만 검증 가능한 형태로 담는다.
///
/// 매트릭스 항목 19(speech recognition, PHYSICAL_DEVICE_REQUIRED)와
/// `integration_test/_harness/fakes/fake_stt_channel.dart`의 주석이 이미
/// 실측 확인한 대로, `lib/services/stt_service.dart`에는 iOS 네이티브 STT
/// 엔진(`speech_to_text` 패키지)을 교체할 delegate/생성자 파라미터가 없다
/// (`const SttService()` — 필드 없는 상수 생성자, 순수 static 상태).
/// 그래서 이 파일은 `fake_stt_channel.dart`의 MethodChannel mock 대신,
/// `test/screens/voice_input_screen_test.dart`가 이미 쓰는 검증된 패턴—
/// `SttService`를 직접 서브클래싱해 `listen()`의 반환값만 제어하는 방식—을
/// 재사용한다. `SttService`는 `abstract`/`sealed`/`final` 클래스가 아니고
/// `listen()`/`warmUp()`/`cancelActiveListen()`/`stopActiveListen()`도
/// 일반 인스턴스 메서드(override 가능)이므로, 이 방식은 서비스 코드를
/// 전혀 수정하지 않고도 `VoiceInputScreen`의 상태전이만 검증한다.
///
/// `lib/services/stt_service.dart:1034-1041`(iOS `_listenWithSpeechToText`
/// 경로)을 보면, 실제 iOS 마이크 권한이 거부된 경우
/// `speech.initialize()`가 `available=false`를 반환하고
/// `hasPermission=false`이면 정확히
/// `SttListenResult.failure(failure: SttListenFailure.permissionDenied,
/// message: _permissionMessage)` 형태가 반환된다. 이 파일의 fake는 그
/// 정확한 반환 형태(같은 enum 값)를 재현해, 실제 iOS 권한 거부 시 화면이
/// 타는 분기와 동일한 코드 경로를 검증한다.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 게이트 delegate는 static 싱글턴(VoiceConversationAdGate.instance)에
    // 걸리므로, 한 테스트가 설정한 delegate가 다음 테스트로 새는 것을 막는다.
    VoiceConversationAdGate.instance.delegateForTest = null;
  });

  group('FLOW6: VoiceInputScreen — 마이크 권한 거부/재시도 상태머신', () {
    testWidgets(
      '마이크 권한이 거부되면 상태 배너를 보여주고 직접 입력으로 폴백하며, '
      '재시도해서 권한이 허용되면 정상 인식으로 이어진다',
      (tester) async {
        const deniedMessage =
            '마이크 권한이 없어요. 설정에서 권한을 허용한 뒤 다시 시도하거나 직접 입력으로 이어가 주세요.';
        final fakeStt = _PermissionGatedSttService(denialMessage: deniedMessage);

        final router = GoRouter(
          initialLocation: AppRoutes.voice,
          routes: [
            GoRoute(
              path: AppRoutes.voice,
              builder: (context, state) => VoiceInputScreen(
                autoStartOverride: false,
                sttService: fakeStt,
              ),
            ),
            GoRoute(
              path: AppRoutes.confirm,
              builder: (context, state) {
                final extra = state.extra as Map<String, dynamic>;
                return Text(
                  'confirm:${extra['raw_text']}',
                  textDirection: TextDirection.ltr,
                );
              },
            ),
            GoRoute(
              path: AppRoutes.voiceAction,
              builder: (context, state) => const Text(
                '음성 관리 화면',
                textDirection: TextDirection.ltr,
              ),
            ),
          ],
        );

        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // 1차 시도: OS가 마이크 권한을 거부한 것으로 가정.
        await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(fakeStt.listenCalls, 1);
        expect(find.text(deniedMessage), findsOneWidget);
        // 리스닝은 종료되고 화면은 그대로 유지되어(내비게이션 없음) 사용자가
        // 키보드로 직접 입력을 이어갈 수 있는 상태여야 한다.
        expect(
          find.byKey(const ValueKey('voice-primary-button')),
          findsOneWidget,
        );
        expect(find.text('confirm:'), findsNothing);

        // 2차 시도: 사용자가 설정에서 권한을 허용한 뒤 같은 버튼으로 재시도.
        fakeStt.grantPermissionForNextAttempt();
        await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(fakeStt.listenCalls, 2);
        expect(find.text(deniedMessage), findsNothing);
        // 정상 인식된 텍스트가 확인 화면으로 전달된다(로컬 정제 규칙에 따라
        // 일부 문구가 다듬어질 수 있어 부분 문자열로 확인한다).
        expect(find.textContaining('회의'), findsWidgets);
      },
    );

    testWidgets(
      '거부된 상태에서도 사용자는 화면을 벗어나지 않고 키보드로 직접 입력할 수 있다',
      (tester) async {
        const deniedMessage =
            '마이크 권한이 없어요. 설정에서 권한을 허용한 뒤 다시 시도하거나 직접 입력으로 이어가 주세요.';
        final fakeStt = _PermissionGatedSttService(denialMessage: deniedMessage);

        await tester.pumpWidget(
          MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: false,
              sttService: fakeStt,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text(deniedMessage), findsOneWidget);

        // 권한 거부 후에도 원문 입력용 TextField는 여전히 조작 가능해야 한다.
        final transcriptField = find.byType(TextField);
        expect(transcriptField, findsOneWidget);
        await tester.enterText(transcriptField, '직접 입력한 일정 내용');
        await tester.pump();

        expect(find.text('직접 입력한 일정 내용'), findsOneWidget);
        // 직접 입력 중에는 여전히 STT를 다시 부르지 않는다(거부 상태
        // 이후 사용자가 명시적으로 재시도 버튼을 누르기 전까지는 조용히
        // 대기해야 한다 — 재요청 스팸 방지).
        expect(fakeStt.listenCalls, 1);
      },
    );
  });

  group(
    'FLOW6: PermissionOnboardingScreen — 마이크 권한 요청 UI 거부/재요청 분기',
    () {
      testWidgets(
        '마이크 권한 요청이 거부되면 안내 문구를 보여주고, 재요청해서 '
        '허용되면 허용 상태로 전환된다',
        (tester) async {
          SharedPreferencesAsyncPlatform.instance =
              InMemorySharedPreferencesAsync.empty();
          addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

          final permissionService = _MicPermissionOnboardingFake();

          await tester.pumpWidget(
            MaterialApp(
              home: PermissionOnboardingScreen(
                permissionService: permissionService,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final micTile = find.ancestor(
            of: find.text('마이크'),
            matching: find.byType(Card),
          );
          expect(micTile, findsOneWidget);

          await tester.tap(
            find.descendant(of: micTile, matching: find.text('요청')),
          );
          await tester.pumpAndSettle();

          expect(permissionService.microphoneRequestCalls, 1);
          expect(
            find.text(
              '마이크 권한이 아직 허용되지 않았습니다. 다시 요청하거나 Android 앱 설정에서 켜 주세요.',
            ),
            findsOneWidget,
          );

          // 재요청: 이번엔 (OS 설정에서 사용자가 직접 허용했다고 가정하고)
          // 허용된 상태를 반환한다.
          permissionService.microphoneGranted = true;
          await tester.tap(
            find.descendant(of: micTile, matching: find.text('요청')),
          );
          await tester.pumpAndSettle();

          expect(permissionService.microphoneRequestCalls, 2);
          expect(find.text('마이크 권한이 허용되었습니다.'), findsOneWidget);
        },
      );
    },
  );
}

/// `SttService`를 직접 서브클래싱해 마이크 권한 거부/허용 시나리오를
/// 재현하는 fake. iOS의 실제 `_listenWithSpeechToText` 경로가 권한 거부
/// 시 반환하는 형태(`SttListenFailure.permissionDenied`)를 그대로
/// 재현한다(`lib/services/stt_service.dart:1034-1041`).
class _PermissionGatedSttService extends SttService {
  _PermissionGatedSttService({required this.denialMessage});

  final String denialMessage;
  int listenCalls = 0;
  bool _granted = false;

  void grantPermissionForNextAttempt() {
    _granted = true;
  }

  @override
  Future<void> warmUp() async {}

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) async {
    listenCalls += 1;
    if (!_granted) {
      return SttListenResult.failure(
        failure: SttListenFailure.permissionDenied,
        message: denialMessage,
      );
    }
    return SttListenResult.success('내일 오전 10시 회의');
  }

  @override
  Future<void> cancelActiveListen() async {}

  @override
  Future<void> stopActiveListen() async {}
}

/// `PermissionOnboardingScreen`의 마이크 권한 타일 거부→재요청→허용 흐름을
/// 재현하는 fake. `checkAll()`을 완전히 오버라이드해 실제
/// `NotificationService`/배터리 최적화/캘린더 채널을 전혀 호출하지 않는다
/// (`test/screens/permission_onboarding_screen_test.dart`의
/// `_FakePermissionService` 패턴 재사용, 이번 시나리오에 필요한 최소
/// 부분집합만 구현).
class _MicPermissionOnboardingFake extends AppPermissionService {
  bool microphoneGranted = false;
  int microphoneRequestCalls = 0;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: microphoneGranted,
      locationGranted: true,
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
  Future<bool> requestMicrophonePermission() async {
    microphoneRequestCalls += 1;
    return microphoneGranted;
  }

  @override
  Future<void> markOnboardingCompleted(String userId) async {}
}
