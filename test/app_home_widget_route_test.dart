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
      resolveHomeWidgetRoute(Uri.parse('planflow-v2://voice-launcher')),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(
          Uri.parse('planflow-v2://voice-launcher?source=mic')),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow-v2://voice?autoStart=1')),
      '${AppRoutes.voice}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(
        Uri.parse('planflow-v2://voice-conversation?autoStart=1'),
      ),
      '${AppRoutes.voiceConversation}?autoStart=1',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow-v2://voice-conversation')),
      '${AppRoutes.voiceConversation}?autoStart=1',
    );
  });

  test('resolveHomeWidgetRoute maps calendar and event deep links', () {
    expect(
      resolveHomeWidgetRoute(
          Uri.parse('planflow-v2://calendar?date=2026-05-21')),
      '${AppRoutes.calendar}?date=2026-05-21',
    );
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow-v2://event/event-123')),
      '${AppRoutes.eventDetail}/event-123',
    );
    expect(
      resolveHomeWidgetRoute(
          Uri.parse('planflow-v2://event?eventId=event-456')),
      '${AppRoutes.eventDetail}/event-456',
    );
  });
}
