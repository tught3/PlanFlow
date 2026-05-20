import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';

void main() {
  test('fetchSettings returns a decoded user settings row', () async {
    final gateway = _FakeSettingsGateway(
      fetchRow: <String, dynamic>{
        'id': 'settings-1',
        'user_id': 'user-1',
        'morning_briefing_at': '06:45:00',
        'evening_briefing_at': '20:15:00',
        'default_reminder_min': 45,
        'prep_time_min': 60,
        'prep_pre_alarm_offset': 10,
        'depart_pre_alarm_offset': 0,
        'departure_safety_margin_min': 20,
        'travel_mode': 'transit',
        'voice_auto_start': false,
        'preferred_map_provider': 'google',
        'google_calendar_token': 'google-token',
        'naver_calendar_token': 'naver-token',
        'created_at': '2026-05-02T00:00:00Z',
      },
    );

    final repository = SupabaseSettingsRepository(gateway: gateway);
    final settings = await repository.fetchSettings('user-1');

    expect(settings, isNotNull);
    expect(settings!.id, 'settings-1');
    expect(settings.userId, 'user-1');
    expect(settings.morningBriefingAt, '06:45');
    expect(settings.eveningBriefingAt, '20:15');
    expect(settings.defaultReminderMin, 45);
    expect(settings.prepTimeMin, 60);
    expect(settings.prepPreAlarmOffset, 10);
    expect(settings.departPreAlarmOffset, 0);
    expect(settings.departureSafetyMarginMin, 20);
    expect(settings.travelMode, 'transit');
    expect(settings.voiceAutoStart, isFalse);
    expect(settings.preferredMapProvider, 'google');
    expect(settings.googleCalendarToken, 'google-token');
    expect(settings.naverCalendarToken, 'naver-token');
    expect(settings.createdAt, DateTime.parse('2026-05-02T00:00:00Z'));
    expect(gateway.fetchUserIds.single, 'user-1');
  });

  test('upsertSettings sends user settings to Supabase and returns the row',
      () async {
    final gateway = _FakeSettingsGateway(
      upsertRow: <String, dynamic>{
        'id': 'settings-2',
        'user_id': 'user-1',
        'morning_briefing_at': '07:10:00',
        'evening_briefing_at': '21:20:00',
        'default_reminder_min': 60,
        'prep_time_min': 45,
        'prep_pre_alarm_offset': 10,
        'depart_pre_alarm_offset': 30,
        'departure_safety_margin_min': 20,
        'travel_mode': 'transit',
        'voice_auto_start': false,
        'preferred_map_provider': 'tmap',
        'created_at': '2026-05-02T01:00:00Z',
      },
    );

    final repository = SupabaseSettingsRepository(gateway: gateway);
    final saved = await repository.upsertSettings(
      const UserSettingsModel(
        id: '',
        userId: 'user-1',
        morningBriefingAt: '07:10',
        eveningBriefingAt: '21:20',
        defaultReminderMin: 60,
        prepTimeMin: 45,
        prepPreAlarmOffset: 10,
        departPreAlarmOffset: 30,
        departureSafetyMarginMin: 20,
        travelMode: 'transit',
        voiceAutoStart: false,
        preferredMapProvider: 'tmap',
      ),
    );

    expect(saved.id, 'settings-2');
    expect(saved.userId, 'user-1');
    expect(gateway.upsertPayloads.single['user_id'], 'user-1');
    expect(gateway.upsertPayloads.single.containsKey('id'), isFalse);
    expect(gateway.upsertPayloads.single['morning_briefing_at'], '07:10');
    expect(gateway.upsertPayloads.single['evening_briefing_at'], '21:20');
    expect(gateway.upsertPayloads.single['default_reminder_min'], 60);
    expect(gateway.upsertPayloads.single['prep_time_min'], 45);
    expect(gateway.upsertPayloads.single['prep_pre_alarm_offset'], 10);
    expect(gateway.upsertPayloads.single['depart_pre_alarm_offset'], 30);
    expect(gateway.upsertPayloads.single['departure_safety_margin_min'], 20);
    expect(gateway.upsertPayloads.single['travel_mode'], 'transit');
    expect(gateway.upsertPayloads.single['voice_auto_start'], isFalse);
    expect(gateway.upsertPayloads.single['preferred_map_provider'], 'tmap');
    expect(saved.travelMode, 'transit');
    expect(saved.voiceAutoStart, isFalse);
    expect(saved.preferredMapProvider, 'tmap');
    expect(saved.prepTimeMin, 45);
    expect(saved.prepPreAlarmOffset, 10);
    expect(saved.departPreAlarmOffset, 30);
    expect(saved.departureSafetyMarginMin, 20);
  });
}

class _FakeSettingsGateway implements SettingsGateway {
  _FakeSettingsGateway({
    this.fetchRow,
    this.upsertRow,
  });

  final Map<String, dynamic>? fetchRow;
  final Map<String, dynamic>? upsertRow;

  final List<String> fetchUserIds = <String>[];
  final List<Map<String, dynamic>> upsertPayloads = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>?> fetchSettings(String userId) async {
    fetchUserIds.add(userId);
    return fetchRow;
  }

  @override
  Future<Map<String, dynamic>> upsertSettings(
    Map<String, dynamic> payload,
  ) async {
    upsertPayloads.add(Map<String, dynamic>.from(payload));
    return upsertRow ??
        <String, dynamic>{
          ...payload,
          'id': 'settings-1',
          'created_at': '2026-05-02T00:00:00Z',
        };
  }
}
