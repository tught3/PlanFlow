import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/services/alarm_service.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';

void main() {
  test('rescheduleNextBriefing schedules the next morning alarm', () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1').copyWith(
          morningBriefingAt: '06:40',
          eveningBriefingAt: '20:20',
        ),
      ),
    );

    final scheduled = await service.rescheduleNextBriefing(
      isMorning: true,
      userId: 'user-1',
    );

    expect(scheduled, isTrue);
    expect(alarm.morningCalls, 1);
    expect(alarm.eveningCalls, 0);
    expect(alarm.lastUserId, 'user-1');
    expect(alarm.lastScheduledAt?.hour, 6);
    expect(alarm.lastScheduledAt?.minute, 40);
  });

  test('rescheduleNextBriefing schedules the next evening alarm', () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1').copyWith(
          morningBriefingAt: '06:40',
          eveningBriefingAt: '20:20',
        ),
      ),
    );

    final scheduled = await service.rescheduleNextBriefing(
      isMorning: false,
      userId: 'user-1',
    );

    expect(scheduled, isTrue);
    expect(alarm.morningCalls, 0);
    expect(alarm.eveningCalls, 1);
    expect(alarm.lastUserId, 'user-1');
    expect(alarm.lastScheduledAt?.hour, 20);
    expect(alarm.lastScheduledAt?.minute, 20);
  });
}

class _FakeAlarmService extends AlarmService {
  int morningCalls = 0;
  int eveningCalls = 0;
  DateTime? lastScheduledAt;
  String? lastUserId;

  @override
  Future<bool> scheduleMorningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? userId,
    String? briefingText,
  }) async {
    morningCalls += 1;
    lastScheduledAt = scheduledAt;
    lastUserId = userId;
    return true;
  }

  @override
  Future<bool> scheduleEveningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? userId,
    String? briefingText,
  }) async {
    eveningCalls += 1;
    lastScheduledAt = scheduledAt;
    lastUserId = userId;
    return true;
  }
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository({required this.settings});

  final UserSettingsModel settings;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async => settings;

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}
