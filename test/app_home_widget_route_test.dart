import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/home_widget_route_coordinator.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/providers/auth_provider.dart';

/// 테스트용 wake 신호: notifyListeners가 protected라 직접 호출 대신 서브클래스
/// 메서드로 노출한다. 프로덕션에서는 authProvider/startupRouteGate 병합
/// Listenable이 이 역할을 한다.
class _ManualWakeSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// coordinator 구동에 필요한 주입 지점을 모아 둔 하네스. 실제 앱이 주입하는
/// 것과 동일한 시그니처(readiness/navigate/currentUri/consume/onDeferred/
/// onTerminal)를 그대로 쓴다 — 네이티브 프로브도 같은 생성자를 쓴다.
class _Harness {
  final wake = _ManualWakeSignal();
  HomeWidgetRouteReadiness readiness = HomeWidgetRouteReadiness.notReady;
  Uri current = Uri.parse('/home');
  final navigated = <String>[];
  final consumed = <String>[];
  final deferredRoutes = <String>[];
  final deferredReadiness = <HomeWidgetRouteReadiness>[];
  final terminalRoutes = <String>[];
  final terminalOutcomes = <HomeWidgetRouteOutcome>[];

  late final HomeWidgetRouteCoordinator coordinator =
      HomeWidgetRouteCoordinator(
    readinessResolver: () => readiness,
    wakeSignal: wake,
    navigate: (route) {
      navigated.add(route);
      // 실제 라우터처럼 navigate 이후 current가 바뀐다. 테스트에서는
      // navigateSetsCurrent 플래그로 바운스/리다이렉트를 시뮬레이션한다.
      if (navigateSetsCurrent) {
        current = Uri.parse(route);
      }
    },
    currentUri: () => current,
    consume: (route) async {
      consumed.add(route);
    },
    onDeferred: (route, readiness) {
      deferredRoutes.add(route);
      deferredReadiness.add(readiness);
    },
    onTerminal: (route, outcome) {
      terminalRoutes.add(route);
      terminalOutcomes.add(outcome);
    },
    arrivalCheckInterval: arrivalCheckInterval,
    arrivalMaxAttempts: arrivalMaxAttempts,
    readinessTimeout: readinessTimeout,
    retainedRetryDelay: retainedRetryDelay,
    maxNavigationCycles: maxNavigationCycles,
  );

  bool navigateSetsCurrent = true;
  Duration arrivalCheckInterval = const Duration(milliseconds: 5);
  int arrivalMaxAttempts = 3;
  Duration readinessTimeout = const Duration(seconds: 15);
  Duration retainedRetryDelay = const Duration(seconds: 2);
  int maxNavigationCycles = 3;
}

