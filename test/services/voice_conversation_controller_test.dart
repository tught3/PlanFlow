import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/voice_conversation_controller.dart';

void main() {
  group('VoiceConversationController', () {
    test('absolute date query filters visible events for that day', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('may-7-9', '오전 회진', DateTime(2026, 5, 7, 9)),
          _event('may-7-15', '오후 회의', DateTime(2026, 5, 7, 15)),
          _event('may-8', '다음날 방문', DateTime(2026, 5, 8, 10)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );

      final result = controller.handle('5월 7일 일정 보여줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.queryRange?.start, DateTime(2026, 5, 7));
      expect(result.queryRange?.end, DateTime(2026, 5, 8));
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'may-7-9',
        'may-7-15',
      ]);
      expect(controller.visibleEvents.length, 2);
    });

    test('explicit weekday query wins over current or next week range', () {
      final monday = DateTime(2026, 5, 18, 9);
      final friday = DateTime(2026, 5, 22, 9);
      final nextFriday = DateTime(2026, 5, 29, 9);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('monday', '월요일 회의', monday),
          _event('friday', '금요일 방문', friday),
          _event('next-friday', '다음 금요일 방문', nextFriday),
        ],
        now: () => DateTime(2026, 5, 21, 8),
      );

      for (final text in <String>[
        '이번주금요일 일정 알려줘',
        '이번 주 금요일 일정 알려줘',
        '이번주 금요일 일정 알려줘',
      ]) {
        final result = controller.handle(text);

        expect(result.queryRange?.start, DateTime(2026, 5, 22));
        expect(result.queryRange?.end, DateTime(2026, 5, 23));
        expect(result.visibleEvents.map((event) => event.id), <String>[
          'friday',
        ]);
      }

      final nextResult = controller.handle('다음주 금요일 일정 알려줘');

      expect(nextResult.queryRange?.start, DateTime(2026, 5, 29));
      expect(nextResult.queryRange?.end, DateTime(2026, 5, 30));
      expect(nextResult.visibleEvents.map((event) => event.id), <String>[
        'next-friday',
      ]);
    });

    test('weekly query remains current week range', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('monday', '월요일 회의', DateTime(2026, 5, 18, 9)),
          _event('friday', '금요일 방문', DateTime(2026, 5, 22, 9)),
          _event('next-friday', '다음 금요일 방문', DateTime(2026, 5, 29, 9)),
        ],
        now: () => DateTime(2026, 5, 21, 8),
      );

      final result = controller.handle('주간 일정 알려줘');

      expect(result.queryRange?.start, DateTime(2026, 5, 18));
      expect(result.queryRange?.end, DateTime(2026, 5, 25));
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'monday',
        'friday',
      ]);
    });

    test('availability query returns empty-day state without side effects', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('may-7', '기존 일정', DateTime(2026, 5, 7, 9)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );

      final result = controller.handle('6월 15일 일정 비어있어?');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.isAvailabilityCheck, isTrue);
      expect(result.isEmptyAvailability, isTrue);
      expect(result.visibleEvents, isEmpty);
      expect(controller.visibleEvents, isEmpty);
      expect(controller.pendingDelete, isNull);
    });

    test(
        'ordinal follow-up resolves target and requests edit-screen navigation',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(2026, 5, 7, 12)),
          _event('third', '오후 방문', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('3번째 일정에 원주세브란스기독병원 장소 추가해줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'third');
      expect(result.locationText, '원주세브란스기독병원');
      expect(result.requiresEditScreenNavigation, isTrue);
      expect(result.requiresDeleteConfirmation, isFalse);
      expect(controller.focusedEvent?.id, 'third');
    });

    test('field-first location wording extracts only the new place', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('visit', '오후 방문', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('그 일정 장소를 원주세브란스기독병원으로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'visit');
      expect(result.locationText, '원주세브란스기독병원');
    });

    test('time follow-up delete resolves target and asks for confirmation', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('morning', '오전 진료', DateTime(2026, 5, 7, 9)),
          _event('afternoon', '오후 방문', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('오후 3시 일정 삭제해줘');

      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'afternoon');
      expect(result.requiresDeleteConfirmation, isTrue);
      expect(result.pendingDelete?.event.id, 'afternoon');
      expect(controller.pendingDelete?.event.id, 'afternoon');
    });

    test('duplicate time follow-up asks user to choose a numbered event', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first-3pm', '첫 오후 일정', DateTime(2026, 5, 7, 15)),
          _event('second-3pm', '둘째 오후 일정', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('오후 3시 일정 삭제해줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.requiresDeleteConfirmation, isFalse);
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'first-3pm',
        'second-3pm',
      ]);
      expect(controller.pendingDelete, isNull);
    });

    test('pending delete confirmation returns flag and clears pending action',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('morning', '오전 진료', DateTime(2026, 5, 7, 9)),
          _event('afternoon', '오후 방문', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller
        ..handle('오늘 일정 알려줘')
        ..handle('오후 3시 일정 삭제해줘');

      final result = controller.handle('응 삭제해');

      expect(result.action, VoiceConversationAction.deleteConfirmed);
      expect(result.deleteConfirmed, isTrue);
      expect(result.targetEvent?.id, 'afternoon');
      expect(controller.pendingDelete, isNull);
      expect(controller.focusedEvent?.id, 'afternoon');
    });
  });
}

EventModel _event(String id, String title, DateTime localStart) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: planflowLocalDateTimeToUtc(localStart),
    endAt: planflowLocalDateTimeToUtc(localStart.add(const Duration(hours: 1))),
  );
}
