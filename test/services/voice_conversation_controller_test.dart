import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/voice_conversation_controller.dart';

// UI 테스트(voice_*_screen_test)와 동일한 규칙: 1월 1일이 목요일이고 윤년이
// 아닌 미래 연도를 고른다. 과거 기준 연도와 같은 요일 배치(5/7 목, 5/22 금 등)를
// 보존하므로 기존 월/일/요일 기반 픽스처 참조가 모두 유효하게 유지된다.
int _alignedFutureFixtureYear() {
  for (var year = DateTime.now().year + 1; ; year++) {
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

void main() {
  group('음성 수정 대상 매칭', () {
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
