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
        'travel_mode': 'transit',
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
    expect(settings.travelMode, 'transit');
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
        'travel_mode': 'transit',
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
        travelMode: 'transit',
      ),
    );

    expect(saved.id, 'settings-2');
    expect(saved.userId, 'user-1');
    expect(gateway.upsertPayloads.single['user_id'], 'user-1');
    expect(gateway.upsertPayloads.single.containsKey('id'), isFalse);
    expect(gateway.upsertPayloads.single['morning_briefing_at'], '07:10');
    expect(gateway.upsertPayloads.single['evening_briefing_at'], '21:20');
    expect(gateway.upsertPayloads.single['default_reminder_min'], 60);
    expect(gateway.upsertPayloads.single['travel_mode'], 'transit');
    expect(saved.travelMode, 'transit');
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
