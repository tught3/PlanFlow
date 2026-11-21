import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/event_edit_route_payload.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/screens/voice/voice_action_screen.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';
import 'package:planflow/services/gpt_service.dart';
import 'package:planflow/services/voice_command_router.dart';
import 'package:planflow/services/voice_conversation_controller.dart';
import 'package:planflow/services/voice_text_cleanup_service.dart';

// UI 테스트(voice_*_screen_test)와 동일한 규칙: 1월 1일이 목요일이고 윤년이
// 아닌 미래 연도를 고른다. 과거 기준 연도와 같은 요일 배치(5/7 목, 5/22 금 등)를
// 보존하므로 기존 월/일/요일 기반 픽스처 참조가 모두 유효하게 유지된다.
int _alignedFutureFixtureYear() {
  for (var year = DateTime.now().year + 1;; year++) {
    if (DateTime(year, 1, 1).weekday == DateTime.thursday &&
        !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) {
      return year;
    }
  }
}

final int _fixtureYear = _alignedFutureFixtureYear();

/// [from] 이후(포함) 가장 가까운 [weekday](DateTime.monday..sunday)를 반환한다.
DateTime _nextWeekdayOnOrAfter(DateTime from, int weekday) {
  final int diff = (weekday - from.weekday) % 7;
  return from.add(Duration(days: diff));
}

DateTime _dateAt(DateTime date, int dayOffset, [int hour = 0, int minute = 0]) {
  return DateTime(date.year, date.month, date.day + dayOffset, hour, minute);
}

class _CountingVoiceCommandRouter extends VoiceCommandRouter {
  int routeCallCount = 0;

  @override
  VoiceCommandRouteResult route(
    String rawText, {
    VoiceCommandRouteIntent? intent,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    routeCallCount++;
    return super.route(
      rawText,
      intent: intent,
      context: context,
      candidates: candidates,
    );
  }
}

void main() {
  group('pending destructive voice actions', () {
    VoiceConversationController makeController({
      required bool convert,
      bool requestConfirmation = true,
    }) {
      final today = DateTime(_fixtureYear, 5, 7, 8);
      final controller = VoiceConversationController(
        now: () => today,
        events: [
          if (convert)
            _event('a', '팀 회의', DateTime(_fixtureYear, 5, 7, 9))
                .copyWith(source: 'group')
          else
            _event('a', '진료', DateTime(_fixtureYear, 5, 7, 9)),
          _event('b', '방문', DateTime(_fixtureYear, 5, 7, 15)),
          _event('yesterday', '공유 회의', DateTime(_fixtureYear, 5, 6, 11)),
          _event('tomorrow', '네이버 회의', DateTime(_fixtureYear, 5, 8, 11)),
        ],
      );
      expect(controller.handle('오늘 일정 보여줘').action,
          VoiceConversationAction.showEvents);
      if (!requestConfirmation) return controller;
      final pending =
          controller.handle(convert ? '첫번째 일정 개인 일정으로 바꿔줘' : '첫번째 일정 삭제해줘');
      expect(
          pending.action,
          convert
              ? VoiceConversationAction.confirmConvertToPersonal
              : VoiceConversationAction.confirmDelete);
      expect(pending.targetEvent?.id, 'a');
      return controller;
    }

    for (final reply in [
      '응',
      '네',
      '예',
      '그래',
      '맞아',
      '좋아',
      '확인',
      '오케이',
      '응, 그래!',
      '네 맞아요',
      '삭제해',
      '삭제해줘',
      '지워',
      '지워줘',
      '없애줘',
      '응 지워줘',
      '응 삭제해줘',
      '네 삭제해줘',
    ]) {
      test('"$reply" confirms only the pending delete target', () {
        final controller = makeController(convert: false);
        final result = controller.handle(reply);
        expect(result.action, VoiceConversationAction.deleteConfirmed);
        expect(result.targetEvent?.id, 'a');
        expect(controller.pendingDelete, isNull);
      });
    }

    for (final reply in [
      '삭제 취소해줘',
      '안 지워도 돼',
      '안지워도돼',
      '지우지 마',
      '삭제하지 말아줘',
      '아니',
      '아냐',
      '됐어',
      '그만',
      '말고',
      '보류',
      '놔둬',
      '냅둬',
      '괜찮아',
      '안삭제',
      '안해',
      '하지 마',
      '취소',
      '싫어',
      '아니요',
    ]) {
      test('"$reply" cancels the pending delete', () {
        final controller = makeController(convert: false);
        final result = controller.handle(reply);
        expect(result.action, VoiceConversationAction.deleteCanceled);
        expect(result.deleteConfirmed, isFalse);
        expect(controller.pendingDelete, isNull);
      });
    }

    for (final reply in [
      '어',
      '어…',
      '어 음',
      '응?',
      '네?',
      '그래?',
      '맞아?',
      '맞아요？',
      '네 맞아요?',
      '삭제해줘?',
    ]) {
      test('"$reply" asks again without confirming the pending delete', () {
        final controller = makeController(convert: false);
        final pending = controller.pendingDelete;

        final result = controller.handle(reply);

        expect(result.action, VoiceConversationAction.none);
        expect(result.deleteConfirmed, isFalse);
        expect(result.assistantMessage, contains('삭제할까요?'));
        expect(controller.pendingDelete, same(pending));
        expect(
          controller.handle('응').action,
          VoiceConversationAction.deleteConfirmed,
        );
      });
    }

    for (final reply in [
      '두 번째 일정 삭제해줘',
      '2번 일정 삭제해줘',
      '방문 일정 삭제해줘',
      '내일 일정 삭제해줘',
    ]) {
      test('"$reply" asks again for the new delete target', () {
        final controller = makeController(convert: false);
        final result = controller.handle(reply);
        final newTarget = reply.startsWith('내일') ? 'tomorrow' : 'b';
        expect(result.action, VoiceConversationAction.confirmDelete);
        expect(result.deleteConfirmed, isFalse);
        expect(result.requiresDeleteConfirmation, isTrue);
        expect(result.targetEvent?.id, newTarget);
        expect(controller.pendingDelete?.event.id, newTarget);
      });
    }

    test('a repeated request prefix requires a separate affirmative reply', () {
      final controller = makeController(convert: false);
      const request = '첫번째 일정 삭제해줘';
      final withoutSeparator = controller.handle('$request' '어');
      expect(withoutSeparator.deleteConfirmed, isFalse);
      expect(controller.pendingDelete?.event.id, 'a');

      controller.handle(request);
      final separated = controller.handle('$request, 응 삭제해줘');
      expect(separated.action, VoiceConversationAction.deleteConfirmed);
      expect(separated.targetEvent?.id, 'a');
    });

    test('a query replaces a pending delete', () {
      final controller = makeController(convert: false);
      final result = controller.handle('내일 일정 보여줘');
      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), ['tomorrow']);
      expect(controller.pendingDelete, isNull);
    });

    test('an explicit creation command replaces a pending delete', () {
      final controller = makeController(convert: false);
      final result = controller.handle('병원 예약');
      expect(result.action, VoiceConversationAction.createEvent);
      expect(result.deleteConfirmed, isFalse);
      expect(controller.pendingDelete, isNull);
    });

    test('an ambiguous reply preserves a pending delete', () {
      final controller = makeController(convert: false);
      final result = controller.handle('음 글쎄');
      expect(result.action, VoiceConversationAction.none);
      expect(result.deleteConfirmed, isFalse);
      expect(result.assistantMessage, contains('응'));
      expect(result.assistantMessage, contains('아니'));
      expect(controller.pendingDelete?.event.id, 'a');
    });

    for (final reply in [
      '응',
      '네',
      '좋아',
      '어',
      '옮겨줘',
      '바꿔줘',
      '개인 일정으로 해줘',
      '네?',
      '그래?',
      '맞아?',
    ]) {
      test('"$reply" confirms only the pending conversion target', () {
        final controller = makeController(convert: true);
        final result = controller.handle(reply);
        expect(
            result.action, VoiceConversationAction.convertToPersonalConfirmed);
        expect(result.targetEvent?.id, 'a');
        expect(controller.pendingConvert, isNull);
      });
    }

    for (final reply in ['싫어', '아니', '하지 마', '취소', '안옮겨']) {
      test('"$reply" cancels the pending conversion', () {
        final controller = makeController(convert: true);
        final result = controller.handle(reply);
        expect(result.action, VoiceConversationAction.none);
        expect(result.assistantMessage, '개인 일정으로 옮기지 않을게요.');
        expect(controller.pendingConvert, isNull);
      });
    }

    test('"네이버 일정 보여줘" replaces a pending conversion with a query', () {
      final controller = makeController(convert: true);
      final result = controller.handle('네이버 일정 보여줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), ['tomorrow']);
      expect(controller.pendingConvert, isNull);
    });

    test('yesterday query uses the ordinary path during pending conversion',
        () {
      const query = '어제 일정 보여줘';
      final controller = makeController(convert: true);
      final ordinary = makeController(
        convert: true,
        requestConfirmation: false,
      ).handle(query);

      final result = controller.handle(query);

      expect(VoiceCommandRouter().route(query).intent,
          VoiceCommandRouteIntent.query);
      expect(result.inputText, query);
      for (final response in [ordinary, result]) {
        expect(response.action, VoiceConversationAction.showEvents);
        expect(response.queryRange?.start, DateTime(_fixtureYear, 5, 6));
        expect(response.queryRange?.end, DateTime(_fixtureYear, 5, 7));
        expect(response.visibleEvents.map((event) => event.id), ['yesterday']);
      }
      expect(result.visibleEvents.map((event) => event.id),
          ordinary.visibleEvents.map((event) => event.id));
      expect(controller.pendingConvert, isNull);
    });

    test('a new conversion target is confirmed separately', () {
      final controller = makeController(convert: true);
      final result = controller.handle('두 번째 일정 개인 일정으로 옮겨줘');
      expect(result.action, VoiceConversationAction.confirmConvertToPersonal);
      expect(result.targetEvent?.id, 'b');
      expect(controller.pendingConvert?.id, 'b');
    });

    test('an ambiguous reply preserves a pending conversion', () {
      final controller = makeController(convert: true);
      final result = controller.handle('어쩌지 그냥 해줘');
      expect(result.action, VoiceConversationAction.none);
      expect(result.assistantMessage, contains('응'));
      expect(result.assistantMessage, contains('아니'));
      expect(controller.pendingConvert?.id, 'a');
    });
  });

  group('local schedule time edits', () {
    for (final (input, originalHour, expectedDay, hour, minute) in [
      ('밤 12시', 14, 8, 0, 0),
      ('낮 2시', 9, 7, 14, 0),
      ('3시', 14, 7, 15, 0),
      ('6시', 9, 7, 18, 0),
      ('7시', 9, 7, 7, 0),
      ('10시', 9, 7, 10, 0),
      ('11시', 9, 7, 11, 0),
      ('12시', 9, 7, 12, 0),
      ('10시', 15, 7, 22, 0),
      ('자정에', 14, 8, 0, 0),
      ('오늘 자정에', 14, 9, 0, 0),
      ('5월 20일 자정에', 14, 21, 0, 0),
      ('정오에', 14, 7, 12, 0),
      ('오늘 밤 12시', 14, 9, 0, 0),
      ('네 시 사십오 분', 14, 7, 16, 45),
      ('오후 다섯 시 오십 분', 14, 7, 17, 50),
    ]) {
      test('"$input" edits a selected schedule at $originalHour:00', () {
        final controller = VoiceConversationController(
          events: [
            _event('target', '회의', DateTime(_fixtureYear, 5, 7, originalHour)),
          ],
          now: () => DateTime(_fixtureYear, 5, 8, 8),
        );
        expect(
            controller.handle('어제 일정 보여줘').visibleEvents.single.id, 'target');

        final direction = input.endsWith('에') ? input : '$input로';
        final result = controller.handle('첫번째 일정 $direction 옮겨줘');

        expect(result.action, VoiceConversationAction.confirmedEdit);
        expect(result.targetEvent?.id, 'target');
        final start = result.draftEvent?.startAt;
        expect(start, isNotNull);
        expect(planflowLocal(start!),
            DateTime(_fixtureYear, 5, expectedDay, hour, minute));
      });
    }

    for (final (input, expectedDayOffset) in [
      ('밤 12시로', 8),
      ('자정에', 8),
      ('오늘 자정에', 1),
      ('명시 날짜 자정에', 5),
    ]) {
      test('P6c controller resolves $input for a future schedule', () {
        final today = _dateAt(planflowNow(), 0, 9);
        final event = _event('target', '회식', _dateAt(today, 7, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );

        final result = controller.handle(
          '첫번째 일정 ${_editTimeWording(input, today)} 옮겨줘',
        );

        expect(result.targetEvent?.id, event.id);
        expect(
          result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, expectedDayOffset)),
        );
      });
    }

    for (final (input, expectedDayOffset, hour, minute) in [
      ('밤 12시로', 8, 0, 0),
      ('낮 2시로', 7, 14, 0),
      ('3시로', 7, 15, 0),
      ('10시로', 7, 22, 0),
      ('자정에', 8, 0, 0),
      ('오늘 자정에', 1, 0, 0),
      ('명시 날짜 자정에', 5, 0, 0),
      ('정오에', 7, 12, 0),
      ('네 시 사십오 분으로', 7, 16, 45),
      ('오후 다섯 시 오십 분으로', 7, 17, 50),
    ]) {
      testWidgets('voice action uses $input in the edit draft', (tester) async {
        final today = planflowNow();
        final event = _event(
          'target',
          '팀 회식',
          _dateAt(today, 7, input == '10시로' ? 9 : 14),
        ).copyWith(externalId: 'linked');

        final localDays = <DateTime>{};
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: _editTimeWording(input, today),
          observeDate: localDays.add,
        );
        // VoiceActionScreen reads the wall clock. If this tap straddles
        // midnight, either observed date is valid for an explicit "today".
        final Iterable<DateTime> referenceDays =
            input.startsWith('오늘') ? localDays : [today];
        expect(
          payload?.draft.startAt,
          isIn([
            for (final day in referenceDays)
              planflowLocalDateTimeToUtc(
                _dateAt(day, expectedDayOffset, hour, minute),
              ),
          ]),
        );
      });
    }

