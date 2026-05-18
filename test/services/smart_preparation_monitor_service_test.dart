import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/smart_preparation_monitor_service.dart';

void main() {
  test('refreshUpcoming recalculates upcoming smart preparation alarms',
      () async {
    AppEnv.markSupabaseInitialized();
    final sideEffects = _FakeManualEventSideEffectService();
    final service = SmartPreparationMonitorService(
      sideEffectService: sideEffects,
    );

    await service.refreshUpcoming(userId: 'user-1');

    expect(sideEffects.recalculatedUserIds, ['user-1']);
  });
}

class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  final recalculatedUserIds = <String>[];

  @override
  Future<ManualEventAlarmRecalculationResult> recalculateUpcomingAlarmsForUser({
    required String userId,
    Iterable<EventModel> seedEvents = const <EventModel>[],
    DateTime? now,
    bool resyncDepartureAlarms = true,
  }) async {
    recalculatedUserIds.add(userId);
    return const ManualEventAlarmRecalculationResult();
  }
}
