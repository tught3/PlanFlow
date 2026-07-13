import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/voice_conversation_controller.dart';

void main() {
  group('음성 수정 대상 매칭', () {
    test('STT로 이름 일부가 빠져도 단일 제목 토큰 일치 수정은 기존 일정을 연다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '김민수와 프로젝트 회의', DateTime(2026, 7, 14, 15)),
          _event('other', '디자인 프로젝트 회의', DateTime(2026, 7, 14, 16)),
        ],
        now: () => DateTime(2026, 7, 13, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle('민수와 프로젝트 회의 일정을 오후 4시로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'meeting');
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 16);
      expect(result.draftEvent?.id, 'meeting');
    });
  });

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

    test(
        'recurrence follow-up with an explicit weekday sets RRULE and anchors '
        'the start date to that weekday', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(2026, 5, 7, 12)),
          _event('third', '오후 방문', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('세 번째 일정을 매주 금요일마다 반복으로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'third');
      expect(result.requiresEditScreenNavigation, isTrue);
      expect(result.draftEvent, isNotNull);
      expect(result.draftEvent!.recurrenceRule, contains('FREQ=WEEKLY'));
      expect(result.draftEvent!.recurrenceRule, contains('BYDAY=FR'));
      // "금요일"이 함께 언급됐으므로 반복 요일에 맞춰 시작일도 가장 가까운
      // 금요일로 앵커링되는 것이 자연스럽다(2026-5-7은 목요일 -> 5-8 금요일).
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 5, 8, 15),
      );
    });

    test(
        'recurrence follow-up without a weekday only changes RRULE and keeps '
        'the original start time', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(2026, 5, 7, 12)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 매월 반복으로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'first');
      expect(result.draftEvent, isNotNull);
      expect(result.draftEvent!.recurrenceRule, 'FREQ=MONTHLY');
      // 요일/날짜 언급이 없으므로 시작 시각은 원래 값 그대로 유지돼야 한다.
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(2026, 5, 7, 9),
      );
    });

    test(
        'recurrence follow-up combined with an explicit weekday shift applies '
        'both changes', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(2026, 5, 7, 9)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result =
          controller.handle('1번 일정 다음주 금요일로 옮기고 매주 반복해줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.draftEvent, isNotNull);
      expect(result.draftEvent!.recurrenceRule, contains('FREQ=WEEKLY'));
      expect(
        planflowLocal(result.draftEvent!.startAt!).weekday,
        DateTime.friday,
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

    test(
        '제목만 겹치는 후속 명령은 추측으로 편집하지 않고 다시 물어본다 '
        '(순번/명시적 시간 지정 없이는 제목 부분일치로 대상을 추론하지 않음)',
        () {
      // 기존 일정 변경은 "몇 시 일정을 바꿔줘"처럼 명시적 시간을 짚거나,
      // 조회 후 "몇 번째 일정"처럼 순번으로 지정할 때만 이뤄져야 한다.
      // 텍스트에 우연히 등장하는 제목 단어로 대상을 추측하면, 관련 없는
      // 일정을 사용자 모르게 바꿔버릴 위험이 있다(실증: "모란역으로 가기
      // 일정생성해줘"가 옛 "가기" 일정을 편집해버린 버그).
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '내일 회의', DateTime(2026, 5, 8, 9)),
          _event('visit', '내일 방문', DateTime(2026, 5, 8, 10)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('내일 일정 알려줘');

      final result = controller.handle('내일 회의 중요한 일정으로 표시해줘');

      expect(result.action, VoiceConversationAction.none);
      expect(result.targetEvent, isNull);
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

    test('개인 일정 전환 발화는 확인 질문을 만들고 응답으로 확정된다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('morning', '오전 진료', DateTime(2026, 5, 7, 9)),
          _event('afternoon', '팀 회의', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final confirmAsk = controller.handle('오후 3시 일정 개인 일정으로 바꿔줘');
      expect(confirmAsk.action, VoiceConversationAction.confirmConvertToPersonal);
      expect(confirmAsk.targetEvent?.id, 'afternoon');
      expect(controller.pendingConvert?.id, 'afternoon');

      final confirmed = controller.handle('응');
      expect(confirmed.action, VoiceConversationAction.convertToPersonalConfirmed);
      expect(confirmed.targetEvent?.id, 'afternoon');
      expect(controller.pendingConvert, isNull);
    });

    test('개인 일정 전환 확인 질문을 거절하면 대기 상태만 지운다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('afternoon', '팀 회의', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');
      controller.handle('오후 3시 일정 개인 일정으로 바꿔줘');

      final rejected = controller.handle('아니 취소해');
      expect(rejected.action, VoiceConversationAction.none);
      expect(controller.pendingConvert, isNull);
    });

    test(
        '회귀: 장소 변경 발화는 개인 일정 전환으로 새지 않는다 '
        '("장소를 바꿔줘"의 "바꿔"가 전환 의도로 오탐되면 안 됨)', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('afternoon', '팀 회의', DateTime(2026, 5, 7, 15)),
        ],
        now: () => DateTime(2026, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('오후 3시 일정 장소를 본관으로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.locationText, '본관');
      expect(controller.pendingConvert, isNull);
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
