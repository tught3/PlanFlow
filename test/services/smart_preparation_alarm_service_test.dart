import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';

void main() {
  test('buildCandidates creates medical, travel, and supply alarms', () {
    final service = SmartPreparationAlarmService();
    final candidates = service.buildCandidates(
      rawText: '모레 오전 8시 위내시경 검사. 신분증 챙기고 병원 방문',
      eventStartAt: DateTime(2026, 5, 8, 8),
      supplies: const <String>['신분증'],
    );

    expect(
      candidates.map((candidate) => candidate.title),
      containsAll(<String>[
        '병원 준비사항 확인',
        '금식/복약 안내 확인',
        '이동시간과 출발 시간 확인',
        '준비물 챙기기',
      ]),
    );
    expect(candidates.map((candidate) => candidate.title).toSet().length,
        candidates.length);
  });

  test('schedulePayloads schedules future smart preparation notifications',
      () async {
    final notifications = _FakeNotificationService();
    final service = SmartPreparationAlarmService(
      notificationService: notifications,
    );

    await service.schedulePayloads(
      eventId: 'event-1',
      eventTitle: '강남 미팅',
      payloads: <Map<String, dynamic>>[
        <String, dynamic>{
          'title': '이동시간과 출발 시간 확인',
          'notify_at':
              DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
        },
        <String, dynamic>{
          'title': '이미 지난 알림',
          'notify_at': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
        },
      ],
    );

    expect(notifications.scheduledIds, <int>[
      notifications.notificationIdFor('event-1:smart_preparation:0'),
    ]);
    expect(notifications.titles.single, SmartPreparationAlarmService.label);
    expect(
      notifications.bodies.single,
      contains('스마트 준비 알람: 이동시간과 출발 시간 확인'),
    );
  });
}

class _FakeNotificationService extends NotificationService {
  final scheduledIds = <int>[];
  final titles = <String>[];
  final bodies = <String>[];

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
  }) async {
    scheduledIds.add(id);
    titles.add(title);
    bodies.add(body);
  }
}
