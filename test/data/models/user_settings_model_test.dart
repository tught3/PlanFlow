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
      prepTimeMin: 45,
      prepPreAlarmOffset: 10,
      departPreAlarmOffset: 0,
      travelMode: 'transit',
      voiceAutoStart: false,
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
    expect(restored.prepTimeMin, 45);
    expect(restored.prepPreAlarmOffset, 10);
    expect(restored.departPreAlarmOffset, 0);
    expect(restored.travelMode, 'transit');
    expect(restored.voiceAutoStart, isFalse);
    expect(restored.toJson()['voice_auto_start'], isFalse);
    expect(restored.googleCalendarToken, model.googleCalendarToken);
    expect(restored.naverCalendarToken, model.naverCalendarToken);
    expect(restored.createdAt, model.createdAt);
  });

  test('UserSettingsModel defaults unknown travel mode to car', () {
    final restored = UserSettingsModel.fromJson({
      'id': 'settings-2',
      'user_id': 'user-2',
      'travel_mode': 'bike',
    });

    expect(restored.travelMode, 'car');
    expect(restored.voiceAutoStart, isFalse);
    expect(restored.prepTimeMin, 30);
    expect(restored.prepPreAlarmOffset, 30);
    expect(restored.departPreAlarmOffset, 30);
    expect(restored.toJson()['travel_mode'], 'car');
  });

  test('UserSettingsModel defaults region settings to Korea', () {
    final settings = UserSettingsModel.defaults(userId: 'user-1');

    expect(settings.countryCode, 'KR');
    expect(settings.localeCode, 'ko-KR');
    expect(settings.timeZoneId, 'Asia/Seoul');
    expect(settings.toJson()['country_code'], 'KR');
  });
}
