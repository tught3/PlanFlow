import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/critical_alarm_channel_migration_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CriticalAlarmChannelMigrationService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('reschedules only future critical events once per channel', () async {
      final now = DateTime.utc(2026, 5, 24, 3);
      final repository = _FakeEventRepository(<EventModel>[
        _event('past-critical', now.subtract(const Duration(hours: 1)), true),
        _event('future-normal', now.add(const Duration(hours: 2)), false),
        _event('future-critical', now.add(const Duration(hours: 3)), true),
      ]);
      final sideEffects = _FakeManualEventSideEffectService();
      final service = CriticalAlarmChannelMigrationService(
        eventRepository: repository,
        sideEffectService: sideEffects,
        now: () => now,
      );

      expect(
        await service.migrateFutureCriticalAlarmsIfNeeded('user-1'),
        isTrue,
      );
      expect(repository.listCalls, 1);
      expect(sideEffects.resyncedEventIds, <String>['future-critical']);

      expect(
        await service.migrateFutureCriticalAlarmsIfNeeded('user-1'),
        isTrue,
      );
      expect(repository.listCalls, 1);
      expect(sideEffects.calls, 1);
    });

    test('uses current critical alarm channel id in migration key', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = CriticalAlarmChannelMigrationService(
        eventRepository: _FakeEventRepository(const <EventModel>[]),
        sideEffectService: _FakeManualEventSideEffectService(),
      );

      expect(
          await service.migrateFutureCriticalAlarmsIfNeeded('user-1'), isTrue);

      expect(
        prefs.getBool(
          'critical_alarm_channel_migration:user-1:'
          '${NotificationService.criticalAlarmChannelId}',
        ),
        isTrue,
      );
    });
  });
}

EventModel _event(String id, DateTime startAt, bool isCritical) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: id,
    startAt: startAt,
    isCritical: isCritical,
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.events);

  final List<EventModel> events;
  int listCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listCalls += 1;
    return events;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  final resyncedEventIds = <String>[];
  int calls = 0;

  @override
  Future<bool> resyncRemindersForEvents({
    required Iterable<EventModel> events,
    required String userId,
    Duration? reminderOffset =
        ManualEventSideEffectService.defaultReminderOffset,
    Duration? criticalAlarmOffset =
        ManualEventSideEffectService.criticalAlarmOffset,
  }) async {
    calls += 1;
    resyncedEventIds.addAll(events.map((event) => event.id));
    return true;
  }
}
