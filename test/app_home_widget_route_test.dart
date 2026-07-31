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
