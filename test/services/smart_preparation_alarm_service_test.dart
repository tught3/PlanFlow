import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
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

  test('buildCandidates does not infer medical alarms from locations alone',
      () {
    final service = SmartPreparationAlarmService();

    for (final rawText in const <String>[
      '내일 오전 10시 병원',
      '내일 오후 2시 병원 미팅',
      '토요일 병원 병문안',
      '내일 법원',
      '내일 학교',
      '내일 건강검진센터',
    ]) {
      final candidates = service.buildCandidates(
        rawText: rawText,
        eventStartAt: DateTime(2026, 5, 8, 10),
      );

      expect(
        candidates.map((candidate) => candidate.title),
        isNot(contains('병원 준비사항 확인')),
        reason: rawText,
      );
      expect(
        candidates.map((candidate) => candidate.title),
        isNot(contains('금식/복약 안내 확인')),
        reason: rawText,
      );
    }
  });

  test('buildCandidates creates visit prep for hospital patient visits', () {
    final service = SmartPreparationAlarmService();
    final candidates = service.buildCandidates(
      rawText: '토요일 병원 병문안',
      eventStartAt: DateTime(2026, 5, 9, 14),
    );
    final titles = candidates.map((candidate) => candidate.title);

    expect(titles, contains('꽃이나 선물 챙기기'));
    expect(titles, isNot(contains('병원 준비사항 확인')));
    expect(titles, isNot(contains('금식/복약 안내 확인')));
  });

  test('buildCandidates requires medical action with medical location', () {
    final service = SmartPreparationAlarmService();
    final candidates = service.buildCandidates(
      rawText: '월요일 오전 8시 건강검진',
      location: '서울병원',
      eventStartAt: DateTime(2026, 5, 11, 8),
    );

    expect(
      candidates.map((candidate) => candidate.title),
      containsAll(<String>[
        '병원 준비사항 확인',
        '금식/복약 안내 확인',
      ]),
    );
  });

  test('buildCandidates keeps explicit medical action over work context', () {
    final service = SmartPreparationAlarmService();
    final candidates = service.buildCandidates(
      rawText: '내일 병원 업무 후 진료 예약',
      eventStartAt: DateTime(2026, 5, 8, 10),
    );

    expect(
      candidates.map((candidate) => candidate.title),
      contains('병원 준비사항 확인'),
    );
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

  test('buildExternalEventPayloads creates departure-only external flow', () {
    final service = SmartPreparationAlarmService();
    final payloads = service.buildExternalEventPayloads(
      eventId: 'event-2',
      userId: 'user-1',
      title: '원주 미팅',
      location: '원주시청',
      eventStartAt: DateTime(2026, 5, 8, 12),
      travelMinutes: 90,
      prepTimeMin: 60,
      prepPreAlarmOffset: 30,
      departPreAlarmOffset: 30,
      departureSafetyMarginMin: 20,
      now: DateTime(2026, 5, 8, 7),
    );

    expect(payloads.map((row) => row['title']), <String>[
      '30분 뒤 출발해야 해요 🔔',
      '지금 출발하세요 🚗 (이동 약 90분)',
    ]);
    expect(payloads.map((row) => row['notify_at']), <String>[
      DateTime(2026, 5, 8, 9, 40).toIso8601String(),
      DateTime(2026, 5, 8, 10, 10).toIso8601String(),
    ]);
    expect(
      payloads.map((row) => row['source']).toSet(),
      {'external_preparation'},
    );
  });

  test('buildExternalEventPayloads expands both pre-alert setting', () {
    final service = SmartPreparationAlarmService();
    final payloads = service.buildExternalEventPayloads(
      eventId: 'event-both',
      userId: 'user-1',
      title: '대전 미팅',
      location: '대전역',
      eventStartAt: DateTime(2026, 5, 8, 12),
      travelMinutes: 60,
      prepTimeMin: 30,
      prepPreAlarmOffset: 31,
      departPreAlarmOffset: 31,
      departureSafetyMarginMin: 20,
      now: DateTime(2026, 5, 8, 7),
    );

    final titles = payloads.map((row) => row['title'].toString()).toList();
    expect(titles, isNot(contains('30분 뒤부터 준비 시작하세요 🔔')));
    expect(titles, isNot(contains('10분 뒤부터 준비 시작하세요 🔔')));
    expect(titles, contains('30분 뒤 출발해야 해요 🔔'));
    expect(titles, contains('10분 뒤 출발해야 해요 🔔'));
    expect(titles, contains('지금 출발하세요 🚗 (이동 약 60분)'));
  });

  test('isExternalEvent ignores home, online, and call schedules', () {
    final service = SmartPreparationAlarmService();

    expect(service.isExternalEvent(title: '대면 미팅', location: '원주시청'), true);
    expect(service.isExternalEvent(title: '재택 회의', location: '집'), false);
    expect(service.isExternalEvent(title: '줌 미팅', location: '온라인'), false);
    expect(service.isExternalEvent(title: '거래처 전화', location: '사무실 전화'), false);
  });

  test('isFirstExternalEventOfDay only returns true for first outside event',
      () {
    final service = SmartPreparationAlarmService();
    final first = EventModel(
      id: 'first',
      userId: 'user-1',
      title: '원주 미팅',
      startAt: DateTime(2026, 5, 8, 9),
      location: '원주시청',
    );
    final second = EventModel(
      id: 'second',
      userId: 'user-1',
      title: '대전 방문',
      startAt: DateTime(2026, 5, 8, 14),
      location: '대전역',
    );
    final home = EventModel(
      id: 'home',
      userId: 'user-1',
      title: '재택 회의',
      startAt: DateTime(2026, 5, 8, 8),
      location: '집',
    );

    expect(
      service.isFirstExternalEventOfDay(
        event: first,
        dayEvents: <EventModel>[home, second, first],
      ),
      true,
    );
    expect(
      service.isFirstExternalEventOfDay(
        event: second,
        dayEvents: <EventModel>[home, second, first],
      ),
      false,
    );
  });

  test('isFirstExternalEventOfDay ignores earlier schedules without places',
      () {
    final service = SmartPreparationAlarmService();
    final call = EventModel(
      id: 'call',
      userId: 'user-1',
      title: '본사 전화하기',
      startAt: DateTime(2026, 5, 8, 9),
    );
    final trip = EventModel(
      id: 'trip',
      userId: 'user-1',
      title: '대전 내려가기',
      startAt: DateTime(2026, 5, 8, 10),
      location: '대전역',
    );

    expect(
      service.isFirstExternalEventOfDay(
        event: trip,
        dayEvents: <EventModel>[call, trip],
      ),
      true,
    );
  });

  test('isFirstExternalEventOfDay compares events by PlanFlow local day', () {
    final service = SmartPreparationAlarmService();
    final lateNightKst = EventModel(
      id: 'late-night',
      userId: 'user-1',
      title: '야간 이동',
      startAt: DateTime.utc(2026, 5, 7, 15, 30),
      location: '서울역',
    );
    final morningKst = EventModel(
      id: 'morning',
      userId: 'user-1',
      title: '오전 이동',
      startAt: DateTime.utc(2026, 5, 8, 0),
      location: '대전역',
    );

    expect(
      service.isFirstExternalEventOfDay(
        event: lateNightKst,
        dayEvents: <EventModel>[morningKst, lateNightKst],
      ),
      true,
    );
    expect(
      service.isFirstExternalEventOfDay(
        event: morningKst,
        dayEvents: <EventModel>[morningKst, lateNightKst],
      ),
      false,
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
    String? payload,
  }) async {
    scheduledIds.add(id);
    titles.add(title);
    bodies.add(body);
  }
}
