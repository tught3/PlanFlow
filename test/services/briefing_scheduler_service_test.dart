import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/user_settings_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/data/repositories/settings_repository.dart';
import 'package:planflow/services/alarm_service.dart';
import 'package:planflow/services/briefing_scheduler_service.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/tts_service.dart';
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

  test(
      'executeBriefing uses secretary-style local fallback for critical events',
      () async {
    AppEnv.markSupabaseInitialized();
    final tts = _FakeTtsService();
    final service = BriefingSchedulerService(
      alarmService: _FakeAlarmService(),
      gptService: _FailingGptService(),
      ttsService: tts,
      notificationService: _FakeNotificationService(),
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장님 동행방문',
            startAt: DateTime.utc(2026, 5, 12, 0),
            location: '강남역',
            isCritical: true,
          ),
          EventModel(
            id: 'event-2',
            userId: 'user-1',
            title: '고객 미팅',
            startAt: DateTime.utc(2026, 5, 12, 5),
            location: '서울시청',
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1'),
      ),
      now: () => DateTime(2026, 5, 12, 7),
    );

    final result = await service.executeBriefing(
      isMorning: true,
      userId: 'user-1',
    );

    expect(result.usedFallback, isTrue);
    expect(tts.lastText, contains('좋은 아침입니다. 오늘 일정은 2개입니다.'));
    expect(
      tts.lastText,
      contains('중요한 일정입니다. 오전 9시, 강남역에서 팀장님 동행방문이 있습니다.'),
    );
    expect(
      tts.lastText,
      contains('다음 일정은 오후 2시, 서울시청에서 고객 미팅이 있습니다.'),
    );
    expect(tts.lastText, isNot(contains('중요.')));
  });

  test('manual briefing suppresses notification but still speaks', () async {
    AppEnv.markSupabaseInitialized();
    final notification = _FakeNotificationService();
    final tts = _FakeTtsService();
    final service = BriefingSchedulerService(
      alarmService: _FakeAlarmService(),
      ttsService: tts,
      notificationService: notification,
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '회의',
            startAt: DateTime.utc(2026, 5, 12, 9),
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1'),
      ),
      now: () => DateTime(2026, 5, 12, 7),
    );

    final result = await service.executeBriefing(
      isMorning: true,
      userId: 'user-1',
      isManualTrigger: true,
    );

    expect(result.delivered, isTrue);
    expect(notification.lastBody, isNull);
    expect(tts.lastText, isNotNull);
  });

  test('foreground briefing suppresses notification but still speaks',
      () async {
    AppEnv.markSupabaseInitialized();
    final notification = _FakeNotificationService();
    final tts = _FakeTtsService();
    final service = BriefingSchedulerService(
      alarmService: _FakeAlarmService(),
      ttsService: tts,
      notificationService: notification,
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '회의',
            startAt: DateTime.utc(2026, 5, 12, 9),
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1'),
      ),
      isAppInForeground: () => true,
      now: () => DateTime(2026, 5, 12, 7),
    );

    final result = await service.executeBriefing(
      isMorning: true,
      userId: 'user-1',
    );

    expect(result.delivered, isTrue);
    expect(notification.calls, 0);
    expect(tts.lastText, isNotNull);
  });

  test('foreground app suppresses briefing start notification', () async {
    final notification = _FakeNotificationService();
    final service = BriefingSchedulerService(
      alarmService: _FakeAlarmService(),
      notificationService: notification,
      eventRepository: _FakeEventRepository(),
      isAppInForeground: () => true,
    );

    await service.showBriefingStartNotification(isMorning: true);

    expect(notification.calls, 0);
  });

  test('pending foreground briefing modal emits and clears stored trigger',
      () async {
    SharedPreferences.setMockInitialValues({
      BriefingSchedulerService.appForegroundKey: true,
      BriefingSchedulerService.pendingModalKey: 'morning',
    });
    final preferences = await SharedPreferences.getInstance();
    final modal = BriefingSchedulerService.foregroundBriefingStream.first;

    await BriefingSchedulerService.checkPendingModalTrigger();

    expect(await modal, isTrue);
    expect(
      preferences.getString(BriefingSchedulerService.pendingModalKey),
      isNull,
    );
  });

  test('pending briefing modal remains stored while app is background',
      () async {
    SharedPreferences.setMockInitialValues({
      BriefingSchedulerService.appForegroundKey: false,
      BriefingSchedulerService.pendingModalKey: 'evening',
    });
    final preferences = await SharedPreferences.getInstance();
    var emitted = false;
    final subscription = BriefingSchedulerService.foregroundBriefingStream
        .listen((_) => emitted = true);

    await BriefingSchedulerService.checkPendingModalTrigger();
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isFalse);
    expect(
      preferences.getString(BriefingSchedulerService.pendingModalKey),
      'evening',
    );

    await subscription.cancel();
    await preferences.setBool(BriefingSchedulerService.appForegroundKey, true);
    final modal = BriefingSchedulerService.foregroundBriefingStream.first;

    await BriefingSchedulerService.checkPendingModalTrigger();

    expect(await modal, isFalse);
    expect(
      preferences.getString(BriefingSchedulerService.pendingModalKey),
      isNull,
    );
  });

  test('local briefing does not mention movement when events have no location',
      () async {
    AppEnv.markSupabaseInitialized();
    final tts = _FakeTtsService();
    final service = BriefingSchedulerService(
      alarmService: _FakeAlarmService(),
      gptService: _FailingGptService(),
      ttsService: tts,
      notificationService: _FakeNotificationService(),
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '방명록 미리 준비',
            startAt: DateTime.utc(2026, 5, 12, 0),
          ),
          EventModel(
            id: 'event-2',
            userId: 'user-1',
            title: '고객 전화',
            startAt: DateTime.utc(2026, 5, 12, 0, 10),
          ),
        ],
      ),
      settingsRepository: _FakeSettingsRepository(
        settings: UserSettingsModel.defaults(userId: 'user-1'),
      ),
      now: () => DateTime(2026, 5, 12, 7),
    );

    final result = await service.executeBriefing(
      isMorning: true,
      userId: 'user-1',
    );

    expect(result.usedFallback, isTrue);
    expect(
      tts.lastText,
      contains('일정 간격이 짧으니 앞 일정 마무리 시간을 확인해 주세요.'),
    );
    expect(tts.lastText, isNot(contains('이동을 서둘러')));
    expect(tts.lastText, isNot(contains('출발')));
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

class _FailingGptService extends GptService {
  @override
  Future<String> generateBriefing({
    required String rawText,
    required bool isMorning,
  }) {
    throw const GptCompletionException(
      'test_failure',
      'forced failure',
    );
  }
}

class _FakeTtsService extends TtsService {
  String? lastText;

  @override
  Future<void> speak(String text) async {
    lastText = text;
  }
}

class _FakeNotificationService extends NotificationService {
  int calls = 0;
  String? lastBody;

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    calls += 1;
    lastBody = body;
  }
}