    testWidgets('P6c tomorrow midnight agrees across all three entrypoints',
        (tester) async {
      final today = planflowNow();
      final event = _event('target', '회식', _dateAt(today, 7, 14))
          .copyWith(externalId: 'linked');
      final localDays = <DateTime>{};
      const input = '내일 자정에';

      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: input,
        observeDate: localDays.add,
      );

      final expectedUtc = <DateTime>[];
      for (final day in localDays) {
        final expected = _dateAt(day, 2);
        final reference = _dateAt(day, 0, 9);
        final asUtc = planflowLocalDateTimeToUtc(expected);
        expectedUtc.add(asUtc);
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(reference),
        );
        final result = controller.handle('첫번째 일정 $input 옮겨줘');
        expect(result.targetEvent?.id, event.id);
        expect(result.draftEvent?.startAt, asUtc);
        expect(GptService(now: () => reference).inferStartAtFromRawText(input),
            expected);
      }
      expect(payload?.draft.startAt, isIn(expectedUtc));
    });

    for (final noun in ['일정', '약속', '스케줄']) {
      test('P6d controller edits 회식 followed by $noun을', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회식', _dateAt(today, 0, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        expect(
            controller.handle('오늘 일정 보여줘').visibleEvents.single.id, event.id);

        final result = controller.handle('회식 $noun을 3시로 옮겨줘');

        expect(result.targetEvent?.id, event.id);
        expect(result.draftEvent?.startAt,
            planflowLocalDateTimeToUtc(_dateAt(today, 0, 15)));
      });
    }

    for (final input in ['금요일 자정으로', '내일 자정에', '금요일 3시로']) {
      testWidgets('P6d controller and VoiceAction date policy: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final original = _dateAt(today, 14, 14);
        final event =
            _event('target', '회식', original).copyWith(externalId: 'linked');
        final observedDays = <DateTime>{};
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: observedDays.add,
        );

        final expectedStarts = <DateTime>[];
        for (final day in observedDays) {
          final expected = switch (input) {
            '금요일 자정으로' => _dateAt(
                _nextWeekdayOnOrAfter(_dateAt(day, 1), DateTime.friday), 1),
            '내일 자정에' => _dateAt(day, 2),
            _ => _dateAt(
                _nextWeekdayOnOrAfter(_dateAt(original, 1), DateTime.friday),
                0,
                15,
              ),
          };
          final expectedUtc = planflowLocalDateTimeToUtc(expected);
          expectedStarts.add(expectedUtc);
          final controller = VoiceConversationController(
            events: [event],
            now: () => planflowLocalDateTimeToUtc(_dateAt(day, 0, 8)),
          );
          final result = controller.handle('첫번째 일정 $input 옮겨줘');

          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt, expectedUtc);
        }
        expect(payload?.draft.startAt, isIn(expectedStarts));
      });
    }

    testWidgets('P6d VoiceAction keeps a past date for a time-only edit',
        (tester) async {
      final past = _dateAt(planflowNow(), -7, 14);
      final event = _event('target', '회식', past).copyWith(externalId: 'linked');
      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: '3시로',
        observeDate: (_) {},
      );

      expect(payload?.draft.startAt,
          planflowLocalDateTimeToUtc(_dateAt(past, 0, 15)));
    });

    test('P6c a noon destination does not select the existing noon schedule',
        () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('noon', '점심', _dateAt(today, 0, 12)),
          _event('other', '정기미팅', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      expect(
        controller.handle('오늘 일정 보여줘').visibleEvents.map((event) => event.id),
        ['noon', 'other'],
      );

      final result = controller.handle('정오로 옮겨줘');

      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
    });

    for (final input in ['정오로 옮겨줘', '정오로 좀 옮겨줘', '정오로 잠시 옮겨줘']) {
      test('P6c destination cannot select an event titled 정오: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final controller = VoiceConversationController(
          events: [
            _event('named', '팀 회식', _dateAt(today, 0, 12)),
            _event('clock-title', '정오', _dateAt(today, 0, 15)),
          ],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        expect(
          controller.handle('오늘 일정 보여줘').visibleEvents.map((event) => event.id),
          ['named', 'clock-title'],
        );

        final result = controller.handle(input);

        expect(result.targetEvent, isNull);
        expect(result.draftEvent, isNull);
      });

      test('P6c retains the named event before the destination: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final controller = VoiceConversationController(
          events: [
            _event('named', '팀 회식', _dateAt(today, 0, 14)),
            _event('clock-title', '정오', _dateAt(today, 0, 15)),
          ],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');

        final result = controller.handle('팀 회식 $input');

        expect(result.targetEvent?.id, 'named');
        expect(
          result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)),
        );
      });
    }

    test('P6c round3 잠깐 noon destination cannot select or auto-apply', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('noon', '점심', _dateAt(today, 0, 12)),
          _event('clock-title', '정오', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('정오로 잠깐 옮겨줘');

      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    test('P6c round3 numeric destination preserves explicit named target', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('named', '팀 회식', _dateAt(today, 0, 14)),
          _event('decoy', '3시', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('팀 회식 3시로 잠시 옮겨줘');

      expect(result.targetEvent?.id, 'named');
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 0, 15)));
    });

    test('P6c round3 numeric destination alone cannot select clock title', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('named', '팀 회식', _dateAt(today, 0, 14)),
          _event('decoy', '3시', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('3시로 잠시 옮겨줘');

      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    test('P6c round3 relative two-day midnight uses target date', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final targetDate = _dateAt(today, 7, 14);
      final event = _event('target', '회식', targetDate);
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );

      final result = controller.handle('1번 일정 2일 뒤 자정으로 잠시 옮겨줘');

      expect(result.targetEvent?.id, 'target');
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(targetDate, 3)));
    });

    for (final input in ['오늘 밤 12시로 잠시', '20일 밤 12시로']) {
      testWidgets(
          'P6c round3 explicit night twelve across edit entrypoints: $input',
          (tester) async {
        final today = planflowNow();
        final event = _event('target', '회식', _dateAt(today, 40, 14))
            .copyWith(externalId: 'linked');
        final localDays = <DateTime>{};
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: localDays.add,
        );
        final expectedUtc = <DateTime>[];
        for (final day in localDays) {
          final reference = _dateAt(day, 0, 9);
          final stated = input.startsWith('오늘')
              ? _dateAt(day, 0)
              : DateTime(day.year, day.month + (day.day > 20 ? 1 : 0), 20);
          final expected = planflowLocalDateTimeToUtc(_dateAt(stated, 1));
          expectedUtc.add(expected);
          final controller = VoiceConversationController(
            events: [event],
            now: () => planflowLocalDateTimeToUtc(reference),
          );
          final result = controller.handle('첫번째 일정 $input 옮겨줘');
          expect(result.targetEvent?.id, 'target');
          expect(result.draftEvent?.startAt, expected);
        }
        expect(localDays, isNotEmpty);
        expect(payload?.draft.startAt, isIn(expectedUtc));
      });
    }

    for (final input in [
      '오후 2시 또는 오후 3시로',
      '오후 2시 아니면 오후 3시로',
      '2일 뒤 오후 2시로 옮겨줘, 아니면 오후 3시로',
      '2일 뒤 오후 3시로 바꾸고 오후 4시로',
    ]) {
      test('P6c round4 ambiguous destination controller: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final result = controller.handle('1번 일정 $input 옮겨줘');
        expect(result.draftEvent, isNull);
        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
      });

      testWidgets('P6c round4 ambiguous destination VoiceAction: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14))
            .copyWith(externalId: 'linked');
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: (_) {},
          expectDraft: false,
        );
        expect(payload, isNull);
      });
    }

    testWidgets('P6c round4 source time then destination is unambiguous',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 7, 14))
          .copyWith(externalId: 'linked');
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      final query = controller.handle('다음 주 일정 보여줘');
      expect(query.visibleEvents.map((item) => item.id), contains(event.id));
      final result = controller.handle('오후 2시 일정을 오후 3시로 옮겨줘');
      expect(result.targetEvent?.id, event.id);
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 7, 15)));

      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: '오후 2시 일정을 오후 3시로',
        observeDate: (_) {},
      );
      expect(payload?.draft.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 7, 15)));
    });

    testWidgets('P6c round4 two days later midnight agrees across entrypoints',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final targetDate = _dateAt(today, 7, 14);
      final event =
          _event('target', '회의', targetDate).copyWith(externalId: 'linked');
      final expected = planflowLocalDateTimeToUtc(_dateAt(targetDate, 3));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      final result = controller.handle('1번 일정 2일 뒤 자정으로 옮겨줘');
      expect(result.targetEvent?.id, event.id);
      expect(result.draftEvent?.startAt, expected);

      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: '2일 뒤 자정으로',
        observeDate: (_) {},
      );
      expect(payload?.draft.startAt, expected);
      expect(
        GptService(now: () => targetDate).inferStartAtFromRawText('2일 뒤 자정으로'),
        _dateAt(targetDate, 3),
      );
    });

    for (final input in [
      '오후 2시나 오후 3시로',
      '오후 2시 또는 24:00로',
    ]) {
      test('P6c round5 alternative destination controller: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final result = controller.handle('1번 일정 $input 옮겨줘');
        expect(result.draftEvent, isNull);
        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
      });

      testWidgets('P6c round5 alternative destination VoiceAction: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14))
            .copyWith(externalId: 'linked');
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: (_) {},
          expectDraft: false,
        );
        expect(payload, isNull);
      });
    }

    test('P6c round5 alternative time query remains a query', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 0, 14));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      final result = controller.handle('오늘 오후 2시 또는 오후 3시 일정 보여줘');
      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((item) => item.id), contains(event.id));
      expect(result.draftEvent, isNull);
    });

    for (final wording in ['일주일 뒤', '한 달 뒤']) {
      for (final modifier in ['', ' 잠시']) {
        test('P6c round5 relative date midnight controller: $wording$modifier',
            () {
          final today = _dateAt(planflowNow(), 0, 8);
          final targetDate = DateTime(today.year, today.month + 2, 10, 14);
          final event = _event('target', '회의', targetDate);
          final requestedDate = wording == '일주일 뒤'
              ? _dateAt(targetDate, 7)
              : DateTime(targetDate.year, targetDate.month + 1, targetDate.day);
          final expected =
              planflowLocalDateTimeToUtc(_dateAt(requestedDate, 1));
          final controller = VoiceConversationController(
            events: [event],
            now: () => planflowLocalDateTimeToUtc(today),
          );
          final result = controller.handle('1번 일정 $wording 자정으로$modifier 옮겨줘');
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt, expected);
        });

        testWidgets(
            'P6c round5 relative date midnight VoiceAction: $wording$modifier',
            (tester) async {
          final today = _dateAt(planflowNow(), 0, 8);
          final targetDate = DateTime(today.year, today.month + 2, 10, 14);
          final event =
              _event('target', '회의', targetDate).copyWith(externalId: 'linked');
          final requestedDate = wording == '일주일 뒤'
              ? _dateAt(targetDate, 7)
              : DateTime(targetDate.year, targetDate.month + 1, targetDate.day);
          final expected =
              planflowLocalDateTimeToUtc(_dateAt(requestedDate, 1));
          final payload = await _openVoiceActionDraft(
            tester,
            event: event,
            input: '$wording 자정으로$modifier',
            observeDate: (_) {},
          );
          expect(payload?.draft.startAt, expected);
        });
      }
    }

    for (final input in [
      '정오나 오후 3시로',
      '자정이나 오후 3시로',
      '오후 2시 또는 내일 오후 3시로',
      '오후 2시나 내일 오후 3시로',
      '2일 뒤 또는 3일 뒤 자정으로',
    ]) {
      test('P6c round6 ambiguous destination controller: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final result = controller.handle('1번 일정 $input 옮겨줘');
        expect(result.draftEvent, isNull);
        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
      });

      testWidgets('P6c round6 ambiguous destination VoiceAction: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14))
            .copyWith(externalId: 'linked');
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: (_) {},
          expectDraft: false,
        );
        expect(payload, isNull);
      });
    }

    for (final input in [
      '내일 또는 모레 자정으로',
      '오늘이나 내일 자정으로',
      '내일 또는 3일 뒤 자정으로',
    ]) {
      test('P6c round7 alternative calendar dates controller: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final result = controller.handle('1번 일정 $input 옮겨줘');
        expect(result.draftEvent, isNull);
        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
      });

      testWidgets('P6c round7 alternative calendar dates VoiceAction: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 7, 14))
            .copyWith(externalId: 'linked');
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: (_) {},
          expectDraft: false,
        );
        expect(payload, isNull);
      });
    }

    test('P6c round7 ordinary 한시나마 cannot trigger an edit', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 0, 13));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');
      final result = controller.handle('한시나마 도와줘');
      expect(result.targetEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    test('P6c round7 three days later midnight controller', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final targetDate = _dateAt(today, 7, 14);
      final event = _event('target', '회의', targetDate);
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      final result = controller.handle('1번 일정 사흘 뒤 자정으로 옮겨줘');
      expect(result.targetEvent?.id, event.id);
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(targetDate, 4)));
    });

    testWidgets('P6c round7 three days later midnight VoiceAction',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final targetDate = _dateAt(today, 7, 14);
      final event =
          _event('target', '회의', targetDate).copyWith(externalId: 'linked');
      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: '사흘 뒤 자정으로',
        observeDate: (_) {},
      );
      expect(payload?.draft.startAt,
          planflowLocalDateTimeToUtc(_dateAt(targetDate, 4)));
    });

    test('P6c round8 date alternatives with particle controller', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 7, 14));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      final result = controller.handle('1번 일정 내일 또는 모레에 자정으로 옮겨줘');
      expect(result.draftEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    testWidgets('P6c round8 date alternatives with particle VoiceAction',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 7, 14))
          .copyWith(externalId: 'linked');
      final payload = await _openVoiceActionDraft(
        tester,
        event: event,
        input: '내일 또는 모레에 자정으로',
        observeDate: (_) {},
        expectDraft: false,
      );
      expect(payload, isNull);
    });

    test('P6c round8 꼭 destination cannot select clock-titled event', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');
      final result = controller.handle('정오로 꼭 옮겨줘');
      expect(result.targetEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    test('P6c round8 꼭 destination preserves explicit target', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');
      final result = controller.handle('1번 일정 정오로 꼭 옮겨줘');
      expect(result.targetEvent?.id, event.id);
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
    });

    test('P6c round10 adverb destination cannot select clock-titled event', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');
      final result = controller.handle('정오로 한 번만 옮겨줘');
      expect(result.targetEvent, isNull);
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    testWidgets('P6c round10 VoiceInput adverb destination does not save',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '정오로 한 번만 옮겨줘',
      );
      expect(repository.listCount, greaterThan(0));
      expect(repository.savedEvents, isEmpty);
    });

    testWidgets('P6c round10 VoiceInput mismatched title does not save',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '오늘 팀 회의를 정오로 꼭 옮겨줘',
      );
      expect(repository.listCount, greaterThan(0));
      expect(repository.savedEvents, isEmpty);
    });

    for (final (candidateTitle, input) in [
      ('회의', '팀 회의를 정오로 꼭 옮겨줘'),
      ('에버랜드', '에버랜드 모임을 정오로 꼭 옮겨줘'),
    ]) {
      testWidgets('P6c round10b partial title does not save: $candidateTitle',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('decoy', candidateTitle, _dateAt(today, 0, 15));
        final repository = _VoiceTimeWriteSpy(event);
        await _submitVoiceInputToAction(
          tester,
          event: event,
          repository: repository,
          input: input,
        );
        expect(repository.listCount, greaterThan(0));
        expect(repository.savedEvents, isEmpty);
      });
    }

    testWidgets('P6c round10b date-only move with a target clock',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('named', '팀 회의', _dateAt(today, 0, 15));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '오늘 오후 3시 팀 회의를 내일로 옮겨줘',
      );
      expect(repository.savedEvents, hasLength(1));
      expect(repository.savedEvents.single.id, event.id);
      expect(repository.savedEvents.single.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 1, 15)));
    });

    test('P6c round10c clock-only target date edit controller', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final eventDay = today.weekday == DateTime.friday ? 1 : 0;
      final eventDate = _dateAt(today, eventDay, 14);
      final destination = _nextWeekdayOnOrAfter(eventDate, DateTime.friday);
      final event = _event('target', '회의', eventDate);
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle(eventDay == 0 ? '오늘 일정 보여줘' : '내일 일정 보여줘');
      final result = controller.handle('오후 2시 일정을 금요일로 옮겨줘');
      expect(result.targetEvent?.id, event.id);
      expect(
          result.draftEvent?.startAt, planflowLocalDateTimeToUtc(destination));
    });

    testWidgets('P6c round10c clock-only target date edit VoiceInput',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final eventDay = today.weekday == DateTime.friday ? 1 : 0;
      final eventDate = _dateAt(today, eventDay, 14);
      final destination = _nextWeekdayOnOrAfter(eventDate, DateTime.friday);
      final event = _event('target', '회의', eventDate);
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '오후 2시 일정을 금요일로 옮겨줘',
      );
      expect(repository.listCount, greaterThan(0));
      expect(repository.savedEvents, hasLength(1));
      expect(repository.savedEvents.single.id, event.id);
      expect(repository.savedEvents.single.startAt,
          planflowLocalDateTimeToUtc(destination));
    });

    for (final (eventHour, shouldSave) in [(15, false), (14, true)]) {
      for (final destination in ['하루 뒤로 옮겨줘', '내일로   옮겨줘']) {
        test('P6c round10k date split $destination: $shouldSave', () {
          final today = _dateAt(planflowNow(), 0, 8);
          final event = _event('named', '회의', _dateAt(today, 0, eventHour));
          final controller = VoiceConversationController(
            events: [event],
            now: () => planflowLocalDateTimeToUtc(today),
          )..handle('오늘 일정 보여줘');
          final result = controller.handle('오늘 오후 2시 회의를 $destination');
          if (shouldSave) {
            expect(result.action, VoiceConversationAction.confirmedEdit);
            expect(result.targetEvent?.id, event.id);
            expect(result.draftEvent?.startAt,
                planflowLocalDateTimeToUtc(_dateAt(today, 1, 14)));
          } else {
            expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
          }
        });
      }
    }

    test('P6c round10j end-of-day controller does not select same-day midnight',
        () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('named', '회의', _dateAt(today, 0, 0));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');
      final result = controller.handle('오늘 밤 12시 회의를 정오로 꼭 옮겨줘');
      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
    });

    testWidgets(
        'P6c round10j end-of-day VoiceInput does not save same-day midnight',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('named', '회의', _dateAt(today, 0, 0));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(tester,
          event: event,
          repository: repository,
          input: '오늘 밤 12시 회의를 정오로 꼭 옮겨줘');
      expect(repository.savedEvents, isEmpty);
    });

    for (final (spoken, title, shouldConfirm) in [
      ('팀 회의를', '병원', false),
      ('팀 회의 준비를', '팀 회의', false),
      ('팀 회의를', '팀 회의', true),
      ('일정을', '병원', true),
    ]) {
      test('P6c time lookup respects the stated title: $spoken / $title', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', title, _dateAt(today, 0, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');

        final result = controller.handle('오늘 오후 2시 $spoken 정오로 꼭 옮겨줘');

        if (shouldConfirm) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
          expect(result.targetEvent, isNull);
          expect(result.draftEvent, isNull);
        }
      });
    }

    for (final (input, hour) in [
      ('3시랑 4시로', 15),
      ('3시하고 4시로', 15),
      ('세시랑 네시로', 15),
      ('오후 2시 또는 바로 오후 3시로', 14),
    ]) {
      test('P6c coordinated destination is not a source clock: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '회의', _dateAt(today, 0, hour));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final result = controller.handle('1번 일정 $input 옮겨줘');

        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        expect(result.draftEvent, isNull);
      });
    }

    test('P6c a source display midnight cannot auto-edit same-day midnight',
        () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '회의', _dateAt(today, 0, 0));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('오늘 24:00 일정을 정오로 꼭 옮겨줘');

      expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
      expect(result.draftEvent, isNull);
    });

    for (final input in ['내일 25시로', '하루 뒤 2시 70분으로', '내일 24:00로']) {
      test('P6c invalid destination does not yield a partial draft: $input',
          () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '팀 회의', _dateAt(today, 0, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');

        final result = controller.handle('팀 회의를 $input 옮겨줘');

        expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        expect(result.draftEvent, isNull);
      });

      testWidgets('P6c invalid destination does not allow direct save: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '팀 회의', _dateAt(today, 0, 14));
        final repository = _VoiceTimeWriteSpy(event);
        await _submitVoiceInputToAction(
          tester,
          event: event,
          repository: repository,
          input: '팀 회의를 $input 옮겨줘',
        );

        final save = find.text('바로 저장');
        if (save.evaluate().isNotEmpty) {
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
        }
        expect(repository.savedEvents, isEmpty);
      });

      testWidgets(
          'P6c invalid destination does not open a partial edit: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '팀 회의', _dateAt(today, 0, 14))
            .copyWith(externalId: 'linked');
        final payload = await _openVoiceActionDraft(
          tester,
          event: event,
          input: input,
          observeDate: (_) {},
          expectDraft: false,
        );
        expect(payload, isNull);
      });
    }

    test('P6c a date-only destination retains the original clock', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('target', '팀 회의', _dateAt(today, 0, 14, 30));
      final controller = VoiceConversationController(
        events: [event],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('1번 일정 내일로 옮겨줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 1, 14, 30)));
    });

    test('P6c round19 add route does not edit the same-time hospital', () {
      const input = '오늘 오후 2시 팀 회의 시작시간 8시반으로 해줘';
      expect(const VoiceCommandRouter().route(input).intent,
          VoiceCommandRouteIntent.add);
      final today = _dateAt(planflowNow(), 0, 8);
      final hospital = _event('hospital', '병원', _dateAt(today, 0, 14));
      final controller = VoiceConversationController(
        events: [hospital],
        now: () => planflowLocalDateTimeToUtc(today),
      );
      expect(
          controller.handle('오늘 일정 보여줘').visibleEvents.single.id, hospital.id);

      final result = controller.handle(input);

      expect(result.action, VoiceConversationAction.createEvent);
      expect(result.targetEvent, isNull);
      expect(result.draftEvent?.id, isEmpty);
    });

    for (final (round, input) in [
      (19, '내일 25:00로'),
      (19, '내일 2500로'),
      (19, '내일 밤 2400로'),
      (20, '내일 9:70로'),
      (20, '내일 970로'),
    ]) {
      test('P6c round$round invalid labeled clock yields no draft: $input', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '팀 회의', _dateAt(today, 0, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');

        final result = controller.handle('1번 일정 $input 옮겨줘');

        expect(result.action, VoiceConversationAction.none);
        expect(result.draftEvent, isNull);
      });
    }

    for (final (round, input, normalized) in [
      (19, '내일 25:00로', '내일 2500로'),
      (19, '내일 밤 24:00로', '내일 밤 2400로'),
      (20, '내일 9:70로', '내일 970로'),
      (20, '내일 970로', '내일 970로'),
    ]) {
      testWidgets('P6c round$round VoiceInput cannot auto-save: $input',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', '팀 회의', _dateAt(today, 0, 14));
        final repository = _VoiceTimeWriteSpy(event);

        await _submitVoiceInputToAction(
          tester,
          event: event,
          repository: repository,
          input: '팀 회의를 $input 옮겨줘',
          expectedActionText: '팀 회의를 $normalized 옮겨줘',
        );

        expect(repository.listCount, greaterThan(0));
        expect(repository.savedEvents, isEmpty);
      });

      for (final directSave in [true, false]) {
        final action = directSave ? 'save directly' : 'open an edit draft';
        testWidgets('P6c round$round VoiceInput cannot $action: $input',
            (tester) async {
          final today = _dateAt(planflowNow(), 0, 8);
          final event = _event('target', '팀 회의', _dateAt(today, 0, 14))
              .copyWith(externalId: 'linked');
          final repository = _VoiceTimeWriteSpy(event);
          EventEditRoutePayload? draft;

          await _submitVoiceInputToAction(
            tester,
            event: event,
            repository: repository,
            input: '팀 회의를 $input 옮겨줘',
            expectedActionText: '팀 회의를 $normalized 옮겨줘',
            onOpenDraft: (payload) => draft = payload,
          );

          expect(repository.savedEvents, isEmpty);
          final button = directSave
              ? find.text('바로 저장')
              : find
                  .ancestor(
                    of: find.text(event.title),
                    matching: find.byType(InkWell),
                  )
                  .first;
          if (directSave && button.evaluate().isEmpty) return;
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(repository.savedEvents, isEmpty);
          expect(draft, isNull);
        });
      }
    }

    for (final (round, title) in [(19, '2400 회의'), (20, '970 회의')]) {
      testWidgets('P6c round$round VoiceInput can date-edit a numeric title',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('target', title, _dateAt(today, 0, 14, 30));
        final repository = _VoiceTimeWriteSpy(event);

        await _submitVoiceInputToAction(
          tester,
          event: event,
          repository: repository,
          input: '$title를 내일로 옮겨줘',
        );

        expect(repository.savedEvents, hasLength(1));
        expect(repository.savedEvents.single.id, event.id);
        expect(repository.savedEvents.single.title, event.title);
        expect(repository.savedEvents.single.startAt,
            planflowLocalDateTimeToUtc(_dateAt(today, 1, 14, 30)));
      });
    }

    for (final (spoken, shouldSave) in [
      ('회의 준비', false),
      ('팀 회의 준비', false),
      ('팀 회의', false),
      ('회의', true),
    ]) {
      test('P6c round10l title collision $spoken: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '회의', _dateAt(today, 0, 15));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');
        final result = controller.handle('$spoken를 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });
    }

    for (final (title, shouldSave) in [('회의', false), ('팀 회의', true)]) {
      test('P6c round10i full controller title: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', title, _dateAt(today, 0, 15));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');
        final result = controller.handle('팀 회의를 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });
    }

    for (final (eventHour, shouldSave) in [(10, false), (14, true)]) {
      test('P6c round10h last-mentioned source clock: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '단기렌트', _dateAt(today, 0, eventHour));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final titleQuery = controller.handle('단기렌트 일정 보여 줘');
        expect(titleQuery.visibleEvents.single.id, event.id);
        final emptyQuery = controller.handle('내일 일정 보여 줘');
        expect(emptyQuery.visibleEvents, isEmpty);
        final result = controller.handle('오후 2시 아까 그 일정을 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });
    }

    for (final (eventOffset, shouldSave) in [(1, false), (0, true)]) {
      test('P6c round10g controller source date: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '회의', _dateAt(today, eventOffset, 14));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle(eventOffset == 0 ? '오늘 일정 보여줘' : '내일 일정 보여줘');
        final result = controller.handle('오늘 오후 2시 회의를 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });
    }

    for (final (eventHour, shouldSave) in [(15, false), (14, true)]) {
      test('P6c round10f date-only controller source clock: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '회의', _dateAt(today, 0, eventHour));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');
        final result = controller.handle('오늘 오후 2시 회의를 내일로 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 1, 14)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });
    }

    for (final (eventHour, shouldSave) in [(15, false), (14, true)]) {
      test('P6c round10e single-word controller source clock: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '회의', _dateAt(today, 0, eventHour));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');
        final result = controller.handle('오늘 오후 2시 회의를 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });

      testWidgets('P6c round10e refreshed source clock: $shouldSave',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final listed = _event('named', '팀 회의', _dateAt(today, 0, 14));
        final fresh = _event('named', '팀 회의', _dateAt(today, 0, eventHour));
        final repository = _VoiceTimeChangingWriteSpy(listed, fresh);
        await _submitVoiceInputToAction(
          tester,
          event: listed,
          repository: repository,
          input: '오늘 오후 2시 팀 회의를 정오로 꼭 옮겨줘',
        );
        expect(repository.fetchCount, greaterThan(0));
        expect(repository.savedEvents, hasLength(shouldSave ? 1 : 0));
        if (shouldSave) {
          expect(repository.savedEvents.single.id, listed.id);
          expect(repository.savedEvents.single.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        }
      });

      test('P6c round10d controller source clock match: $shouldSave', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '팀 회의', _dateAt(today, 0, eventHour));
        final controller = VoiceConversationController(
          events: [event],
          now: () => planflowLocalDateTimeToUtc(today),
        )..handle('오늘 일정 보여줘');
        final result = controller.handle('오늘 오후 2시 팀 회의를 정오로 꼭 옮겨줘');
        if (shouldSave) {
          expect(result.action, VoiceConversationAction.confirmedEdit);
          expect(result.targetEvent?.id, event.id);
          expect(result.draftEvent?.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        } else {
          expect(result.action, isNot(VoiceConversationAction.confirmedEdit));
        }
      });

      testWidgets('P6c round10d source clock match: $shouldSave',
          (tester) async {
        final today = _dateAt(planflowNow(), 0, 8);
        final event = _event('named', '팀 회의', _dateAt(today, 0, eventHour));
        final repository = _VoiceTimeWriteSpy(event);
        await _submitVoiceInputToAction(
          tester,
          event: event,
          repository: repository,
          input: '오늘 오후 2시 팀 회의를 정오로 꼭 옮겨줘',
        );
        expect(repository.listCount, greaterThan(0));
        expect(repository.savedEvents, hasLength(shouldSave ? 1 : 0));
        if (shouldSave) {
          expect(repository.savedEvents.single.id, event.id);
          expect(repository.savedEvents.single.startAt,
              planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
        }
      });
    }

    testWidgets('P6c round9 VoiceInput ambiguous target does not save',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('clock-title', '정오', _dateAt(today, 0, 15));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '정오로 꼭 옮겨줘',
      );
      expect(repository.listCount, greaterThan(0),
          reason: 'The candidate-loading path must have inspected the event.');
      expect(repository.savedEvents, isEmpty);
    });

    testWidgets('P6c round9 VoiceInput explicit target may save',
        (tester) async {
      final today = _dateAt(planflowNow(), 0, 8);
      final event = _event('named', '팀 회의', _dateAt(today, 0, 15));
      final repository = _VoiceTimeWriteSpy(event);
      await _submitVoiceInputToAction(
        tester,
        event: event,
        repository: repository,
        input: '팀 회의를 정오로 꼭 옮겨줘',
      );
      expect(repository.savedEvents, hasLength(1));
      expect(repository.savedEvents.single.id, event.id);
      expect(repository.savedEvents.single.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
    });

    test('P6c full edit target wins over a shorter title', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('named', '팀 회식', _dateAt(today, 0, 14)),
          _event('decoy', '회식', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('팀 회식 정오로 옮겨줘');

      expect(result.targetEvent?.id, 'named');
      expect(result.draftEvent?.startAt,
          planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
    });

    test('P6c duplicate full edit targets do not select a decoy', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [
          _event('named-1', '팀 회식', _dateAt(today, 0, 14)),
          _event('named-2', '팀 회식', _dateAt(today, 0, 16)),
          _event('decoy', '회식', _dateAt(today, 0, 15)),
        ],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('팀 회식 정오로 옮겨줘');

      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
    });

    for (final priorMultiSelection in [false, true]) {
      test(
          'P6c duplicate title selection uses displayed order with prior '
          'multi-selection=$priorMultiSelection', () {
        final today = _dateAt(planflowNow(), 0, 8);
        final events = [
          _event('named-1', '팀 회식', _dateAt(today, 0, 14)),
          _event('decoy', '회식', _dateAt(today, 0, 15)),
          _event('named-2', '팀 회식', _dateAt(today, 0, 16)),
        ];
        final controller = VoiceConversationController(
          events: events,
          now: () => planflowLocalDateTimeToUtc(today),
        );
        final query = controller.handle('오늘 일정 보여줘');
        final initialSession = priorMultiSelection
            ? query.session.copyWith(
                selectedEvents: [events[0], events[1]],
                focusedEvent: events[1],
              )
            : query.session;

        final prompt = controller.handle(
          '팀 회식 정오로 옮겨줘',
          session: initialSession,
        );
        expect(prompt.targetEvent, isNull);
        expect(prompt.visibleEvents.map((event) => event.id),
            ['named-1', 'named-2']);
        expect(prompt.session.visibleEvents.map((event) => event.id),
            prompt.visibleEvents.map((event) => event.id));
        expect(prompt.session.selectedEvents, isEmpty);
        expect(prompt.session.focusedEvent, isNull);

        final result = controller.handle(
          '두 번째 일정 정오로 옮겨줘',
          session: prompt.session,
        );
        expect(result.targetEvent?.id, 'named-2');
        expect(result.draftEvent?.startAt,
            planflowLocalDateTimeToUtc(_dateAt(today, 0, 12)));
      });
    }

    test('P6c partial edit target does not match a longer title', () {
      final today = _dateAt(planflowNow(), 0, 8);
      final controller = VoiceConversationController(
        events: [_event('named', '팀 회식', _dateAt(today, 0, 14))],
        now: () => planflowLocalDateTimeToUtc(today),
      )..handle('오늘 일정 보여줘');

      final result = controller.handle('회식 정오로 옮겨줘');

      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNull);
    });

    for (final dateCue in [
      '오늘',
      '내일',
      '월과 일',
      '일',
      '다음 주 금요일',
    ]) {
      for (final separator in [' ', '']) {
        testWidgets(
          'P6c midnight uses explicit date "$dateCue" with separator "$separator"',
          (tester) async {
            final today = _dateAt(planflowNow(), 0);
            final statedDate = _dateAt(today, 4);
            final wording = switch (dateCue) {
              '월과 일' => '${statedDate.month}월$separator${statedDate.day}일',
              '일' => '${statedDate.day}일',
              _ => dateCue,
            };
            final input = '$wording$separator자정에';
            final event = _event('target', '회식', _dateAt(today, 40, 14))
                .copyWith(externalId: 'linked');
            final localDays = <DateTime>{};

            final payload = await _openVoiceActionDraft(
              tester,
              event: event,
              input: input,
              observeDate: localDays.add,
            );

            final expectedUtc = <DateTime>[];
            for (final day in localDays) {
              final reference = _dateAt(day, 0, 9);
              final expected = switch (dateCue) {
                '오늘' => _dateAt(day, 1),
                '내일' => _dateAt(day, 2),
                '다음 주 금요일' => _dateAt(day, 13 - day.weekday),
                _ => _dateAt(statedDate, 1),
              };
              final utc = planflowLocalDateTimeToUtc(expected);
              expectedUtc.add(utc);
              final controller = VoiceConversationController(
                events: [event],
                now: () => planflowLocalDateTimeToUtc(reference),
              );

              final result = controller.handle('첫번째 일정 $input 옮겨줘');

              expect(result.targetEvent?.id, event.id);
              expect(result.draftEvent?.startAt, utc);
              expect(
                GptService(now: () => reference).inferStartAtFromRawText(input),
                expected,
              );
            }
            expect(payload?.draft.startAt, isIn(expectedUtc));
          },
        );
      }
    }

    for (final wording in ['강한 알림', '강한알림']) {
      test('"$wording 켜줘" applies the strong alarm', () {
        final controller = VoiceConversationController(
          events: [_event('target', '회의', DateTime(_fixtureYear, 5, 7, 14))],
          now: () => DateTime(_fixtureYear, 5, 7, 8),
        )..handle('오늘 일정 보여줘');

        final result = controller.handle('첫번째 일정 $wording 켜줘');

        expect(result.action, VoiceConversationAction.confirmedEdit);
        expect(result.targetEvent?.id, 'target');
        expect(result.criticalValue, isTrue);
      });
    }
  });

  group('음성 수정 대상 매칭', () {
    test('ordinal time edit matches an event titled 일정', () {
      final today = DateTime(_fixtureYear, 5, 7, 8);
      final event = _event('generic-title', '일정', _dateAt(today, 1, 14));
      final controller = VoiceConversationController(
        events: [event],
        now: () => today,
      );

      final query = controller.handle('내일 일정 보여줘');
      expect(query.action, VoiceConversationAction.showEvents);
      expect(query.visibleEvents.map((item) => item.id), ['generic-title']);

      final result = controller.handle('첫 번째 일정을 오후 5시로 변경해 줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, event.id);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 17);
      expect(planflowLocal(result.draftEvent!.endAt!).hour, 18);
    });

    test('STT로 이름 일부가 빠져도 단일 제목 토큰 일치 수정은 기존 일정을 연다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '김민수와 프로젝트 회의', DateTime(_fixtureYear, 7, 14, 15)),
          _event('other', '디자인 프로젝트 회의', DateTime(_fixtureYear, 7, 14, 16)),
        ],
        now: () => DateTime(_fixtureYear, 7, 13, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle('민수와 프로젝트 회의 일정을 오후 4시로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'meeting');
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 16);
      expect(result.draftEvent?.id, 'meeting');
    });

    test('일정 시간 필드명을 포함한 수정도 조회된 제목과 매칭한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '김민수와 프로젝트 회의', DateTime(_fixtureYear, 7, 14, 15)),
        ],
        now: () => DateTime(_fixtureYear, 7, 13, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle(
        '김민수와 프로젝트 회의 일정 시간을 오후 4시로 변경해 줘',
      );

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'meeting');
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 16);
    });

    test('장소와 시간 변경은 하나의 편집 초안에 함께 반영한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '김민수와 프로젝트 회의', DateTime(_fixtureYear, 7, 14, 15))
              .copyWith(
            location: '강남역',
            locationLat: 37.4979,
            locationLng: 127.0276,
          ),
        ],
        now: () => DateTime(_fixtureYear, 7, 13, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle(
        '1번 일정 장소를 서울오크우드 호텔로 변경하고 시간을 오후 5시로 변경해줘',
      );

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.targetEvent?.id, 'meeting');
      expect(result.locationText, '서울오크우드 호텔');
      expect(result.draftEvent?.location, '서울오크우드 호텔');
      expect(result.draftEvent?.locationLat, isNull);
      expect(result.draftEvent?.locationLng, isNull);
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 17);
      expect(planflowLocal(result.draftEvent!.endAt!).hour, 18);
      expect(result.requiresEditScreenNavigation, isTrue);
    });

    test('중요도와 시간 변경도 하나의 편집 초안에 함께 반영한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '김민수와 프로젝트 회의', DateTime(_fixtureYear, 7, 14, 15)),
        ],
        now: () => DateTime(_fixtureYear, 7, 13, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle(
        '1번 일정 중요한 일정으로 바꾸고 시간을 오후 5시로 변경해줘',
      );

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.draftEvent?.isCritical, isTrue);
      expect(planflowLocal(result.draftEvent!.startAt!).hour, 17);
      expect(result.requiresEditScreenNavigation, isTrue);
    });
  });

  group('VoiceConversationController', () {
    test('yearless guide query uses the bound saved date across New Year', () {
      final currentYear = _fixtureYear;
      final savedDate = DateTime(currentYear + 1, 1, 1);
      final saved = _event(
        'guide-saved',
        '연습 일정',
        DateTime(currentYear + 1, 1, 1, 15),
      );
      final sameDayThisYear = _event(
        'this-year',
        '올해 일정',
        DateTime(currentYear, 1, 1, 15),
      );
      final otherDay = _event(
        'other-date',
        '다른 날짜 일정',
        DateTime(currentYear + 1, 1, 2, 15),
      );
      final nextYear = _event(
        'next-year',
        '다음 해 일정',
        DateTime(currentYear + 2, 1, 1, 15),
      );
      var guide = GuideSnapshot(
        uid: saved.userId,
        version: 'real_ui_v1',
        sessionId: 'tutorial',
        revision: 1,
        serverRevision: 1,
        run: GuideRun.active,
        step: GuideStep.querySpeech,
        createdEventId: saved.id,
        savedLocalDate: savedDate,
      );
      var now = DateTime(currentYear, 12, 31, 12);
      final controller = VoiceConversationController(
        events: [saved, sameDayThisYear, otherDay, nextYear],
        now: () => now,
        guideSnapshot: () => guide,
      );

      final result = controller.handle('1월 1일 일정 보여 줘.');
      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.queryRange?.start, savedDate);
      expect(result.visibleEvents.map((event) => event.id), [saved.id]);

      final explicit = controller.handle('$currentYear년 1월 1일 일정 보여줘');
      expect(explicit.queryRange?.start, DateTime(currentYear, 1, 1));
      expect(explicit.visibleEvents.map((event) => event.id),
          [sameDayThisYear.id]);

      now = DateTime(currentYear + 1, 1, 2, 12);
      final active = controller.handle('1월 1일 일정 보여줘');
      expect(active.queryRange?.start, savedDate);
      expect(active.visibleEvents.map((event) => event.id), [saved.id]);

      final other = controller.handle('1월 2일 일정 보여줘');
      expect(other.queryRange?.start, DateTime(currentYear + 1, 1, 2));
      expect(other.visibleEvents.map((event) => event.id), [otherDay.id]);

      guide = guide.copyWith(run: GuideRun.paused);
      final paused = controller.handle('1월 1일 일정 보여줘');
      expect(paused.queryRange?.start, DateTime(currentYear + 2, 1, 1));
      expect(paused.visibleEvents.map((event) => event.id), [nextYear.id]);
    });

    test(
      '반복일정 회차가 조회 범위 안에 있으면 단발 일정과 함께 조회 결과에 포함된다',
      () {
        // "내일"이 항상 화요일이 되도록(recurrence_rule BYDAY=TU와 정합) 미래의
        // 가장 가까운 화요일을 앵커로 삼는다 — 절대 날짜 리터럴 시한폭탄 방지.
        final DateTime tomorrow = _nextWeekdayOnOrAfter(
          DateTime.now().add(const Duration(days: 400)),
          DateTime.tuesday,
        );
        final DateTime today = tomorrow.subtract(const Duration(days: 1));
        final DateTime recurringAnchorWeek = tomorrow.subtract(
          const Duration(days: 7),
        );
        final controller = VoiceConversationController(
          events: <EventModel>[
            _event(
              'single-1',
              '단발 회의 A',
              DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 10),
            ),
            _event(
              'single-2',
              '단발 회의 B',
              DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 14),
            ),
            _event(
              'recurring',
              '주간 회의',
              DateTime(
                recurringAnchorWeek.year,
                recurringAnchorWeek.month,
                recurringAnchorWeek.day,
                9,
              ),
            ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU'),
          ],
          now: () => DateTime(today.year, today.month, today.day, 9),
        );

        final result = controller.handle('내일 일정 보여줘');

        expect(result.action, VoiceConversationAction.showEvents);
        expect(
          result.visibleEvents.map((event) => event.id).toSet(),
          <String>{'single-1', 'single-2', 'recurring'},
        );
        expect(result.visibleEvents.length, 3);

        // 리뷰어 HIGH 지적 회귀 방지: 조회 결과의 반복일정 항목은
        // anchor(recurringAnchorWeek, 조회한 "내일"보다 1주 전)가 아니라
        // 실제로 매치된 occurrence("내일") 날짜의 startAt을 가져야 한다.
        final EventModel visibleRecurring = result.visibleEvents.singleWhere(
          (event) => event.id == 'recurring',
        );
        final DateTime visibleRecurringStartLocal =
            planflowLocal(visibleRecurring.startAt!);
        expect(
          DateTime(
            visibleRecurringStartLocal.year,
            visibleRecurringStartLocal.month,
            visibleRecurringStartLocal.day,
          ),
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day),
        );
        expect(
          DateTime(
            visibleRecurringStartLocal.year,
            visibleRecurringStartLocal.month,
            visibleRecurringStartLocal.day,
          ),
          isNot(
            DateTime(
              recurringAnchorWeek.year,
              recurringAnchorWeek.month,
              recurringAnchorWeek.day,
            ),
          ),
        );
      },
    );

    test(
      '반복일정 회차를 조회한 뒤 날짜 단서 없이 시간만 바꾸면 조회한 회차 날짜를 유지한다(anchor 날짜로 새지 않는다)',
      () {
        // "내일"이 항상 화요일이 되도록(recurrence_rule BYDAY=TU와 정합) 미래의
        // 가장 가까운 화요일을 앵커로 삼는다 — 절대 날짜 리터럴 시한폭탄 방지.
        final DateTime tomorrow = _nextWeekdayOnOrAfter(
          DateTime.now().add(const Duration(days: 400)),
          DateTime.tuesday,
        );
        final DateTime today = tomorrow.subtract(const Duration(days: 1));
        // anchor를 조회 범위(내일)보다 훨씬 전(5주 전)으로 둬서, 만약
        // draft가 anchor 날짜를 기준으로 만들어지면 눈에 띄게 다른 날짜가
        // 나오도록 한다.
        final DateTime recurringAnchorWeek = tomorrow.subtract(
          const Duration(days: 35),
        );
        final controller = VoiceConversationController(
          events: <EventModel>[
            _event(
              'recurring',
              '주간 회의',
              DateTime(
                recurringAnchorWeek.year,
                recurringAnchorWeek.month,
                recurringAnchorWeek.day,
                9,
              ),
            ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU'),
          ],
          now: () => DateTime(today.year, today.month, today.day, 9),
        );

        final result = controller.handle('내일 일정 보여줘');
        expect(result.action, VoiceConversationAction.showEvents);
        expect(result.visibleEvents.length, 1);
        expect(result.visibleEvents.single.id, 'recurring');

        final editResult = controller.handle('1번 일정 시간을 오후 5시로 변경해줘');

        expect(editResult.action, VoiceConversationAction.openEditScreen);
        expect(editResult.targetEvent?.id, 'recurring');
        final DateTime draftStartLocal =
            planflowLocal(editResult.draftEvent!.startAt!);
        expect(
          DateTime(
            draftStartLocal.year,
            draftStartLocal.month,
            draftStartLocal.day,
          ),
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day),
          reason: '날짜 단서 없는 시간 변경은 조회한 회차("내일") 날짜를 유지해야 한다 — '
              'anchor의 원래 날짜로 새면 안 된다.',
        );
        expect(draftStartLocal.hour, 17);
      },
    );

    test('absolute date query filters visible events for that day', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('may-7-9', '오전 회진', DateTime(_fixtureYear, 5, 7, 9)),
          _event('may-7-15', '오후 회의', DateTime(_fixtureYear, 5, 7, 15)),
          _event('may-8', '다음날 방문', DateTime(_fixtureYear, 5, 8, 10)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );

      final result = controller.handle('5월 7일 일정 보여줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.queryRange?.start, DateTime(_fixtureYear, 5, 7));
      expect(result.queryRange?.end, DateTime(_fixtureYear, 5, 8));
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'may-7-9',
        'may-7-15',
      ]);
      expect(controller.visibleEvents.length, 2);
    });

    test('explicit weekday query wins over current or next week range', () {
      final monday = DateTime(_fixtureYear, 5, 18, 9);
      final friday = DateTime(_fixtureYear, 5, 22, 9);
      final nextFriday = DateTime(_fixtureYear, 5, 29, 9);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('monday', '월요일 회의', monday),
          _event('friday', '금요일 방문', friday),
          _event('next-friday', '다음 금요일 방문', nextFriday),
        ],
        now: () => DateTime(_fixtureYear, 5, 21, 8),
      );

      for (final text in <String>[
        '이번주금요일 일정 알려줘',
        '이번 주 금요일 일정 알려줘',
        '이번주 금요일 일정 알려줘',
      ]) {
        final result = controller.handle(text);

        expect(result.queryRange?.start, DateTime(_fixtureYear, 5, 22));
        expect(result.queryRange?.end, DateTime(_fixtureYear, 5, 23));
        expect(result.visibleEvents.map((event) => event.id), <String>[
          'friday',
        ]);
      }

      final nextResult = controller.handle('다음주 금요일 일정 알려줘');

      expect(nextResult.queryRange?.start, DateTime(_fixtureYear, 5, 29));
      expect(nextResult.queryRange?.end, DateTime(_fixtureYear, 5, 30));
      expect(nextResult.visibleEvents.map((event) => event.id), <String>[
        'next-friday',
      ]);
    });

    test('weekly query remains current week range', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('monday', '월요일 회의', DateTime(_fixtureYear, 5, 18, 9)),
          _event('friday', '금요일 방문', DateTime(_fixtureYear, 5, 22, 9)),
          _event('next-friday', '다음 금요일 방문', DateTime(_fixtureYear, 5, 29, 9)),
        ],
        now: () => DateTime(_fixtureYear, 5, 21, 8),
      );

      final result = controller.handle('주간 일정 알려줘');

      expect(result.queryRange?.start, DateTime(_fixtureYear, 5, 18));
      expect(result.queryRange?.end, DateTime(_fixtureYear, 5, 25));
      expect(result.visibleEvents.map((event) => event.id), <String>[
        'monday',
        'friday',
      ]);
    });

    test('availability query returns empty-day state without side effects', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('may-7', '기존 일정', DateTime(_fixtureYear, 5, 7, 9)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(_fixtureYear, 5, 7, 12)),
          _event('third', '오후 방문', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(_fixtureYear, 5, 7, 12)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 그 다음날로 변경해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'first');
      expect(result.requiresEditScreenNavigation, isFalse);
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(_fixtureYear, 5, 8, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(_fixtureYear, 5, 8, 10),
      );
      expect(
        planflowLocal(result.targetEvent!.startAt!),
        DateTime(_fixtureYear, 5, 7, 9),
      );
    });

    test(
        'day-only follow-up shifts the selected event to this month or next month',
        () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '계룡 엄마 만나기', DateTime(_fixtureYear, 6, 19, 9)),
          _event('second', '다른 일정', DateTime(_fixtureYear, 6, 19, 12)),
        ],
        now: () => DateTime(_fixtureYear, 6, 10, 8),
      );
      controller.handle('6월 19일 일정 보여줘');

      final result = controller.handle('1번 일정의 날짜를 28일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'first');
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(_fixtureYear, 6, 28, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(_fixtureYear, 6, 28, 10),
      );
    });

    test(
        'recurrence follow-up with an explicit weekday sets RRULE and anchors '
        'the start date to that weekday', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(_fixtureYear, 5, 7, 12)),
          _event('third', '오후 방문', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
      // 금요일로 앵커링되는 것이 자연스럽다(_fixtureYear-5-7은 목요일 -> 5-8 금요일).
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(_fixtureYear, 5, 8, 15),
      );
    });

    test(
        'recurrence follow-up without a weekday only changes RRULE and keeps '
        'the original start time', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(_fixtureYear, 5, 7, 12)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
        DateTime(_fixtureYear, 5, 7, 9),
      );
    });

    test(
        'recurrence follow-up combined with an explicit weekday shift applies '
        'both changes', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 다음주 금요일로 옮기고 매주 반복해줘');

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
          _event('first', '아침 미팅', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '점심 확인', DateTime(_fixtureYear, 5, 7, 12)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('1번 일정 시작시간 8시반으로 해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'first');
      expect(result.requiresEditScreenNavigation, isFalse);
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(_fixtureYear, 5, 7, 8, 30),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(_fixtureYear, 5, 7, 9, 30),
      );
      expect(
        planflowLocal(result.targetEvent!.startAt!),
        DateTime(_fixtureYear, 5, 7, 9),
      );
    });

    test('focused event wording can move a queried event to another date', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('target', '원주집 단기렌트', DateTime(_fixtureYear, 7, 19, 9)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
      );
      controller.handle('7월 19일 일정 보여줘');

      final result = controller.handle('이 일정 6월 19일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(result.targetEvent?.id, 'target');
      expect(result.draftEvent, isNotNull);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(_fixtureYear, 6, 19, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(_fixtureYear, 6, 19, 10),
      );
    });

    test('title or person search defaults to one month around today', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('near-title', '김태형 PM 확인전화', DateTime(_fixtureYear, 7, 6, 9)),
          _event('far-title', '김태형 PM 분기 미팅', DateTime(_fixtureYear, 8, 9, 9)),
          _eventWithPeople(
            'near-target',
            '납품 확인',
            DateTime(_fixtureYear, 5, 10, 9),
            targets: const <String>['김태형'],
          ),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
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
          _event('match', '김창민 만나기', DateTime(_fixtureYear, 6, 19, 9)),
          _event('noise', '김창민 다른 미팅', DateTime(_fixtureYear, 6, 20, 9)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
      );

      final result = controller.handle('김창민 만나기라는 일정 찾아봐');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>['match']);
      expect(result.visibleEvents.single.title, '김창민 만나기');
    });

    test('title search reuses the already parsed route', () {
      final router = _CountingVoiceCommandRouter();
      final controller = VoiceConversationController(
        router: router,
        events: <EventModel>[
          _event('match', '김창민 만나기', DateTime(_fixtureYear, 6, 19, 9)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
      );

      final result = controller.handle('김창민 만나기 일정 찾아봐');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.single.id, 'match');
      expect(router.routeCallCount, 1);
    });

    test('title search requires all name and role tokens to match', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('exact', '김태형 PM 확인전화', DateTime(_fixtureYear, 7, 6, 9)),
          _event('name-only', '김태형 미팅', DateTime(_fixtureYear, 7, 6, 11)),
          _event('role-only', 'PM 주간보고', DateTime(_fixtureYear, 7, 6, 14)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
      );

      final result = controller.handle('김태형 PM 일정 찾아줘');

      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.map((event) => event.id), <String>['exact']);
    });

    test('month-end title search clamps the one-month window', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('feb-last', '김태형 월말 미팅', DateTime(_fixtureYear, 2, 28, 9)),
          _event('feb-early', '김태형 초순 미팅', DateTime(_fixtureYear, 2, 27, 9)),
        ],
        now: () => DateTime(_fixtureYear, 3, 31, 8),
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
          _event('first', '김태형 오전 미팅', DateTime(_fixtureYear, 7, 6, 9)),
          _event('second', '김태형 오후 미팅', DateTime(_fixtureYear, 7, 6, 15)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
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
          _event('far-title', '김태형 PM 분기 미팅', DateTime(_fixtureYear, 8, 9, 9)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
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
          _event('far-title', '김창민 만나기', DateTime(_fixtureYear, 8, 9, 9)),
          _event('future-far', '김창민 분기 미팅', DateTime(_fixtureYear, 10, 9, 9)),
        ],
        now: () => DateTime(_fixtureYear, 6, 7, 8),
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
          _event('first', '첫 일정', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '둘째 일정', DateTime(_fixtureYear, 5, 7, 10)),
          _event('third', '셋째 일정', DateTime(_fixtureYear, 5, 7, 11)),
          _event('fourth', '넷째 일정', DateTime(_fixtureYear, 5, 7, 12)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('visit', '오후 방문', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('first', '회의', DateTime(_fixtureYear, 5, 7, 9)),
          _event('second', '방문', DateTime(_fixtureYear, 5, 7, 10)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('첫번째 일정 강한 알림으로 표시해줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.targetEvent?.id, 'first');
      expect(result.criticalValue, isTrue);
    });

    test(
        '제목만 겹치는 후속 명령은 추측으로 편집하지 않고 다시 물어본다 '
        '(순번/명시적 시간 지정 없이는 제목 부분일치로 대상을 추론하지 않음)', () {
      // 기존 일정 변경은 "몇 시 일정을 바꿔줘"처럼 명시적 시간을 짚거나,
      // 조회 후 "몇 번째 일정"처럼 순번으로 지정할 때만 이뤄져야 한다.
      // 텍스트에 우연히 등장하는 제목 단어로 대상을 추측하면, 관련 없는
      // 일정을 사용자 모르게 바꿔버릴 위험이 있다(실증: "모란역으로 가기
      // 일정생성해줘"가 옛 "가기" 일정을 편집해버린 버그).
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('meeting', '내일 회의', DateTime(_fixtureYear, 5, 8, 9)),
          _event('visit', '내일 방문', DateTime(_fixtureYear, 5, 8, 10)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('내일 일정 알려줘');

      final result = controller.handle('내일 회의 중요한 일정으로 표시해줘');

      expect(result.action, VoiceConversationAction.none);
      expect(result.targetEvent, isNull);
    });

    test('ordinal follow-up can unset 중요한 일정', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(_fixtureYear, 5, 7, 9)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('first', '회의', DateTime(_fixtureYear, 5, 7, 9)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('morning', '오전 진료', DateTime(_fixtureYear, 5, 7, 9)),
          _event('afternoon', '오후 방문', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final result = controller.handle('오후 3시 일정 삭제해줘');

      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'afternoon');
      expect(result.requiresDeleteConfirmation, isTrue);
      expect(result.pendingDelete?.event.id, 'afternoon');
      expect(controller.pendingDelete?.event.id, 'afternoon');
    });

    for (final (input, hour, otherHour) in [
      ('밤 12시', 0, 12),
      ('밤 1시', 1, 13),
      ('24:00', 0, 12),
      ('낮 2시', 14, 2),
      ('새벽 2시', 2, 14),
      ('저녁 7시', 19, 7),
      ('오후 12시', 12, 0),
      ('3시', 15, 16),
    ]) {
      test('time follow-up selects the $input schedule', () {
        final controller = VoiceConversationController(
          events: [
            _event('target', '회의', DateTime(_fixtureYear, 5, 7, hour)),
            _event('other', '진료', DateTime(_fixtureYear, 5, 7, otherHour)),
          ],
          now: () => DateTime(_fixtureYear, 5, 7, 8),
        );
        expect(controller.handle('오늘 일정 알려줘').visibleEvents, hasLength(2));

        final result = controller.handle('$input 일정 삭제해줘');

        expect(result.action, VoiceConversationAction.confirmDelete);
        expect(result.targetEvent?.id, 'target');
      });
    }

    test('duplicate time follow-up asks user to choose a numbered event', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first-3pm', '첫 오후 일정', DateTime(_fixtureYear, 5, 7, 15)),
          _event('second-3pm', '둘째 오후 일정', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('morning', '오전 진료', DateTime(_fixtureYear, 5, 7, 9)),
          _event('afternoon', '오후 방문', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
        'recurring delete with a date phrase sets pendingDelete.occurrenceDate',
        () {
      // 절대 날짜 리터럴 금지 — "내일"이 항상 회차 요일(BYDAY)과 일치하도록
      // 미래의 가장 가까운 화요일을 앵커로 삼는다.
      final DateTime tomorrow = _nextWeekdayOnOrAfter(
        DateTime.now().add(const Duration(days: 400)),
        DateTime.tuesday,
      );
      final DateTime today = tomorrow.subtract(const Duration(days: 1));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'recurring',
            '주간 회의',
            DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
          ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU'),
        ],
        now: () => DateTime(today.year, today.month, today.day, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle('내일 주간 회의 삭제해줘');

      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'recurring');
      expect(result.requiresDeleteConfirmation, isTrue);
      final occurrenceDate = result.pendingDelete?.occurrenceDate;
      expect(occurrenceDate, isNotNull);
      expect(occurrenceDate!.year, tomorrow.year);
      expect(occurrenceDate.month, tomorrow.month);
      expect(occurrenceDate.day, tomorrow.day);
      expect(controller.pendingDelete?.occurrenceDate, isNotNull);
    });

    test('recurring delete without a date leaves occurrenceDate null', () {
      final DateTime tomorrow = _nextWeekdayOnOrAfter(
        DateTime.now().add(const Duration(days: 400)),
        DateTime.tuesday,
      );
      final DateTime today = tomorrow.subtract(const Duration(days: 1));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'recurring',
            '팀 스크럼',
            DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
          ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU'),
        ],
        now: () => DateTime(today.year, today.month, today.day, 9),
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle('팀 스크럼 삭제해줘');

      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'recurring');
      expect(result.requiresDeleteConfirmation, isTrue);
      expect(result.pendingDelete?.occurrenceDate, isNull);
    });

    test('개인 일정 전환 발화는 확인 질문을 만들고 응답으로 확정된다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('morning', '오전 진료', DateTime(_fixtureYear, 5, 7, 9)),
          _event('afternoon', '팀 회의', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
      );
      controller.handle('오늘 일정 알려줘');

      final confirmAsk = controller.handle('오후 3시 일정 개인 일정으로 바꿔줘');
      expect(
          confirmAsk.action, VoiceConversationAction.confirmConvertToPersonal);
      expect(confirmAsk.targetEvent?.id, 'afternoon');
      expect(controller.pendingConvert?.id, 'afternoon');

      final confirmed = controller.handle('응');
      expect(
          confirmed.action, VoiceConversationAction.convertToPersonalConfirmed);
      expect(confirmed.targetEvent?.id, 'afternoon');
      expect(controller.pendingConvert, isNull);
    });

    test('개인 일정 전환 확인 질문을 거절하면 대기 상태만 지운다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('afternoon', '팀 회의', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('afternoon', '팀 회의', DateTime(_fixtureYear, 5, 7, 15)),
        ],
        now: () => DateTime(_fixtureYear, 5, 7, 8),
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
          _event('existing-1', '가기', DateTime(_fixtureYear, 7, 3, 9, 30)),
        ],
        now: () => DateTime(_fixtureYear, 7, 3, 10),
      );

      final showResult = controller.handle('오늘 일정 보여줘');
      expect(showResult.action, VoiceConversationAction.showEvents);
      expect(controller.focusedEvent?.id, 'existing-1');

      final result = controller.handle('오늘 오후2시에 모란역으로 가기 일정생성해줘');

      expect(result.action, VoiceConversationAction.createEvent);
      expect(result.targetEvent, isNull);
      expect(result.draftEvent, isNotNull);
    });

    test('시간 없는 새 일정은 날짜와 관계없이 오전 9시로 만든다', () {
      final now = DateTime(DateTime.now().year + 1, 7, 3, 16, 40);
      final controller = VoiceConversationController(
        now: () => now,
      );

      final dated = controller.handle('내일 프로젝트 회의 일정으로 저장');
      final undated = controller.handle('프로젝트 회의 일정으로 저장');

      expect(dated.action, VoiceConversationAction.createEvent);
      expect(
        dated.draftEvent?.startAt,
        DateTime(now.year, now.month, now.day + 1, 9),
      );
      expect(undated.action, VoiceConversationAction.createEvent);
      expect(
        undated.draftEvent?.startAt,
        DateTime(now.year, now.month, now.day, 9),
      );
    });

    test(
      'single-date creation does not turn the half-open query end into a second day',
      () {
        final testYear = DateTime.now().year + 1;
        final controller = VoiceConversationController(
          now: () => DateTime(testYear, 8, 10, 12),
        );

        final result = controller.handle('9월 12일 태블릿계기반찍기 일정으로 저장');

        expect(result.action, VoiceConversationAction.createEvent);
        expect(result.draftEvent, isNotNull);
        expect(
          planflowLocal(result.draftEvent!.startAt!),
          DateTime(testYear, 9, 12, 9),
        );
        expect(
          planflowLocal(result.draftEvent!.endAt!),
          DateTime(testYear, 9, 12, 10),
        );
      },
    );
  });

  group('멀티턴 맥락 유지', () {
    test('다다음주 조회 후 "그 주에서 ~만 삭제"는 조회한 범위에서 후보를 좁힌다', () {
      // '다다음주'는 컨트롤러 now 기준이므로 절대 날짜 리터럴 없이 now를 고정한다.
      final now = DateTime(_fixtureYear, 7, 3, 10); // 금요일
      final controller = VoiceConversationController(
        events: <EventModel>[
          // 다음 주(7/6~7/12)의 단기렌트: 맥락 폴백 없이 후보를 좁히면
          // 범위 밖 이 일정까지 후보에 들어와 2개로 모호해진다.
          _event('rent-other', '단기렌트 청소', DateTime(_fixtureYear, 7, 8, 10)),
          _event(
              'rent-target', '단기렌트 물품 수령', DateTime(_fixtureYear, 7, 15, 10)),
        ],
        now: () => now,
      );

      final query = controller.handle('다다음주 일정 보여 줘');
      expect(query.action, VoiceConversationAction.showEvents);
      expect(
        query.visibleEvents.map((event) => event.id),
        contains('rent-target'),
      );
      expect(
        query.visibleEvents.map((event) => event.id),
        isNot(contains('rent-other')),
      );

      final deleteAsk = controller.handle('그 주에서 단기렌트만 삭제해 줘');
      expect(deleteAsk.action, VoiceConversationAction.confirmDelete);
      expect(deleteAsk.targetEvent?.id, 'rent-target');
      expect(deleteAsk.requiresDeleteConfirmation, isTrue);

      final confirmed = controller.handle('응 삭제해');
      expect(confirmed.action, VoiceConversationAction.deleteConfirmed);
      expect(confirmed.targetEvent?.id, 'rent-target');
    });

    test('조회 후 "같은 주 일정 보여 줘"는 동일 범위를 재조회한다', () {
      final now = DateTime(_fixtureYear, 7, 3, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('in-week', '주간 작업', DateTime(_fixtureYear, 7, 15, 10)),
          _event('out-week', '다른 주 작업', DateTime(_fixtureYear, 7, 8, 10)),
        ],
        now: () => now,
      );

      final first = controller.handle('다다음주 일정 보여 줘');
      expect(first.action, VoiceConversationAction.showEvents);
      expect(first.queryRange, isNotNull);

      final second = controller.handle('같은 주 일정 보여 줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(second.queryRange?.start, first.queryRange?.start);
      expect(second.queryRange?.end, first.queryRange?.end);
      expect(
        second.visibleEvents.map((event) => event.id).toSet(),
        first.visibleEvents.map((event) => event.id).toSet(),
      );
    });

    test('"방금 본 일정 중에 2번 삭제"는 조회 결과의 순번으로 선택한다', () {
      final now = DateTime(_fixtureYear, 7, 3, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '첫 회의', DateTime(_fixtureYear, 7, 4, 10)),
          _event('second', '둘째 회의', DateTime(_fixtureYear, 7, 4, 15)),
        ],
        now: () => now,
      );

      final query = controller.handle('내일 일정 보여 줘');
      expect(query.visibleEvents.length, 2);

      final result = controller.handle('방금 본 일정 중에 2번 삭제해 줘');
      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'second');
    });

    test('맥락 없이 "그 주 일정 보여 줘"라고 말하면 날짜를 다시 묻는다', () {
      final now = DateTime(_fixtureYear, 7, 3, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('some', '어떤 일정', DateTime(_fixtureYear, 7, 8, 10)),
        ],
        now: () => now,
      );

      final result = controller.handle('그 주 일정 보여 줘');
      expect(result.action, VoiceConversationAction.none);
      expect(result.assistantMessage, '어느 날짜인지 잘 모르겠어요. 조회할 날짜를 말해 주세요.');
    });

    test('제목 조회 후 지시어만 말하면 마지막 언급 제목으로 재검색해 삭제한다', () {
      final now = DateTime(_fixtureYear, 7, 3, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
              'rent-target', '단기렌트 물품 수령', DateTime(_fixtureYear, 7, 15, 10)),
          _event('other', '다른 회의', DateTime(_fixtureYear, 7, 15, 15)),
        ],
        now: () => now,
      );

      final titleQuery = controller.handle('단기렌트 물품 수령 일정 보여 줘');
      expect(titleQuery.action, VoiceConversationAction.showEvents);
      expect(titleQuery.visibleEvents.single.id, 'rent-target');
      expect(titleQuery.targetEvent?.id, 'rent-target');

      // 다른 조회로 focusedEvent를 해제한다(7/6~7/12 범위라 매칭 0개).
      final narrowQuery = controller.handle('다음주 일정 보여 줘');
      expect(narrowQuery.action, VoiceConversationAction.showEvents);
      expect(narrowQuery.visibleEvents, isEmpty);

      final deleteAsk = controller.handle('아까 그 일정 삭제해 줘');
      expect(deleteAsk.action, VoiceConversationAction.confirmDelete);
      expect(deleteAsk.targetEvent?.id, 'rent-target');
      expect(deleteAsk.requiresDeleteConfirmation, isTrue);
    });

    test('지시어 제목 폴백으로 2개가 매칭되면 목록을 보여 주고 번호를 요청한다', () {
      final now = DateTime(_fixtureYear, 7, 3, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('rent-1', '단기렌트 물품 수령', DateTime(_fixtureYear, 7, 15, 10)),
          _event('rent-2', '단기렌트 물품 반납', DateTime(_fixtureYear, 7, 16, 10)),
          _event('other', '다른 회의', DateTime(_fixtureYear, 7, 15, 15)),
        ],
        now: () => now,
      );

      final titleQuery = controller.handle('단기렌트 일정 보여 줘');
      expect(titleQuery.action, VoiceConversationAction.showEvents);
      expect(titleQuery.visibleEvents.length, 2);

      // focusedEvent를 해제하기 위해 매칭 0개 조회로 갈아끊운다.
      final narrowQuery = controller.handle('다음주 일정 보여 줘');
      expect(narrowQuery.visibleEvents, isEmpty);

      final result = controller.handle('아까 그 일정 삭제해 줘');
      expect(result.action, VoiceConversationAction.showEvents);
      expect(result.visibleEvents.length, 2);
      expect(
        result.visibleEvents.map((event) => event.id).toSet(),
        <String>{'rent-1', 'rent-2'},
      );
      expect(result.assistantMessage, contains('2개'));
    });

    test('반복 일정 조회 후 "그날" 삭제는 조회한 회차 날짜로 occurrenceDate를 설정한다', () {
      // "모레"가 항상 화요일이 되도록(BYDAY=TU와 정합) 미래의 가장 가까운
      // 화요일을 기준으로 삼는다 — 절대 날짜 리터럴 시한폭탄 방지.
      final DateTime tuesday = _nextWeekdayOnOrAfter(
        DateTime.now().add(const Duration(days: 400)),
        DateTime.tuesday,
      );
      final DateTime dayAfterTomorrow = tuesday;
      final DateTime today = dayAfterTomorrow.subtract(const Duration(days: 2));
      final DateTime anchorWeek = dayAfterTomorrow.subtract(
        const Duration(days: 7),
      );
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'recurring',
            '주간 회의',
            DateTime(anchorWeek.year, anchorWeek.month, anchorWeek.day, 9),
          ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU'),
        ],
        now: () => DateTime(today.year, today.month, today.day, 9),
      );

      final query = controller.handle('모레 일정 보여 줘');
      expect(query.action, VoiceConversationAction.showEvents);
      expect(
          query.visibleEvents.map((event) => event.id), contains('recurring'));

      final result = controller.handle('그날 일정 삭제해 줘');
      expect(result.action, VoiceConversationAction.confirmDelete);
      expect(result.targetEvent?.id, 'recurring');
      final occurrenceDate = result.pendingDelete?.occurrenceDate;
      expect(occurrenceDate, isNotNull);
      expect(occurrenceDate!.year, dayAfterTomorrow.year);
      expect(occurrenceDate.month, dayAfterTomorrow.month);
      expect(occurrenceDate.day, dayAfterTomorrow.day);
    });
  });

  group('그다음주 체이닝', () {
    // 회귀 방지: "그다음주"를 반복 발화하면 매번 +7일씩 다음 주로 전진해야 한다.
    // 파서는 stateless로 "그다음주"를 오늘+2주로 고정하지만 컨트롤러가 직전
    // 주 조회 범위에 7일을 더해 체이닝한다. 날짜는 모두 내년 기준 상대값.
    final year = DateTime.now().year + 1;
    final now = DateTime(year, 7, 3, 10);
    DateTime plus(DateTime from, int days) =>
        DateTime(from.year, from.month, from.day + days);
    final thisMonday = plus(now, -(now.weekday - 1));
    final nextMonday = plus(thisMonday, 7);

    test('"다음주" → "그다음주" → "그다음주"가 매번 +7일씩 다음 주로 전진한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('next-week', '다음주 회의', plus(nextMonday, 2)),
          _event('week-after', '다다음주 회의', plus(nextMonday, 9)),
          _event('week-after-2', '그다음주 회의', plus(nextMonday, 16)),
        ],
        now: () => now,
      );

      final first = controller.handle('다음주 일정 보여줘');
      expect(first.action, VoiceConversationAction.showEvents);
      expect(first.queryRange?.start, nextMonday);
      expect(first.queryRange?.end, plus(nextMonday, 7));
      expect(first.queryRange?.isMultiDay, isTrue);

      final second = controller.handle('그다음주 일정 보여줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(second.queryRange?.start, plus(nextMonday, 7));
      expect(second.queryRange?.end, plus(nextMonday, 14));
      expect(second.queryRange?.isMultiDay, isTrue);
      expect(
        second.visibleEvents.map((event) => event.id),
        <String>['week-after'],
      );

      final third = controller.handle('그다음주 일정 보여줘');
      expect(third.action, VoiceConversationAction.showEvents);
      expect(third.queryRange?.start, plus(nextMonday, 14));
      expect(third.queryRange?.end, plus(nextMonday, 21));
      expect(third.queryRange?.isMultiDay, isTrue);
      expect(
        third.visibleEvents.map((event) => event.id),
        <String>['week-after-2'],
      );

      final fourth = controller.handle('그다음주 일정 보여줘');
      expect(fourth.queryRange?.start, plus(nextMonday, 21));
      expect(fourth.queryRange?.end, plus(nextMonday, 28));
    });

    test('연 경계를 넘는 "그다음주" 체이닝도 정확히 +7일씩 전진한다', () {
      final yearEnd = DateTime(year, 12, 25, 10);
      final decNextMonday = plus(plus(yearEnd, -(yearEnd.weekday - 1)), 7);
      final controller = VoiceConversationController(
        events: <EventModel>[],
        now: () => yearEnd,
      );

      final first = controller.handle('다음주 일정 보여줘');
      expect(first.queryRange?.start, decNextMonday);

      final second = controller.handle('그다음주 일정 보여줘');
      expect(second.queryRange?.start, plus(decNextMonday, 7));
      expect(second.queryRange?.end, plus(decNextMonday, 14));
      // 다음 월요일(12/26~1/1) +7일은 항상 다음 해 1월이다.
      expect(second.queryRange!.start.year, year + 1);
      expect(second.queryRange!.start.month, 1);

      final third = controller.handle('그다음주 일정 보여줘');
      expect(third.queryRange?.start, plus(decNextMonday, 14));
      expect(third.queryRange?.end, plus(decNextMonday, 21));
    });

    test('첫 발화에서 "그다음주"는 직전 맥락 없이 오늘 기준 2주 뒤로 해석한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[],
        now: () => now,
      );

      final first = controller.handle('그다음주 일정 보여줘');
      expect(first.action, VoiceConversationAction.showEvents);
      expect(first.queryRange?.start, plus(thisMonday, 14));
      expect(first.queryRange?.end, plus(thisMonday, 21));
      expect(first.queryRange?.isMultiDay, isTrue);
    });

    test('단일일 조회 후 "그다음주"는 7일 주 범위가 아니므로 체이닝하지 않는다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('day-event', '특정 일일 일정', DateTime(year, 7, 10, 10)),
        ],
        now: () => now,
      );

      final day = controller.handle('7월 10일 일정 보여줘');
      expect(day.action, VoiceConversationAction.showEvents);
      expect(day.queryRange?.isMultiDay, isFalse);

      final second = controller.handle('그다음주 일정 보여줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(second.queryRange?.start, plus(thisMonday, 14));
      expect(second.queryRange?.end, plus(thisMonday, 21));
    });

    test('"이번주" 후 "그다음주"는 직전 이번주 +7일(=다음주)로 해석한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('this-week', '이번주 일정', plus(thisMonday, 1)),
          _event('next-week', '다음주 일정', plus(nextMonday, 1)),
        ],
        now: () => now,
      );

      final first = controller.handle('이번주 일정 보여줘');
      expect(first.queryRange?.start, thisMonday);
      expect(first.queryRange?.end, nextMonday);

      final second = controller.handle('그다음주 일정 보여줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(second.queryRange?.start, nextMonday);
      expect(second.queryRange?.end, plus(nextMonday, 7));
      expect(
        second.visibleEvents.map((event) => event.id),
        <String>['next-week'],
      );
    });

    test('STT 공백이 섞인 "그 다음 주"도 동일하게 체이닝한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[],
        now: () => now,
      );

      controller.handle('다음주 일정 보여줘');
      final second = controller.handle('그 다음 주 일정 보여줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(second.queryRange?.start, plus(nextMonday, 7));
      expect(second.queryRange?.end, plus(nextMonday, 14));
    });

    test('"그다음주" 텍스트에 명시적 날짜가 끼면 그 명시적 날짜가 우선한다', () {
      final march = DateTime(year, 3, 1, 10);
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('march-5', '3월 5일 일정', DateTime(year, 3, 5, 10)),
        ],
        now: () => march,
      );

      controller.handle('다음주 일정 보여줘');
      final explicit = controller.handle('3월 5일 그다음주 일정 보여줘');
      expect(explicit.action, VoiceConversationAction.showEvents);
      expect(explicit.queryRange?.start, DateTime(year, 3, 5));
      expect(explicit.queryRange?.end, DateTime(year, 3, 6));
      expect(
        explicit.visibleEvents.map((event) => event.id),
        <String>['march-5'],
      );
    });
  });

  group('날짜 자동 저장', () {
    // 시한폭탄 방지: now/anchor 모두 DateTime.now().year+1 기준으로 동적 계산.
    final year = DateTime.now().year + 1;
    // anchorNow를 임의의 월요일로 고정해 weekday 산술에 사용.
    final DateTime anchorNow = DateTime(year, 7, 6, 9);
    final DateTime nextMonday = anchorNow
        .add(Duration(days: (DateTime.monday - anchorNow.weekday) % 7));
    // 다음 해 첫 월요일은 year-12-28 다음 주 월요일로 동적 계산.

    test('종료/구간 발화는 시작 단독 자동 저장 대신 편집 화면으로 보낸다', () {
      for (final utterance in <String>[
        '이 일정 6월 19일 9시부터 11시까지로 변경해줘',
        '이 일정 6월 19일 아홉시부터 열한시까지로 변경해줘',
        '이 일정 6월 19일 11시 2시간 동안으로 바꿔줘',
      ]) {
        final controller = VoiceConversationController(
          events: <EventModel>[
            _event('target', '단기렌트', DateTime(year, 7, 19, 9)),
          ],
          now: () => DateTime(year, 6, 7, 8),
        );
        controller.handle('7월 19일 일정 보여줘');
        final result = controller.handle(utterance);
        expect(result.canAutoApplyDateChange, isFalse, reason: utterance);
        expect(result.action, VoiceConversationAction.openEditScreen,
            reason: utterance);
      }
    });

    test('오후 3시 단독 시작 변경은 자동 저장되고 종료는 1시간 뒤다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('target', '단기렌트', DateTime(year, 7, 19, 9)),
        ],
        now: () => DateTime(year, 6, 7, 8),
      );
      controller.handle('7월 19일 일정 보여줘');
      final result = controller.handle('이 일정 6월 19일 오후 3시로 바꿔줘');
      expect(result.canAutoApplyDateChange, isTrue);
      expect(
          planflowLocal(result.draftEvent!.endAt!), DateTime(year, 6, 19, 16));
    });

    test('명시적 목적지일 변경은 자동으로 저장된다 (확정 날짜 우선)', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('target', '단기렌트', DateTime(year, 7, 19, 9)),
        ],
        now: () => DateTime(year, 6, 7, 8),
      );
      controller.handle('7월 19일 일정 보여줘');

      final result = controller.handle('이 일정 6월 19일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(year, 6, 19, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(year, 6, 19, 10),
      );
      expect(
        planflowLocal(result.targetEvent!.startAt!),
        DateTime(year, 7, 19, 9),
      );
    });

    test('소스 날짜와 다른 요일의 요청 날짜가 정확히 적용된다', () {
      final wed = nextMonday.add(const Duration(days: 2));
      final sun = nextMonday.add(const Duration(days: 6));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('target', '회의', DateTime(wed.year, wed.month, wed.day, 10)),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 일요일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(sun.year, sun.month, sun.day, 10),
      );
    });

    test('요일 단독 발화도 자동으로 저장된다 (일요일로 바꿔줘)', () {
      final sourceWednesday = nextMonday.add(const Duration(days: 2));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'only',
            '출장',
            DateTime(
              sourceWednesday.year,
              sourceWednesday.month,
              sourceWednesday.day,
              14,
            ),
          ),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 일요일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      final newStart = planflowLocal(result.draftEvent!.startAt!);
      expect(newStart.weekday, DateTime.sunday);
      expect(newStart.hour, 14);
    });

    test('공백 있는 "그 다음 주"는 대상 이벤트에 +7일을 적용한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '주간회의', DateTime(year, 7, 6, 9)),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 그 다음 주로 미뤄줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(year, 7, 13, 9),
      );
      expect(
        planflowLocal(result.draftEvent!.endAt!),
        DateTime(year, 7, 13, 10),
      );
    });

    test('+14일 "다다음주로 미뤄줘"는 정확히 2주 뒤로 이동한다', () {
      final source = nextMonday.add(const Duration(days: 2));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'only',
            '주간회의',
            DateTime(source.year, source.month, source.day, 9),
          ),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 다다음주로 미뤄줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      final expectedDate = DateTime(source.year, source.month, source.day + 14);
      final newStart = planflowLocal(result.draftEvent!.startAt!);
      expect(newStart.year, expectedDate.year);
      expect(newStart.month, expectedDate.month);
      expect(newStart.day, expectedDate.day);
    });

    test('연 경계를 넘는 자동 저장도 정확히 적용된다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '연말정리', DateTime(year, 12, 28, 11)),
        ],
        now: () => DateTime(year, 12, 27, 8),
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 다음주 월요일로 옮겨줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      final newStart = planflowLocal(result.draftEvent!.startAt!);
      expect(newStart.weekday, DateTime.monday);
      expect(newStart.year, year + 1);
    });

    test('순번으로 가리킨 일정은 자동으로 저장된다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(year, 7, 6, 9)),
          _event('second', '출장', DateTime(year, 7, 7, 9)),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      // 7/6은 now 기준 이전이라 weekly query에서 누락될 수 있어 명시적 날짜로 조회.
      controller.handle('7월 6일 일정 보여줘');

      final result = controller.handle('1번 일정 7월 15일로 바꿔줘');

      expect(result.action, VoiceConversationAction.confirmedEdit);
      expect(result.canAutoApplyDateChange, isTrue);
      expect(
        planflowLocal(result.draftEvent!.startAt!),
        DateTime(year, 7, 15, 9),
      );
    });

    test('혼합 변경(장소+시간)은 자동 저장하지 않고 편집 화면으로 보낸다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '회의', DateTime(year, 7, 6, 9)),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle(
        '1번 일정 장소를 서울 강남역으로 변경하고 시간은 8시로 바꿔줘',
      );

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.canAutoApplyDateChange, isFalse);
      expect(result.locationText, '서울 강남역');
    });

    test('반복 일정은 자동 저장하지 않고 편집 화면으로 보낸다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '주간회의', DateTime(year, 7, 6, 9)).copyWith(
            recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
          ),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 수요일로 바꿔줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.canAutoApplyDateChange, isFalse);
      expect(result.draftEvent?.recurrenceRule, 'FREQ=WEEKLY;BYDAY=MO');
    });

    test('대상을 식별할 수 없으면 자동 저장하지 않는다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('first', '회의', DateTime(year, 7, 6, 9)),
          _event('second', '출장', DateTime(year, 7, 6, 10)),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('그 일정 다음주로 미뤄줘');

      expect(result.canAutoApplyDateChange, isFalse);
    });

    test('실제 변경이 없으면 confirmedEdit가 아니다', () {
      final source = DateTime(year, 7, 6, 9); // Monday
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '확정 일정', source),
        ],
        now: () => anchorNow,
      );
      controller.handle('7월 6일 일정 보여줘');

      // 시각을 명확히 다르게 지정하지 않으면 시간이 0시로 강제될 수 있어,
      // 같은 요일·같은 시각의 다른 날짜로 요청하여 no-op을 검증한다.
      final result = controller.handle(
        '1번 일정 다음주 월요일로 옮겨줘',
      );

      // Monday 이지만 +7일 차이가 분명히 있으므로 autoApply 가능 (positive test).
      expect(result.canAutoApplyDateChange, isTrue);
    });

    test('외부 캘린더 링크 일정은 자동 저장하지 않는다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('linked', '외부 일정', DateTime(year, 7, 6, 9)).copyWith(
            externalCalendarId: 'ext-cal-1',
          ),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final result = controller.handle('1번 일정 다음주로 미뤄줘');

      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.canAutoApplyDateChange, isFalse);
      expect(result.draftEvent, isNotNull);
    });

    test('조회 체인(_parseDateRangeWithContext) 회귀 없음', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'next',
            '다음주 회의',
            DateTime(
              nextMonday.year,
              nextMonday.month,
              nextMonday.day + 1,
              10,
            ),
          ),
        ],
        now: () => anchorNow,
      );

      final first = controller.handle('다음주 일정 보여줘');
      expect(first.action, VoiceConversationAction.showEvents);
      expect(
        first.queryRange?.start,
        DateTime(nextMonday.year, nextMonday.month, nextMonday.day),
      );

      final second = controller.handle('그다음주 일정 보여줘');
      expect(second.action, VoiceConversationAction.showEvents);
      expect(
        second.queryRange?.start,
        DateTime(
          nextMonday.year,
          nextMonday.month,
          nextMonday.day + 7,
        ),
      );
    });

    test('replaceEvents 후에도 비반복 focusedEvent 참조가 최신 인스턴스로 갱신된다', () {
      final sourceStart = nextMonday.add(const Duration(days: 2));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'only',
            '주간회의',
            DateTime(sourceStart.year, sourceStart.month, sourceStart.day, 9),
          ),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final firstShift = controller.handle('1번 일정 그 다음 주로 미뤄줘');
      expect(firstShift.action, VoiceConversationAction.confirmedEdit);
      expect(firstShift.canAutoApplyDateChange, isTrue);
      // 저장된 초안 (savedStart) 은 원본 +7일로 옮겨진 시각이다.
      final savedStart = firstShift.draftEvent!.startAt!;

      // UI 측자가 저장된 결과를 로컬 이벤트 목록에 반영한다.
      controller.replaceEvents(<EventModel>[
        _event(
          'only',
          '주간회의',
          planflowLocal(savedStart),
        ),
      ]);

      // 다시 +14일을 적용. 만약 focusedEvent가 옛 인스턴스를 가리키면
      // 옛 startAt(원본 +7일)에서 +14일이 더해져 잘못된 결과가 나온다.
      final secondShift = controller.handle('1번 일정 다다음주로 미뤄줘');

      expect(secondShift.action, VoiceConversationAction.confirmedEdit);
      expect(secondShift.canAutoApplyDateChange, isTrue);
      final expectedStart =
          planflowLocal(savedStart).add(const Duration(days: 14));
      expect(
        planflowLocal(secondShift.draftEvent!.startAt!),
        expectedStart,
      );
      // saved fields preserved (title/location unchanged after refresh).
      expect(secondShift.draftEvent?.id, 'only');
      expect(secondShift.draftEvent?.title, '주간회의');
    });

    test('반복 일정의 확장 회차는 replaceEvents 후에도 그대로 남는다', () {
      // anchor가 1주 전, 이번주 회차가 BYDAY=MO 와 일치하는 단일 occurrence.
      final expandedOccurrence = nextMonday;
      final anchorStart = expandedOccurrence
          .subtract(const Duration(days: 7))
          .add(const Duration(hours: 9));
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event(
            'recurring',
            '주간회의',
            anchorStart,
          ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO'),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');

      final focusedBefore = controller.focusedEvent;
      expect(focusedBefore, isNotNull);
      expect(focusedBefore!.recurrenceRule, isNotEmpty);

      controller.replaceEvents(<EventModel>[
        _event(
          'recurring',
          '주간회의',
          anchorStart,
        ).copyWith(recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO'),
      ]);

      // 반복 일정이라 occurrence 인스턴스가 anchor로 교체되면 안 된다.
      final focusedAfter = controller.focusedEvent;
      expect(focusedAfter, isNotNull);
      expect(focusedAfter, same(focusedBefore));
    });

    test('replaceEvents에 focused id가 없으면 reference가 정리된다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[
          _event('only', '주간회의', nextMonday.add(const Duration(hours: 9))),
        ],
        now: () => anchorNow,
      );
      controller.handle('이번주 일정 보여줘');
      // 첫 편집으로 focusedEvent를 잡아 둔다.
      controller.handle('1번 일정 다음주로 미뤄줘');
      expect(controller.focusedEvent, isNotNull);

      // 다른 id의 이벤트로 교체 (focused id 누락).
      controller.replaceEvents(<EventModel>[
        _event('different', '다른 일정', nextMonday.add(const Duration(hours: 10))),
      ]);

      expect(controller.focusedEvent, isNull);
    });
  });

  group('날짜 변경 draft 메타데이터 보존', () {
    // 절대 연도 리터럴 없이 실행 시점 기준 미래 상대 날짜만 사용한다.
    final DateTime baseNow = DateTime.now();
    final DateTime tomorrow = DateTime(
      baseNow.year,
      baseNow.month,
      baseNow.day + 1,
      9,
    );
    final DateTime overriddenAt = planflowLocalDateTimeToUtc(tomorrow);
    final DateTime deletedAt = planflowLocalDateTimeToUtc(
      tomorrow.add(const Duration(days: 7)),
    );

    EventModel metadataRichEvent(String id, String title) {
      return EventModel(
        id: id,
        userId: 'user-1',
        title: title,
        startAt: planflowLocalDateTimeToUtc(tomorrow),
        endAt: planflowLocalDateTimeToUtc(
          tomorrow.add(const Duration(hours: 1)),
        ),
        location: '강남역',
        memo: '지참물 확인',
        supplies: const <String>['노트북'],
        suppliesChecked: const <String>['노트북'],
        participants: const <String>['김민수'],
        targets: const <String>['디자인팀'],
        isCritical: true,
        useStrongAlarm: true,
        parentEventId: 'parent-1',
        overriddenOccurrenceDate: overriddenAt,
        deletedOccurrenceDates: <DateTime>[deletedAt],
        groupEventId: 'group-1',
        source: 'google',
        externalId: 'ext-1',
        externalCalendarId: 'ext-cal-1',
      );
    }

    void expectMetadataPreserved(EventModel draft, String id) {
      expect(draft.id, id);
      expect(draft.useStrongAlarm, isTrue);
      expect(draft.supplies, <String>['노트북']);
      expect(draft.suppliesChecked, <String>['노트북']);
      expect(draft.isCritical, isTrue);
      expect(draft.memo, '지참물 확인');
      expect(draft.participants, <String>['김민수']);
      expect(draft.targets, <String>['디자인팀']);
      expect(draft.parentEventId, 'parent-1');
      expect(draft.overriddenOccurrenceDate, overriddenAt);
      expect(draft.deletedOccurrenceDates, <DateTime>[deletedAt]);
      expect(draft.groupEventId, 'group-1');
      expect(draft.source, 'google');
      expect(draft.externalId, 'ext-1');
      expect(draft.externalCalendarId, 'ext-cal-1');
      expect(draft.recurrenceRule, isNull);
    }

    test('명시적 시각+장소 혼합 변경 초안은 강도알람과 메타데이터를 보존한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[metadataRichEvent('meta', '강도알람 회의')],
        now: () => baseNow,
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle(
        '1번 일정 장소를 서울오크우드 호텔로 변경하고 시간을 오후 5시로 변경해줘',
      );

      // 강도알람+외부링크+혼합 변경이므로 자동 저장 없이 편집 화면 폴백.
      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.canAutoApplyDateChange, isFalse);
      final draft = result.draftEvent!;
      final newStart = planflowLocal(draft.startAt!);
      final expectedDay = DateTime(
        baseNow.year,
        baseNow.month,
        baseNow.day + 1,
      );
      expect(newStart.year, expectedDay.year);
      expect(newStart.month, expectedDay.month);
      expect(newStart.day, expectedDay.day);
      expect(newStart.hour, 17);
      expect(draft.location, '서울오크우드 호텔');
      expectMetadataPreserved(draft, 'meta');
    });

    test('"다음주로 미뤄줘" 상대 이동 초안도 동일 플래그와 정체성을 보존한다', () {
      final controller = VoiceConversationController(
        events: <EventModel>[metadataRichEvent('meta-shift', '강도알람 회의')],
        now: () => baseNow,
      );
      controller.handle('내일 일정 보여줘');

      final result = controller.handle('1번 일정 다음주로 미뤄줘');

      // 강도알람+외부링크라 자동 저장 대신 편집 화면 폴백.
      expect(result.action, VoiceConversationAction.openEditScreen);
      expect(result.canAutoApplyDateChange, isFalse);
      final draft = result.draftEvent!;
      final newStart = planflowLocal(draft.startAt!);
      final expectedStart = DateTime(
        baseNow.year,
        baseNow.month,
        baseNow.day + 8,
        9,
      );
      expect(newStart.year, expectedStart.year);
      expect(newStart.month, expectedStart.month);
      expect(newStart.day, expectedStart.day);
      expect(newStart.hour, 9);
      expect(planflowLocal(draft.endAt!).hour, 10);
      expectMetadataPreserved(draft, 'meta-shift');
    });
  });
}

