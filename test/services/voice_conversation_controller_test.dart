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

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'third');
      expect(result.locationText, '원주세브란스기독병원');
      expect(result.requiresEditScreenNavigation, isFalse);
      expect(result.requiresDeleteConfirmation, isFalse);
      expect(controller.focusedEvent?.id, 'third');
    });

    test(
        'relative date follow-up creates a shifted draft event for edit screen',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(2026, 5, 7, 12)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 그 다음날로 변경해줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'first');
      expect(result.requiresEditScreenNavigation, isTrue);
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 5, 8, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(2026, 5, 8, 10),
      );
      expect(
        planflowLocal(result.targetEvent!.startAt!),
        DateTime(2026, 5, 7, 9),
      );
    });

    test(
        'day-only follow-up shifts the selected event to this month or next month',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '계룡 엄마 만나기', DateTime(2026, 6, 19, 9)),
          _event('second', '다른 일정', DateTime(2026, 6, 19, 12)),
        ],
        now: () => DateTime(2026, 6, 10, 8),
      );
      controller.handle('6월 19일 일정 보여줘');

      final result = controller.handle('1번 일정의 날짜를 28일로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'first');
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 6, 28, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(2026, 6, 28, 10),
      );
    });

    test('time follow-up creates a shifted draft event for edit screen', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(2026, 5, 7, 12)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 시작시간 8시반으로 해줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'first');
      expect(result.requiresEditScreenNavigation, isTrue);
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 5, 7, 8, 30),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(2026, 5, 7, 9, 30),
      );
      expect(
        planflowLocal(result.targetEvent!.startAt!),
        DateTime(2026, 5, 7, 9),
      );
    });

    test('focused event wording can move a queried event to another date', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('target', '원주집 단기렌트', DateTime(2026, 7, 19, 9)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );
      controller.handle('7월 19일 일정 보여줘');

      final result = controller.handle('이 일정 6월 19일로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'target');
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 6, 19, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(2026, 6, 19, 10),
      );
    });

    test('title or person search defaults to one month around today', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('near-title', '김태형 PM 확인전화', DateTime(2026, 7, 6, 9)),
          _event('far-title', '김태형 PM 분기 미팅', DateTime(2026, 8, 9, 9)),
          _eventWithPeople(
            'near-target',
            '납품 확인',
            DateTime(2026, 5, 10, 9),
            targets: const <String>['김태형'],
          ),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );

      final result = controller.handle('김태형 일정 찾아줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'near-target',
        'near-title',
      ]);
    });

    test('title search trims trailing quoted particles before searching', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('match', '김창민 만나기', DateTime(2026, 6, 19, 9)),
          _event('noise', '김창민 다른 미팅', DateTime(2026, 6, 20, 9)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );

      final result = controller.handle('김창민 만나기라는 일정 찾아봐');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>['match']);
      expect(result.visibleEvents.single.title, '김창민 만나기');
    });

    test('title search requires all name and role tokens to match', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('exact', '김태형 PM 확인전화', DateTime(2026, 7, 6, 9)),
          _event('name-only', '김태형 미팅', DateTime(2026, 7, 6, 11)),
          _event('role-only', 'PM 주간보고', DateTime(2026, 7, 6, 14)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );

      final result = controller.handle('김태형 PM 일정 찾아줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>['exact']);
    });

    test('month-end title search clamps the one-month window', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('feb-last', '김태형 월말 미팅', DateTime(2026, 2, 28, 9)),
          _event('feb-early', '김태형 초순 미팅', DateTime(2026, 2, 27, 9)),
        ],
        now: () => DateTime(2026, 3, 31, 8),
      );

      final result = controller.handle('김태형 일정 찾아줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'feb-last',
      ]);
    });

    test('focused wording does not pick the first result from multiple events',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '김태형 오전 미팅', DateTime(2026, 7, 6, 9)),
          _event('second', '김태형 오후 미팅', DateTime(2026, 7, 6, 15)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );
      controller.handle('김태형 일정 찾아줘');

      final result = controller.handle('이 일정 6월 19일로 바꿔줘');

      expect(result.action, VoiceConversationAction.none);
      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
      expect(result.assistantMessage, contains('몇 번째'));
    });

    test('title search asks whether to expand when one month has no match', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('far-title', '김태형 PM 분기 미팅', DateTime(2026, 8, 9, 9)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );

      final result = controller.handle('김태형 일정 찾아줘');

      expect(result.action, VoiceConversationAction.none);
      expect(result.visibleEvents, isEmpty);
      expect(result.assistantMessage, contains('기간을 넓혀'));
      expect(result.session.pendingTitleSearchText, '김태형 일정 찾아줘');
    });

    test('pending title search expands into the requested future range', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('far-title', '김창민 만나기', DateTime(2026, 8, 9, 9)),
          _event('future-far', '김창민 분기 미팅', DateTime(2026, 10, 9, 9)),
        ],
        now: () => DateTime(2026, 6, 7, 8),
      );

      final initial = controller.handle('김창민 만나기 일정 찾아줘');

      expect(initial.action, VoiceConversationAction.none);
      expect(initial.session.pendingTitleSearchText, '김창민 만나기 일정 찾아줘');

      final expanded = controller.handle('미래 3개월');

      expect(expanded.action, VoiceConversationAction.showEvents);
      expect(expanded.visibleEvents.map((event) => event.id), <String>[
        'far-title',
      ]);
      expect(expanded.session.pendingTitleSearchText, isNull);
    });

    test('numeric ordinal particle is removed from extracted location text',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '첫 일정', DateTime(2026, 5, 7, 9)),
          _event('second', '둘째 일정', DateTime(2026, 5, 7, 10)),
          _event('third', '셋째 일정', DateTime(2026, 5, 7, 11)),
          _event('fourth', '넷째 일정', DateTime(2026, 5, 7, 12)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('4번에 강릉 건도리횟집 장소추가');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'fourth');
      expect(result.locationText, '강릉 건도리횟집');
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

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'visit');
      expect(result.locationText, '원주세브란스기독병원');
    });

    test('ordinal follow-up can mark an event as 중요한 일정', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(2026, 5, 7, 9)),
          _event('second', '방문', DateTime(2026, 5, 7, 10)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('첫번째 일정 강한 알림으로 표시해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'first');
      expect(result.criticalValue, isTrue);
    });

    test('title follow-up can mark an event as 중요한 일정', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '내일 회의', DateTime(2026, 5, 8, 9)),
          _event('visit', '내일 방문', DateTime(2026, 5, 8, 10)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('내일 일정 알려줘');

      final result = controller.handle('내일 회의 중요한 일정으로 표시해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'meeting');
      expect(result.criticalValue, isTrue);
    });

    test('ordinal follow-up can unset 중요한 일정', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(2026, 5, 7, 9)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('첫번째 일정 중요한 알림 꺼줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'first');
      expect(result.criticalValue, isFalse);
    });

    test('explicit "중요한 일정 해제"는 off로 처리한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(2026, 5, 7, 9)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('첫번째 일정 중요한 일정 해제해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'first');
      expect(result.criticalValue, isFalse);
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

    test(
        '명확한 새 일정 생성 명령은 조회로 남아있던 기존 일정과 제목이 우연히 겹쳐도 '
        '그 일정을 편집하지 않고 새 일정 생성으로 처리한다', () {
      // 회귀: "모란역으로 가기 일정생성해줘"가 이전 조회 결과에 남아있던
      // 제목 "가기" 일정과 부분일치(공통 단어 "가기")해, 새 일정을 만드는
      // 대신 그 기존 일정을 오후 2시로 편집해버리는 버그가 있었다.
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('existing-1', '가기', DateTime(2026, 7, 3, 9, 30)),
        ],
        now: () => DateTime(2026, 7, 3, 10),
      );

      final showResult = controller.handle('오늘 일정 보여줘');
      expect(showResult.action, VoiceConversationAction.showEvents);
      expect(controller.focusedEvent?.id, 'existing-1');

      final result =
          controller.handle('오늘 오후2시에 모란역으로 가기 일정생성해줘');

      expect(result.action, VoiceConversationAction.createEvent);
      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNotNull);
    });
  });
}

EventModel _event(String id, String title, DateTime localStart) {
  return _eventWithPeople(id, title, localStart);
}

EventModel _eventWithPeople(
  String id,
  String title,
  DateTime localStart, {
  List<String> participants = const <String>[],
  List<String> targets = const <String>[],
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: planflowLocalDateTimeToUtc(localStart),
    endAt: planflowLocalDateTimeToUtc(localStart.add(const Duration(hours: 1))),
    participants: participants,
    targets: targets,
  );
}