void main() {
  test('app router overrides platform default deep link location', () {
    expect(appRouter.overridePlatformDefaultLocation, isTrue);
  });

  group('voice home-widget dedupe contract', () {
    test(
      'resolveHomeWidgetRoute canonicalizes repeated voice widget and deep-link inputs to the same auto-start route',
      () {
        const expectedVoiceRoute = '${AppRoutes.voice}?autoStart=1';

        expect(
          resolveHomeWidgetRoute(Uri.parse('planflow://voice-launcher')),
          expectedVoiceRoute,
        );
        expect(
          resolveHomeWidgetRoute(
            Uri.parse('planflow://voice-launcher?source=mic'),
          ),
          expectedVoiceRoute,
        );
        expect(
          resolveHomeWidgetRoute(Uri.parse('planflow://voice?autoStart=1')),
          expectedVoiceRoute,
        );
        expect(
          resolveHomeWidgetRoute(Uri.parse('planflow:///voice?autoStart=1')),
          expectedVoiceRoute,
        );
      },
    );

    test(
      'dedupes duplicate cold-start voice widget delivery before STT starts so a second identical route cannot restart voice and cancel auto-start',
      () {
        final startedAt = DateTime(2026, 7, 31, 9);
        const route = '${AppRoutes.voice}?autoStart=1';

        expect(
          shouldIgnoreDuplicateHomeWidgetRoute(
            route: route,
            previousRoute: route,
            previousHandledAt: startedAt,
            now: startedAt.add(const Duration(milliseconds: 800)),
          ),
          isTrue,
        );
        expect(
          shouldIgnoreDuplicateHomeWidgetRoute(
            route: route,
            previousRoute: route,
            previousHandledAt: startedAt,
            now: startedAt.add(const Duration(seconds: 3)),
          ),
          isFalse,
        );
      },
    );
  });

  test('resolveHomeWidgetRoute maps voice conversation routes', () {
    expect(
      resolveHomeWidgetRoute(
        Uri.parse('planflow://voice-conversation?autoStart=1'),
      ),
      '${AppRoutes.voiceConversation}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://voice-conversation')),
      '${AppRoutes.voiceConversation}?autoStart=1',
    );
  });

  test('resolveHomeWidgetRoute maps calendar and event deep links', () {
    expect(
      resolveHomeWidgetRoute(
          Uri.parse('planflow://calendar?date=2026-05-21')),
      '${AppRoutes.calendar}?date=2026-05-21',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://event/event-123')),
      '${AppRoutes.eventDetail}/event-123',
    );
    expect(
      resolveHomeWidgetRoute(
          Uri.parse('planflow://event?eventId=event-456')),
      '${AppRoutes.eventDetail}/event-456',
    );
  });

  test('resolveHomeWidgetRoute maps canonical schedule and day routes', () {
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://schedule/e1')),
      '${AppRoutes.eventDetail}/e1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://day/2026-09-03')),
      '${AppRoutes.calendar}?date=2026-09-03',
    );
    expect(resolveHomeWidgetRoute(Uri.parse('planflow://day/2026-99-99')), isNull);
  });

  test(
      'resolveHomeWidgetRoute maps group calendar links, carrying date '
      'through so a widget day-cell tap opens that date (not always today)',
      () {
    expect(
      resolveHomeWidgetRoute(
        Uri.parse('planflow://group-calendar?groupId=group-1'),
      ),
      '${AppRoutes.groupEventsForId('group-1')}?groupId=group-1',
    );
    expect(
      resolveHomeWidgetRoute(
        Uri.parse(
          'planflow://group-calendar?groupId=group-1&date=2026-07-15',
        ),
      ),
      '${AppRoutes.groupEventsForId('group-1')}?groupId=group-1&date=2026-07-15',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://group-calendar')),
      AppRoutes.groupEvents,
    );
  });

  test('resolveHomeWidgetRoute maps group invite links', () {
    expect(
      resolveHomeWidgetRoute(
        Uri.parse('planflow://group-invite?groupId=group-1&token=abc123'),
      ),
      '${AppRoutes.groupInviteLink}?groupId=group-1&token=abc123',
    );
  });

  group(
    'confirmed-only consumption contract (replaces P5R consume-on-givingUp)',
    () {
      // 타임아웃/도착 실패는 절대 성공/소비가 아니다. givingUp은 pending을
      // RETAINED로 보존하고 소비 신호를 내지 않는다. 소비는 confirmed에서만
      // 정확히 1회다.
      const maxAttempts = 10;

      int countConsumeInvocationsForArrivalSequence(
        List<bool> arrivedPerAttempt,
      ) {
        var consumeCallCount = 0;
        for (var attempt = 0; attempt < arrivedPerAttempt.length; attempt++) {
          final result = resolveHomeWidgetArrivalCheckResult(
            arrived: arrivedPerAttempt[attempt],
            attempt: attempt,
            maxAttempts: maxAttempts,
          );
          if (shouldConsumeHomeWidgetLaunch(result)) {
            consumeCallCount++;
          }
          if (result != HomeWidgetArrivalCheckResult.retrying) {
            break;
          }
        }
        return consumeCallCount;
      }

      test(
        '모든 attempt가 실패해 givingUp으로 끝나면 소비 신호는 0회다 '
        '— givingUp이 소비/clear를 만들지 않고 pending을 보존한다',
        () {
          final alwaysFailing = List<bool>.filled(maxAttempts + 1, false);
          expect(
            countConsumeInvocationsForArrivalSequence(alwaysFailing),
            0,
          );
        },
      );

      test(
        '도착이 확인되면 소비 신호는 정확히 1회다 — 재시도 횟수와 무관하게 '
        'confirmed에서 루프가 끝나므로 중복 소비가 없다',
        () {
          final arrivesOnFourthAttempt = <bool>[
            false,
            false,
            false,
            true,
          ];
          expect(
            countConsumeInvocationsForArrivalSequence(arrivesOnFourthAttempt),
            1,
          );
          expect(
            countConsumeInvocationsForArrivalSequence(const [true]),
            1,
          );
        },
      );

      test(
        'retrying 동안에는 절대 소비되지 않고, 소비는 confirmed에서만이다',
        () {
          for (var attempt = 0; attempt < maxAttempts; attempt++) {
            final result = resolveHomeWidgetArrivalCheckResult(
              arrived: false,
              attempt: attempt,
              maxAttempts: maxAttempts,
            );
            expect(result, HomeWidgetArrivalCheckResult.retrying);
            expect(shouldConsumeHomeWidgetLaunch(result), isFalse);
          }
          expect(
            shouldConsumeHomeWidgetLaunch(
              HomeWidgetArrivalCheckResult.givingUp,
            ),
            isFalse,
          );
          expect(
            shouldConsumeHomeWidgetLaunch(
              HomeWidgetArrivalCheckResult.confirmed,
            ),
            isTrue,
          );
        },
      );
    },
  );

  group('shouldSeedHomeBaseForHomeWidgetRoute', () {
    test(
      '콜드스타트(뒤로갈 스택 없음)면 홈을 먼저 깔아야 한다(true) — '
      '그래야 뒤로가기 시 앱 종료 대신 홈으로 pop된다',
      () {
        expect(
          shouldSeedHomeBaseForHomeWidgetRoute(
            route: AppRoutes.groupEventsForId('group-1'),
            canPop: false,
          ),
          isTrue,
        );
      },
    );

    test(
      '이미 정상 스택이 있으면(canPop=true) 홈으로 초기화하지 않는다(false) '
      '— 호출부는 기존 스택 위에 push만 한다',
      () {
        expect(
          shouldSeedHomeBaseForHomeWidgetRoute(
            route: AppRoutes.groupEventsForId('group-1'),
            canPop: true,
          ),
          isFalse,
        );
      },
    );

    test('목표가 이미 홈 라우트면 스택 없이도 홈을 다시 깔 필요 없다(false)', () {
      expect(
        shouldSeedHomeBaseForHomeWidgetRoute(
          route: AppRoutes.home,
          canPop: false,
        ),
        isFalse,
      );
    });
  });

  group('queryParametersEqual (semantic, order-independent)', () {
    test('두 빈 맵은 같다', () {
      expect(queryParametersEqual({}, {}), isTrue);
    });

    test('키/값이 모두 같고 순서만 다르면 같다 (Map.toString 안정성 회피)', () {
      final a = <String, String>{'date': '2026-05-21', 'autoStart': '1'};
      final b = <String, String>{'autoStart': '1', 'date': '2026-05-21'};
      expect(queryParametersEqual(a, b), isTrue);
      expect(queryParametersEqual(b, a), isTrue);
    });

    test('키가 다르면 다르다', () {
      expect(
        queryParametersEqual({'date': '2026-05-21'}, {'day': '2026-05-21'}),
        isFalse,
      );
    });

    test('값이 다르면 다르다 (wrong-date arrival 감지)', () {
      expect(
        queryParametersEqual(
          <String, String>{'date': '2026-05-21'},
          <String, String>{'date': '2026-05-22'},
        ),
        isFalse,
      );
    });

    test('키 개수가 다르면 다르다', () {
      expect(
        queryParametersEqual({'date': '2026-05-21'}, {}),
        isFalse,
      );
      expect(
        queryParametersEqual(
          {'date': '2026-05-21'},
          {'date': '2026-05-21', 'autoStart': '1'},
        ),
        isFalse,
      );
    });

    test('identical reference는 항상 같다 (early-out)', () {
      const same = <String, String>{'date': '2026-05-21'};
      expect(queryParametersEqual(same, same), isTrue);
    });
  });

  group('HomeWidgetRouteCoordinator (pending-route owner, injected seam)', () {
    test(
      'deferral: notReady면 네비게이션 없이 대기하고, ready wake 즉시 단 1회 '
      'navigate 후 도착을 확인해 confirmed가 된다 — 소비도 정확히 1회',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);

        final outcome = h.coordinator.submitRoute(
          '${AppRoutes.voice}?autoStart=1',
        );
        expect(h.coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);
        expect(h.coordinator.hasPendingRoute, isTrue);
        expect(h.navigated, isEmpty);

        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);

        expect(h.navigated, ['${AppRoutes.voice}?autoStart=1']);
        expect(h.consumed, ['${AppRoutes.voice}?autoStart=1']);
        expect(h.coordinator.pendingRoute, isNull);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.confirmed);
        expect(h.terminalOutcomes, [HomeWidgetRouteOutcome.confirmed]);
      },
    );

    test(
      '(genuine slow readiness >1.2s) readiness가 1.3초 뒤에 와도 pending은 '
      '그대로 보존되며, 도착 확인(1.2초)이 먼저 고갈되지 않는다',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.calendar}?date=2026-05-21';

        final outcome = h.coordinator.submitRoute(route);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);

        // 도착 확인 루프 전체 길이(1.2초)보다 길게 대기해도 ready 신호가
        // 없으면 아무 내비게이션/소비가 없고 pending은 살아 있다.
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        expect(h.navigated, isEmpty);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.hasPendingRoute, isTrue);
        expect(h.coordinator.pendingRoute, route);

        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(h.navigated, [route]);
        expect(h.consumed, [route]);
      },
    );

    test(
      '(readiness timeout never consumes) 상한을 넘겨도 소비 없이 RETAINED로 '
      '전환되며, 이후 ready wake로 재시도된다',
      () async {
        final h = _Harness()
          ..readinessTimeout = const Duration(milliseconds: 60);
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        final outcome = h.coordinator.submitRoute(route);
        await Future<void>.delayed(const Duration(milliseconds: 120));

        // 타임아웃 => 성공/소비가 아니라 RETAINED 보존이다.
        expect(h.coordinator.phase, HomeWidgetRoutePhase.retained);
        expect(h.coordinator.hasPendingRoute, isTrue);
        expect(h.navigated, isEmpty);
        expect(h.consumed, isEmpty);
        expect(h.terminalOutcomes, [HomeWidgetRouteOutcome.givingUp]);

        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(h.navigated, [route]);
        expect(h.consumed, [route]);
      },
    );

    test(
      '(signedout -> login -> signedin replay) resolved-signed-out에서는 '
      'needsAuth 신호만 보내고 절대 네비게이션하지 않으며, 로그인 성공(ready '
      '전환) 후 같은 pending으로 정확히 1회 재시도한다',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        h.readiness = HomeWidgetRouteReadiness.needsAuth;
        final outcome = h.coordinator.submitRoute(route);
        expect(h.navigated, isEmpty);
        expect(h.deferredReadiness, [HomeWidgetRouteReadiness.needsAuth]);

        // 로그인 화면에서 재평가가 여러 번 돌아도(auth/gate 변화) 네비게이션은
        // 없다. 보호 화면 우회 없음.
        h.wake.fire();
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.navigated, isEmpty);
        expect(h.coordinator.hasPendingRoute, isTrue);

        // 로그인 성공: signedIn 전이.
        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(h.navigated, [route]);
        expect(h.consumed, [route]);
      },
    );

    test(
      '(onboarding hold/replay) 온보딩 동안 notReady 이벤트가 여러 번 와도 '
      '네비게이션 없이 대기하고, 완료 후 한 번만 navigate한다',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.calendar}?date=2026-05-21';

        final outcome = h.coordinator.submitRoute(route);
        // 온보딩 중 gate/auth 이벤트 여러 번.
        h.wake.fire();
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.navigated, isEmpty);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);

        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(h.navigated, [route]);
      },
    );

    test(
      '(givingUp retention then retry) 도착 확인이 고갈되면 소비 없이 '
      'RETAINED로 보존되고, 다음 wake에서 재시도해 confirmed로 끝난다 — '
      '재시도 시점에 이미 목적지에 도착해 있으면 재-navigation 없이 확인만 한다',
      () async {
        final h = _Harness()
          ..arrivalMaxAttempts = 2
          ..retainedRetryDelay = const Duration(milliseconds: 500);
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        // 1차: navigate는 했지만 라우터 바운스(로그인/온보딩 커버)로 목적지
        // 미도달 -> givingUp. 소비 없음, pending 보존.
        h.readiness = HomeWidgetRouteReadiness.ready;
        h.navigateSetsCurrent = false; // 바운스: current가 목적지로 안 감
        final outcome = h.coordinator.submitRoute(route);
        expect(await outcome, HomeWidgetRouteOutcome.givingUp);
        expect(h.navigated, [route]);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.retained);
        expect(h.coordinator.pendingRoute, route);
        expect(h.terminalOutcomes, [HomeWidgetRouteOutcome.givingUp]);

        // 바운스 해제(온보딩 종료/로그인 완료로 목적지 노출) + wake.
        // 이미 목적지(쿼리 포함 정확한 route)에 도달해 있는 상태다.
        h.navigateSetsCurrent = true;
        h.current = Uri.parse(route);
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        // 재시도: 이미 목적지라 재-navigation 없이 확인만 하고 confirmed.
        expect(h.navigated, [route]);
        expect(h.consumed, [route]);
        expect(h.coordinator.pendingRoute, isNull);
        expect(h.terminalOutcomes.last, HomeWidgetRouteOutcome.confirmed);
      },
    );

    test(
      '(wrong-date not confirm) /calendar?date=2026-05-21인데 현재가 '
      '2026-05-22면 끝까지 미확인으로 givingUp — 소비/포기 없이 date 보존',
      () async {
        final h = _Harness()
          ..arrivalMaxAttempts = 2
          ..navigateSetsCurrent = false;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.calendar}?date=2026-05-21';
        h.current = Uri.parse('${AppRoutes.calendar}?date=2026-05-22');

        h.readiness = HomeWidgetRouteReadiness.ready;
        final outcome = h.coordinator.submitRoute(route);
        expect(await outcome, HomeWidgetRouteOutcome.givingUp);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.retained);
        expect(h.coordinator.pendingRoute, route);
      },
    );

    test(
      '(voice autoStart exact query) /voice?autoStart=1인데 query 없이 '
      '/voice에 머물면 미확인으로 retained — autoStart 유실 없음',
      () async {
        final h = _Harness()
          ..arrivalMaxAttempts = 1
          ..navigateSetsCurrent = false;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';
        h.current = Uri.parse(AppRoutes.voice);

        h.readiness = HomeWidgetRouteReadiness.ready;
        final outcome = h.coordinator.submitRoute(route);
        expect(await outcome, HomeWidgetRouteOutcome.givingUp);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.pendingRoute, route);
      },
    );

    test(
      '(warm repeats/new superseding requests) 진행 중 pending에 새 요청이 '
      '오면 이전 generation은 cancelled로 끝나고 새 요청만 네비게이션된다',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);

        final first = h.coordinator
            .submitRoute('${AppRoutes.calendar}?date=2026-05-21');
        expect(h.coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);

        h.readiness = HomeWidgetRouteReadiness.ready;
        final second =
            h.coordinator.submitRoute('${AppRoutes.voice}?autoStart=1');
        expect(await first, HomeWidgetRouteOutcome.cancelled);
        expect(await second, HomeWidgetRouteOutcome.confirmed);

        expect(h.navigated, ['${AppRoutes.voice}?autoStart=1']);
        expect(h.consumed, ['${AppRoutes.voice}?autoStart=1']);
      },
    );

    test(
      '(no duplicate navigation) 도착 확인(verifyingArrival) 중에 wake가 여러 '
      '번 와도 navigate는 재진입하지 않는다 — cycle당 exactly-once',
      () async {
        final h = _Harness()
          ..arrivalCheckInterval = const Duration(milliseconds: 30)
          ..navigateSetsCurrent = false;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        h.readiness = HomeWidgetRouteReadiness.ready;
        final outcome = h.coordinator.submitRoute(route);
        expect(h.navigated, [route]);

        // 확인 진행 중 wake 스팸.
        h.wake.fire();
        h.wake.fire();
        h.wake.fire();

        expect(await outcome, HomeWidgetRouteOutcome.givingUp);
        expect(h.navigated, [route]);
      },
    );

    test(
      '(bounded navigation cap) retained 재시도도 maxNavigationCycles를 넘지 '
      '않는다 — watchdog과 wake가 계속 와도 navigate 총횟수는 cap에 갇힌다',
      () async {
        final h = _Harness()
          ..navigateSetsCurrent = false
          ..arrivalMaxAttempts = 1
          ..retainedRetryDelay = const Duration(milliseconds: 20)
          ..maxNavigationCycles = 2;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        h.readiness = HomeWidgetRouteReadiness.ready;
        final outcome = h.coordinator.submitRoute(route);
        expect(await outcome, HomeWidgetRouteOutcome.givingUp);

        // watchdog 재시도(20ms) + wake 스패ム 후에도 cap(2)을 넘지 않는다.
        h.wake.fire();
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(h.navigated.length, 2);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.pendingRoute, route);
      },
    );

    test(
      '(timeout releases startup gate) readinessTimeout 후 actual '
      'StartupRouteGate.widgetLaunchPending이 false가 되고 pending은 보존, '
      '소비 0, 게이트 self-notify로 재진입/타이머 재무장 없음',
      () async {
        final gate = StartupRouteGate();
        addTearDown(gate.dispose);
        final terminals = <HomeWidgetRouteOutcome>[];
        var consumeCalls = 0;
        final coordinator = HomeWidgetRouteCoordinator(
          readinessResolver: () => HomeWidgetRouteReadiness.notReady,
          wakeSignal: gate,
          navigate: (_) => fail('must not navigate while notReady'),
          currentUri: () => Uri.parse('/'),
          consume: (_) async => consumeCalls++,
          onTerminal: (route, outcome) {
            terminals.add(outcome);
            if (outcome == HomeWidgetRouteOutcome.givingUp) {
              gate.completeWidgetLaunch();
            }
          },
          readinessTimeout: const Duration(milliseconds: 40),
        );
        addTearDown(coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';

        gate.beginWidgetLaunch();
        expect(gate.widgetLaunchPending, isTrue);
        unawaited(coordinator.submitRoute(route));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(gate.widgetLaunchPending, isFalse);
        expect(gate.suppressLoginRedirects, isFalse);
        expect(coordinator.pendingRoute, route);
        expect(coordinator.phase, HomeWidgetRoutePhase.retained);
        expect(consumeCalls, 0);
        expect(terminals, [HomeWidgetRouteOutcome.givingUp]);

        // 이후 wake가 와도 타임아웃이 다시 무장되지 않는다.
        gate.beginWidgetLaunch();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(terminals.length, 1);
        expect(coordinator.pendingRoute, route);
        expect(consumeCalls, 0);
      },
    );

    test(
      '(cap + late exact arrival) cap 도달 후 정확한 path+query로 늦게 '
      '도착하면 confirmed + 소비 1회, wrong-date는 확인되지 않는다',
      () async {
        final h = _Harness()
          ..navigateSetsCurrent = false
          ..arrivalMaxAttempts = 1
          ..retainedRetryDelay = const Duration(milliseconds: 15)
          ..maxNavigationCycles = 2;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.calendar}?date=2026-05-21';
        h.readiness = HomeWidgetRouteReadiness.ready;
        expect(await h.coordinator.submitRoute(route),
            HomeWidgetRouteOutcome.givingUp);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(h.navigated.length, 2);

        h.current = Uri.parse('${AppRoutes.calendar}?date=2026-05-20');
        h.coordinator.notifyLocationChanged();
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(h.consumed, isEmpty);
        expect(h.navigated.length, 2);
        expect(h.coordinator.pendingRoute, route);

        h.current = Uri.parse(route);
        h.coordinator.notifyLocationChanged();
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(h.consumed, [route]);
        expect(h.navigated.length, 2);
        expect(h.coordinator.pendingRoute, isNull);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.confirmed);
      },
    );

    test(
      '(cap + explicit kick) cap 도달 후 kick은 한 사이클만 새로 허용하고 '
      'kick 스톰은 maxBudgetGrants로 상한된다',
      () async {
        final h = _Harness()
          ..navigateSetsCurrent = false
          ..arrivalMaxAttempts = 1
          ..retainedRetryDelay = const Duration(milliseconds: 15)
          ..maxNavigationCycles = 2;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';
        h.readiness = HomeWidgetRouteReadiness.ready;
        await h.coordinator.submitRoute(route);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.navigated.length, 2);

        h.coordinator.kickPendingRoute();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.navigated.length, 3);
        expect(h.consumed, isEmpty);

        for (var i = 0; i < 20; i++) {
          h.coordinator.kickPendingRoute();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(h.navigated.length, lessThanOrEqualTo(5));
        expect(h.consumed, isEmpty);
        expect(h.coordinator.pendingRoute, route);
      },
    );

    test(
      '(cap + new readiness) cap 도달 후 not-ready -> ready 전환(온보딩 '
      '완료)은 제한된 새 사이클을 열어 도착/소비로 이어진다',
      () async {
        final h = _Harness()
          ..navigateSetsCurrent = false
          ..arrivalMaxAttempts = 1
          ..retainedRetryDelay = const Duration(milliseconds: 15)
          ..maxNavigationCycles = 2;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';
        h.readiness = HomeWidgetRouteReadiness.ready;
        await h.coordinator.submitRoute(route);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.navigated.length, 2);

        h.readiness = HomeWidgetRouteReadiness.notReady;
        h.wake.fire();
        expect(h.navigated.length, 2);

        h.navigateSetsCurrent = true;
        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(h.navigated.length, 3);
        expect(h.consumed, [route]);
        expect(h.coordinator.pendingRoute, isNull);
      },
    );

    test(
      '(wake storm bounds) cap 도달 후 generic wake/location 스톰은 navigate '
      '예산을 리셋하지 않는다',
      () async {
        final h = _Harness()
          ..navigateSetsCurrent = false
          ..arrivalMaxAttempts = 1
          ..retainedRetryDelay = const Duration(milliseconds: 15)
          ..maxNavigationCycles = 2;
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';
        h.readiness = HomeWidgetRouteReadiness.ready;
        await h.coordinator.submitRoute(route);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.navigated.length, 2);

        for (var i = 0; i < 200; i++) {
          h.wake.fire();
          h.coordinator.notifyLocationChanged();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(h.navigated.length, 2);
        expect(h.consumed, isEmpty);
        expect(h.coordinator.pendingRoute, route);
      },
    );

    test(
      '(cancel cleans timers/listeners) cancel하면 pending이 비대고 outcome은 '
      'cancelled이며, 이후 wake가 와도 아무 동작 없다',
      () async {
        final h = _Harness();
        final outcome =
            h.coordinator.submitRoute('${AppRoutes.voice}?autoStart=1');
        expect(h.coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);

        h.coordinator.cancel();
        expect(await outcome, HomeWidgetRouteOutcome.cancelled);
        expect(h.coordinator.pendingRoute, isNull);
        expect(h.coordinator.phase, HomeWidgetRoutePhase.idle);
        expect(h.coordinator.isWaiting, isFalse);

        // 리스너 제거 확인: 이후 ready + wake도 무시된다.
        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.navigated, isEmpty);
        expect(h.consumed, isEmpty);
      },
    );

    test(
      '(dispose cleans timers/listeners) dispose 후 pending이 비대고 이후 '
      '이벤트로 상태가 변하지 않는다',
      () async {
        final h = _Harness();
        final outcome =
            h.coordinator.submitRoute('${AppRoutes.calendar}?date=2026-05-21');
        h.coordinator.dispose();
        expect(await outcome, HomeWidgetRouteOutcome.cancelled);
        expect(h.coordinator.pendingRoute, isNull);
        expect(h.coordinator.isWaiting, isFalse);

        h.readiness = HomeWidgetRouteReadiness.ready;
        h.wake.fire();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.navigated, isEmpty);
      },
    );

    test(
      '(already-at-target skips navigation) 이미 목적지에 도착한 상태에서 '
      'submit하면 navigate 없이 도착 확인만 하고 confirmed가 된다 — 중복 '
      'push(STT 취소) 방지',
      () async {
        final h = _Harness();
        addTearDown(h.coordinator.dispose);
        const route = '${AppRoutes.voice}?autoStart=1';
        h.current = Uri.parse(route);
        h.readiness = HomeWidgetRouteReadiness.ready;

        final outcome = h.coordinator.submitRoute(route);
        expect(h.navigated, isEmpty);
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(h.consumed, [route]);
      },
    );

    test(
      '(production listenables plug in) 실제 AuthProvider/StartupRouteGate '
      '병합 Listenable이 wakeSignal로 동작한다 — 네이티브 프로브가 fake '
      'readiness로 같은 생성자를 쓰는 것과 동일한 시임',
      () async {
        final authProvider = AuthProvider();
        final gate = StartupRouteGate();
        addTearDown(gate.dispose);
        final navigated = <String>[];
        // 실제 라우터처럼 current는 navigate에 의해 목적지로 바뀐다. 시작
        // 위치는 목적지가 아니어야 wake -> navigate -> confirmed 경로가
        // 관측된다(이미 목적지면 already-at-target skip으로 navigate가
        // 아예 불리지 않는다).
        var current = Uri.parse('/');
        final coordinator = HomeWidgetRouteCoordinator(
          readinessResolver: () => gate.widgetLaunchPending
              ? HomeWidgetRouteReadiness.ready
              : HomeWidgetRouteReadiness.notReady,
          wakeSignal: Listenable.merge(<Listenable>[authProvider, gate]),
          navigate: (route) {
            navigated.add(route);
            current = Uri.parse(route);
          },
          currentUri: () => current,
          consume: (route) async {},
          arrivalCheckInterval: const Duration(milliseconds: 5),
          arrivalMaxAttempts: 2,
        );
        addTearDown(coordinator.dispose);

        final outcome =
            coordinator.submitRoute('${AppRoutes.voice}?autoStart=1');
        expect(coordinator.phase, HomeWidgetRoutePhase.waitingReadiness);

        gate.beginWidgetLaunch(); // notifyListeners -> wake
        expect(await outcome, HomeWidgetRouteOutcome.confirmed);
        expect(navigated, ['${AppRoutes.voice}?autoStart=1']);
      },
    );
  });

  group('(wrong-date arrival) calendar route arrival detection', () {
    test(
      'pending /calendar?date=2026-05-21 인데 현재 URI가 /calendar?date=2026-05-22면 '
      '도착 확인 실패(미확인 유지)',
      () {
        const route = '${AppRoutes.calendar}?date=2026-05-21';
        final current = Uri.parse('${AppRoutes.calendar}?date=2026-05-22');
        final expected = Uri.parse(route);

        final arrival = resolveHomeWidgetArrivalCheckResult(
          arrived: current.path == expected.path &&
              queryParametersEqual(
                current.queryParameters,
                expected.queryParameters,
              ),
          attempt: 0,
          maxAttempts: 10,
        );

        expect(arrival, HomeWidgetArrivalCheckResult.retrying);
      },
    );

    test(
      '같은 path지만 query가 일치하면 도착 확인 성공',
      () {
        const route = '${AppRoutes.calendar}?date=2026-05-21';
        final current = Uri.parse('${AppRoutes.calendar}?date=2026-05-21');
        final expected = Uri.parse(route);

        final arrival = resolveHomeWidgetArrivalCheckResult(
          arrived: current.path == expected.path &&
              queryParametersEqual(
                current.queryParameters,
                expected.queryParameters,
              ),
          attempt: 0,
          maxAttempts: 10,
        );

        expect(arrival, HomeWidgetArrivalCheckResult.confirmed);
      },
    );
  });

  group('(voice1x1 -> voice input autoStart) widget -> router -> screen wiring', () {
    test(
      'planflow://voice-launcher는 /voice?autoStart=1로 정규화되어 '
      'VoiceInputScreen(autoStartOverride=true)이 STT를 자동 시작한다',
      () {
        expect(
          resolveHomeWidgetRoute(Uri.parse('planflow://voice-launcher')),
          '${AppRoutes.voice}?autoStart=1',
        );
      },
    );

    test(
      'planflow://voice?autoStart=1 (deep link)도 동일 라우트로 정규화된다',
      () {
        expect(
          resolveHomeWidgetRoute(Uri.parse('planflow://voice?autoStart=1')),
          '${AppRoutes.voice}?autoStart=1',
        );
      },
    );
  });

  group('(repeated/new request/dedupe) generation bump on new route', () {
    test(
      '동일 route가 2초 내로 두 번 들어오면 shouldIgnoreDuplicateHomeWidgetRoute가 '
      '두 번째를 무시한다 (이미 진행 중인 STT/voice 세션을 보호)',
      () {
        final startedAt = DateTime(DateTime.now().year + 1, 7, 31, 9);
        const route = '${AppRoutes.voice}?autoStart=1';
        expect(
          shouldIgnoreDuplicateHomeWidgetRoute(
            route: route,
            previousRoute: route,
            previousHandledAt: startedAt,
            now: startedAt.add(const Duration(milliseconds: 500)),
          ),
          isTrue,
        );
      },
    );

    test(
      '다른 route가 들어오면 shouldIgnoreDuplicateHomeWidgetRoute는 false를 반환한다 '
      '— 호출부는 새 generation으로 bump해 이전 arrival check를 취소한다',
      () {
        final startedAt = DateTime(DateTime.now().year + 1, 7, 31, 9);
        expect(
          shouldIgnoreDuplicateHomeWidgetRoute(
            route: AppRoutes.calendar,
            previousRoute: '${AppRoutes.voice}?autoStart=1',
            previousHandledAt: startedAt,
            now: startedAt.add(const Duration(milliseconds: 100)),
          ),
          isFalse,
        );
      },
    );

    test(
      '2초 억제 창이 지나면 동일 route도 다시 라우팅된다',
      () {
        final startedAt = DateTime(DateTime.now().year + 1, 7, 31, 9);
        const route = '${AppRoutes.voice}?autoStart=1';
        expect(
          shouldIgnoreDuplicateHomeWidgetRoute(
            route: route,
            previousRoute: route,
            previousHandledAt: startedAt,
            now: startedAt.add(const Duration(seconds: 3)),
          ),
          isFalse,
        );
      },
    );
  });

  group('(retry probe exception catch) initial probe + retry 모두 안전', () {
    test(
      'resolveHomeWidgetRoute가 null URI/잘못된 scheme을 안전하게 거부해 '
      '잘못된 URI가 retry probe에서도 같은 null을 반환한다',
      () {
        expect(resolveHomeWidgetRoute(null), isNull);
        expect(
          resolveHomeWidgetRoute(Uri.parse('https://example.com')),
          isNull,
        );
      },
    );
  });
}