EventModel _event(String id, String title, DateTime localStart) {
  return _eventWithPeople(id, title, localStart);
}

String _editTimeWording(String input, DateTime today) {
  final date = _dateAt(today, 4);
  return input.replaceFirst(
      '명시 날짜', '${date.year}년 ${date.month}월 ${date.day}일');
}

Future<EventEditRoutePayload?> _openVoiceActionDraft(
  WidgetTester tester, {
  required EventModel event,
  required String input,
  required void Function(DateTime) observeDate,
  bool expectDraft = true,
}) async {
  EventEditRoutePayload? payload;
  final router = GoRouter(
    initialLocation: AppRoutes.voiceAction,
    routes: [
      GoRoute(
        path: AppRoutes.voiceAction,
        builder: (context, state) => VoiceActionScreen(
          rawText: '${event.title} $input 옮겨줘',
          action: VoiceScheduleAction.edit,
          eventRepository: _VoiceTimeEventRepository(event),
          groupRepository: _VoiceTimeGroupRepository(),
          gptService: _LocalVoiceTimeGptService(),
          userIdOverride: event.userId,
        ),
      ),
      GoRoute(
        path: AppRoutes.eventEditWithId,
        builder: (context, state) {
          payload = state.extra as EventEditRoutePayload;
          return const SizedBox();
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  observeDate(_dateAt(planflowNow(), 0));
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  await tester.tap(find
      .ancestor(
        of: find.text(event.title),
        matching: find.byType(InkWell),
      )
      .first);
  await tester.pumpAndSettle();
  observeDate(_dateAt(planflowNow(), 0));

  if (expectDraft) expect(payload?.original.id, event.id);
  return payload;
}

class _VoiceTimeEventRepository extends Fake implements EventRepository {
  _VoiceTimeEventRepository(this.event);

  final EventModel event;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => [event];

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      eventId == event.id ? event : null;
}

class _VoiceTimeWriteSpy extends _VoiceTimeEventRepository {
  _VoiceTimeWriteSpy(super.event);

  final savedEvents = <EventModel>[];
  int listCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listCount++;
    return super.listEvents(userId: userId);
  }

  @override
  Future<EventModel> updateEvent(EventModel updated) async {
    savedEvents.add(updated);
    return updated;
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async =>
      [];
}

class _VoiceTimeChangingWriteSpy extends _VoiceTimeWriteSpy {
  _VoiceTimeChangingWriteSpy(super.event, this.fresh);

  final EventModel fresh;
  int fetchCount = 0;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    fetchCount++;
    return eventId == fresh.id ? fresh : null;
  }
}

class _VoiceTimeGroupEventRepository extends Fake
    implements GroupEventRepository {
  @override
  Future<List<GroupEventModel>> getGroupEventsByPersonalEventId(
          String personalEventId) async =>
      [];
}

Future<void> _submitVoiceInputToAction(
  WidgetTester tester, {
  required EventModel event,
  required _VoiceTimeWriteSpy repository,
  required String input,
  String? expectedActionText,
  void Function(EventEditRoutePayload)? onOpenDraft,
}) async {
  final router = GoRouter(
    initialLocation: AppRoutes.voice,
    routes: [
      GoRoute(
        path: AppRoutes.voice,
        builder: (_, __) => VoiceInputScreen(
          autoStartOverride: false,
          gptService: _LocalVoiceTimeGptService(),
        ),
      ),
      GoRoute(
        path: AppRoutes.voiceAction,
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          expect(extra['action'], 'edit');
          if (expectedActionText != null) {
            expect(extra['raw_text'], expectedActionText);
          }
          return VoiceActionScreen(
            rawText: extra['raw_text'] as String,
            action: VoiceScheduleAction.edit,
            eventRepository: repository,
            groupRepository: _VoiceTimeGroupRepository(),
            groupEventRepository: _VoiceTimeGroupEventRepository(),
            gptService: _LocalVoiceTimeGptService(),
            userIdOverride: event.userId,
            reminderNotifyAtReader: (_, __) async => null,
          );
        },
      ),
      if (onOpenDraft != null)
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (_, state) {
            onOpenDraft(state.extra as EventEditRoutePayload);
            return const SizedBox();
          },
        ),
      GoRoute(path: AppRoutes.calendar, builder: (_, __) => const SizedBox()),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.enterText(find.byType(TextField), input);
  await tester.pumpAndSettle();
  await tester.tap(find.text('현재 내용으로 입력'));
  await tester.pumpAndSettle();
}

class _VoiceTimeGroupRepository extends Fake implements GroupRepository {
  @override
  Future<List<GroupModel>> listGroups() async => [];
}

class _LocalVoiceTimeGptService extends Fake implements GptService {
  @override
  Future<VoiceTextCleanupResult> cleanupVoiceText(
    String rawText, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) async =>
      VoiceTextCleanupService.cleanLocally(
        rawText,
        context: context,
        candidates: candidates,
      );
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
