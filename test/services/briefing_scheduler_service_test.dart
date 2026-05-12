import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/services/alarm_service.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('rescheduleNextBriefing schedules the next morning alarm', () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      eventRepository: _FakeEventRepository(),
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

    final status = await service.loadRuntimeStatus();
    expect(status.morningScheduled, isTrue);
    expect(status.nextMorningAt?.hour, 6);
    expect(status.nextMorningAt?.minute, 40);
  });

  test('rescheduleNextBriefing schedules the next evening alarm', () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      eventRepository: _FakeEventRepository(),
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

    final status = await service.loadRuntimeStatus();
    expect(status.eveningScheduled, isTrue);
    expect(status.nextEveningAt?.hour, 20);
    expect(status.nextEveningAt?.minute, 20);
  });

  test('scheduleDaily records both briefing alarm states', () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      eventRepository: _FakeEventRepository(),
    );

    final result = await service.scheduleDaily(
      morningTime: '06:10',
      eveningTime: '22:15',
      userId: 'user-1',
    );

    expect(result.allScheduled, isTrue);
    final status = await service.loadRuntimeStatus();
    expect(status.morningScheduled, isTrue);
    expect(status.eveningScheduled, isTrue);
    expect(status.nextMorningAt?.hour, 6);
    expect(status.nextMorningAt?.minute, 10);
    expect(status.nextEveningAt?.hour, 22);
    expect(status.nextEveningAt?.minute, 15);
  });

  test('scheduleDaily moves morning briefing before first prep alarm',
      () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 11, 22),
            location: '서울시청',
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1').copyWith(
          prepTimeMin: 30,
        ),
      ),
      now: () => DateTime(2026, 5, 12, 4),
    );

    final result = await service.scheduleDaily(
      morningTime: '07:30',
      eveningTime: '21:00',
      userId: 'user-1',
    );

    expect(result.morning.scheduledAt, DateTime(2026, 5, 12, 5));
    expect(alarm.morningScheduledAt, DateTime(2026, 5, 12, 5));
    final status = await service.loadRuntimeStatus();
    expect(status.nextMorningAt, DateTime(2026, 5, 12, 5));
  });

  test('scheduleDaily keeps morning briefing when adjusted prep time is past',
      () async {
    final alarm = _FakeAlarmService();
    final service = BriefingSchedulerService(
      alarmService: alarm,
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 11, 22),
            location: '서울시청',
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1'),
      ),
      now: () => DateTime(2026, 5, 12, 5, 10),
    );

    final result = await service.scheduleDaily(
      morningTime: '07:30',
      eveningTime: '21:00',
      userId: 'user-1',
    );

    expect(result.morning.scheduledAt, DateTime(2026, 5, 12, 7, 30));
    expect(alarm.morningScheduledAt, DateTime(2026, 5, 12, 7, 30));
  });
}

class _FakeAlarmService extends AlarmService {
  int morningCalls = 0;
  int eveningCalls = 0;
  DateTime? morningScheduledAt;
  DateTime? eveningScheduledAt;
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
    morningScheduledAt = scheduledAt;
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
    eveningScheduledAt = scheduledAt;
    lastScheduledAt = scheduledAt;
    lastUserId = userId;
    return true;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({this.events = const <EventModel>[]});

  final List<EventModel> events;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return events.cast<EventModel?>().firstWhere(
          (event) => event?.id == eventId,
          orElse: () => null,
        );
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
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
