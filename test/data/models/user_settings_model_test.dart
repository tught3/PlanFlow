import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';

void main() {
  test('UserSettingsModel normalizes time values', () {
    final model = UserSettingsModel(
      id: 'settings-1',
      userId: 'user-1',
      morningBriefingAt: '07:30',
      eveningBriefingAt: '21:00',
      defaultReminderMin: 45,
      googleCalendarToken: 'google-token',
      naverCalendarToken: 'naver-token',
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final restored = UserSettingsModel.fromJson({
      ...model.toJson(),
      'morning_briefing_at': '07:30:00',
      'evening_briefing_at': '21:00:00',
    });

    expect(restored.id, model.id);
    expect(restored.userId, model.userId);
    expect(restored.morningBriefingAt, '07:30');
    expect(restored.eveningBriefingAt, '21:00');
    expect(restored.defaultReminderMin, model.defaultReminderMin);
    expect(restored.googleCalendarToken, model.googleCalendarToken);
    expect(restored.naverCalendarToken, model.naverCalendarToken);
    expect(restored.createdAt, model.createdAt);
  });
}
