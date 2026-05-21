import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/constants.dart';

void main() {
  test('resolveHomeWidgetRoute maps voice launcher and auto-start routes', () {
    expect(
      resolveHomeWidgetRoute(Uri.parse('planflow://voice-launcher')),
      AppRoutes.voiceLauncher,
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
}
