import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/router.dart';

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

  group('P5: native intent consume only fires once, only on arrival', () {
    // _applyPendingHomeWidgetRoute의 arrival-check 콜백은
    // resolveHomeWidgetArrivalCheckResult()의 반환값 하나로만 분기하고,
    // _consumeHomeWidgetLaunch() 호출 여부는 오직
    // shouldConsumeHomeWidgetLaunch(그 반환값)로 결정된다. 즉 이 두 순수
    // 함수를 실제 재시도 루프와 동일한 방식(attempt 0부터 maxAttempts까지
    // 순차 증가, arrived==true 또는 attempt>=maxAttempts에서 종료)으로
    // 구동하면 consume이 몇 번 호출될지를 코드 변경 없이 정확히 관측할 수
    // 있다.
    const maxAttempts = 10;

    // 실제 _applyPendingHomeWidgetRoute의 재귀 재시도를 그대로 모사한다:
    // 매 attempt마다 arrived 여부를 확인하고, confirmed/givingUp에서
    // 종료, retrying이면 attempt+1로 계속한다.
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
          // confirmed 또는 givingUp이면 실제 코드도 더 이상 재시도하지
          // 않고 종료한다.
          break;
        }
      }
      return consumeCallCount;
    }

    test(
      '도착 확인이 끝까지 실패하면(모든 attempt에서 arrived=false, '
      'maxAttempts 도달로 givingUp) _consumeHomeWidgetLaunch에 대응하는 '
      '소비 신호가 단 한 번도 발생하지 않는다 — intent가 살아있어야 '
      '_resumeHomeWidgetCheck()가 나중에 재시도할 수 있다',
      () {
        final alwaysFailing = List<bool>.filled(maxAttempts + 1, false);

        expect(
          countConsumeInvocationsForArrivalSequence(alwaysFailing),
          0,
        );

        // 개별 attempt 단위로도 확인: 실패 중인 동안(attempt < maxAttempts)
        // 은 retrying이고, maxAttempts에 도달하면 givingUp이다 — 둘 다
        // consume을 승인하지 않는다.
        for (var attempt = 0; attempt <= maxAttempts; attempt++) {
          final result = resolveHomeWidgetArrivalCheckResult(
            arrived: false,
            attempt: attempt,
            maxAttempts: maxAttempts,
          );
          expect(
            result,
            attempt < maxAttempts
                ? HomeWidgetArrivalCheckResult.retrying
                : HomeWidgetArrivalCheckResult.givingUp,
          );
          expect(shouldConsumeHomeWidgetLaunch(result), isFalse);
        }
      },
    );

    test(
      '중간 재시도 끝에 도착이 확인되면(arrived=true) '
      '_consumeHomeWidgetLaunch에 대응하는 소비 신호가 정확히 1회만 '
      '발생한다 — 여러 번 재시도했더라도 confirmed에 도달하는 순간 루프가 '
      '종료되므로 중복 소비가 없다',
      () {
        // attempt 0~2는 실패, attempt 3에서 도착 확인.
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

        // 첫 시도부터 바로 도착하는 경우도 정확히 1회.
        expect(
          countConsumeInvocationsForArrivalSequence(const [true]),
          1,
        );

        // resolveHomeWidgetArrivalCheckResult 자체도 arrived=true면
        // attempt 값과 무관하게 항상 confirmed이고, 오직 confirmed에서만
        // shouldConsumeHomeWidgetLaunch가 true다(=consume 승인 지점은
        // 이 한 곳뿐).
        for (final attempt in [0, 1, 5, maxAttempts, maxAttempts + 3]) {
          final result = resolveHomeWidgetArrivalCheckResult(
            arrived: true,
            attempt: attempt,
            maxAttempts: maxAttempts,
          );
          expect(result, HomeWidgetArrivalCheckResult.confirmed);
          expect(shouldConsumeHomeWidgetLaunch(result), isTrue);
        }
      },
    );
  });

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
}
