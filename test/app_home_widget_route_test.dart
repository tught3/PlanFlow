import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/router.dart';

void main() {
  test('app router overrides platform default deep link location', () {
    expect(appRouter.overridePlatformDefaultLocation, isTrue);
  });

  test('resolveHomeWidgetRoute maps voice launcher and auto-start routes', () {
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://voice-launcher')),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://voice-launcher?source=mic')),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://voice?autoStart=1')),
      '${AppRoutes.voice}?autoStart=1',
    );
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
      resolveHomeWidgetRoute(Uri.parse('planflow://calendar?date=2026-05-21')),
      '${AppRoutes.calendar}?date=2026-05-21',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://event/event-123')),
      '${AppRoutes.eventDetail}/event-123',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://event?eventId=event-456')),
      '${AppRoutes.eventDetail}/event-456',
    );
  });

  test('routePathMatchesExpectedRoute does not throw for custom-scheme URI',
      () {
    expect(
      routePathMatchesExpectedRoute(
        Uri.parse('planflow://voice-launcher'),
        AppRoutes.voice,
      ),
      isFalse,
    );
  });

  test('normalizePlatformRouteInformation maps app scheme before GoRouter', () {
    expect(
      normalizePlatformRouteInformation(
        Uri.parse('planflow://voice-launcher'),
      ),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      normalizePlatformRouteInformation(
        Uri.parse('planflow://auth-callback?code=sample'),
      ),
      isNull,
    );
    expect(
      normalizePlatformRouteInformation(
        Uri.parse('https://example.com/calendar'),
      ),
      isNull,
    );
  });
}
