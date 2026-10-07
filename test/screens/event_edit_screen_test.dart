import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';
import 'package:planflow/widgets/schedule_save_scope_card.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// UI 음성 테스트와 동일한 규칙: 1월 1일이 목요일인 윤년 아닌 미래 연도.
// 과거 기준 연도와 같은 요일 배치를 보존해 날짜 칩의 요일 접미사(목/월/금/수)가 유지된다.
int _alignedFutureFixtureYear() {
  for (var year = DateTime.now().year + 1; ; year++) {
    if (DateTime(year, 1, 1).weekday == DateTime.thursday &&
        !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) {
      return year;
    }
  }
}

final int _fixtureYear = _alignedFutureFixtureYear();

void main() {
  group('resolvePersistedEventId', () {
    test('returns null for a new-event draft with empty id', () {
      // AI 대화에서 넘어온 새 일정 draft: id가 "" → 새 일정으로 판정돼
      // createEvent로 가야 한다. (updateEvent로 가면 "Event id is required" 실패)
      expect(
        EventEditScreen.resolvePersistedEventId(
          loadedEventId: '',
          routeEventId: '',
          extraEventId: '',
        ),
        isNull,
      );
    });

    test('returns loaded event id when present', () {
      expect(
        EventEditScreen.resolvePersistedEventId(
          loadedEventId: 'event-1',
          routeEventId: null,
          extraEventId: null,
        ),
        'event-1',
      );
    });

    test('falls back to route id, then extra id, skipping blanks', () {
      expect(
        EventEditScreen.resolvePersistedEventId(
          loadedEventId: '   ',
          routeEventId: 'route-id',
          extraEventId: 'extra-id',
        ),
        'route-id',
      );
      expect(
        EventEditScreen.resolvePersistedEventId(
          loadedEventId: null,
          routeEventId: '',
          extraEventId: 'extra-id',
        ),
        'extra-id',
      );
    });
  });

  group('linked recurring edit scope guard', () {
    for (final scope in <String>['single', 'future']) {
      test('blocks $scope when an existing group link is known', () {
        expect(
          EventEditScreen.shouldBlockLinkedRecurringPartialEdit(
            isRecurring: true,
            recurrenceScope: scope,
            hasLinkedGroupCopies: true,
            hasGroupEventId: false,
            isSharingToSelectedGroups: false,
          ),
          isTrue,
        );
      });

      test('blocks $scope when sharing to selected groups', () {
        expect(
          EventEditScreen.shouldBlockLinkedRecurringPartialEdit(
            isRecurring: true,
            recurrenceScope: scope,
            hasLinkedGroupCopies: false,
            hasGroupEventId: false,
            isSharingToSelectedGroups: true,
          ),
          isTrue,
        );
      });
    }

    test('group_event_id is a fallback when the link query is empty', () {
      expect(
        EventEditScreen.shouldBlockLinkedRecurringPartialEdit(
          isRecurring: true,
          recurrenceScope: 'single',
          hasLinkedGroupCopies: false,
          hasGroupEventId: true,
          isSharingToSelectedGroups: false,
        ),
        isTrue,
      );
    });

    test('allows whole-series edits of linked recurring events', () {
      expect(
        EventEditScreen.shouldBlockLinkedRecurringPartialEdit(
          isRecurring: true,
          recurrenceScope: 'all',
          hasLinkedGroupCopies: true,
          hasGroupEventId: true,
          isSharingToSelectedGroups: true,
        ),
        isFalse,
      );
    });

    test('allows partial edits when the recurring event is not linked/shared',
        () {
      expect(
        EventEditScreen.shouldBlockLinkedRecurringPartialEdit(
          isRecurring: true,
          recurrenceScope: 'future',
          hasLinkedGroupCopies: false,
          hasGroupEventId: false,
          isSharingToSelectedGroups: false,
        ),
        isFalse,
      );
    });
  });

  group('linked group edit save policy', () {
    test('blocks personal-only edits when active group copies are linked', () {
      expect(
        EventEditScreen.shouldBlockLinkedGroupSaveScope(
          hasLinkedGroupCopies: true,
          hasGroupEventId: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: false,
        ),
        isTrue,
      );
    });

    test('blocks group-only edits when active group copies are linked', () {
      expect(
        EventEditScreen.shouldBlockLinkedGroupSaveScope(
          hasLinkedGroupCopies: true,
          hasGroupEventId: false,
          shouldSavePersonalEvent: false,
          shouldSaveGroupEvent: true,
        ),
        isTrue,
      );
    });

    test('allows linked edits only when personal and group are both saved', () {
      expect(
        EventEditScreen.shouldBlockLinkedGroupSaveScope(
          hasLinkedGroupCopies: true,
          hasGroupEventId: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: true,
        ),
        isFalse,
      );
    });

    test('does not restrict a personal-only event with no group links', () {
      expect(
        EventEditScreen.shouldBlockLinkedGroupSaveScope(
          hasLinkedGroupCopies: false,
          hasGroupEventId: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: false,
        ),
        isFalse,
      );
    });

    test('uses group_event_id as a fallback when links are not returned', () {
      expect(
        EventEditScreen.shouldBlockLinkedGroupSaveScope(
          hasLinkedGroupCopies: false,
          hasGroupEventId: true,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: false,
        ),
        isTrue,
      );
    });

    test('uses atomic update-and-share for whole linked event edits', () {
      expect(
        EventEditScreen.shouldUseAtomicGroupShareForUpdate(
          isNewEvent: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: true,
          recurrenceScope: null,
        ),
        isTrue,
      );
      expect(
        EventEditScreen.shouldUseAtomicGroupShareForUpdate(
          isNewEvent: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: true,
          recurrenceScope: 'single',
        ),
        isFalse,
      );
      expect(
        EventEditScreen.shouldUseAtomicGroupShareForUpdate(
          isNewEvent: false,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: true,
          recurrenceScope: 'future',
        ),
        isFalse,
      );
      expect(
        EventEditScreen.shouldUseAtomicGroupShareForUpdate(
          isNewEvent: true,
          shouldSavePersonalEvent: true,
          shouldSaveGroupEvent: true,
          recurrenceScope: null,
        ),
        isFalse,
      );
    });

    test('atomic update includes existing and newly selected groups once', () {
      expect(
        EventEditScreen.mergeLinkedAndSelectedGroupIdsForEdit(
          linkedGroupIds: <String>['group-a', 'group-a', ' '],
          selectedGroupIds: <String>['group-b', 'group-a'],
        ),
        <String>['group-a', 'group-b'],
      );
    });
  });

  group('shouldHydratePersistedCoordinates', () {
    const persisted = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: '회의',
      location: '강남역',
      locationLat: 37.4979,
      locationLng: 127.0276,
    );

    test('hydrates a same-location partial route event', () {
      expect(
        EventEditScreen.shouldHydratePersistedCoordinates(
          routeEvent: const EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '회의',
            location: '강남역',
          ),
          persistedEvent: persisted,
        ),
        isTrue,
      );
    });

    test(
        'hydrates persisted coordinates even when route location label differs',
        () {
      expect(
        EventEditScreen.shouldHydratePersistedCoordinates(
          routeEvent: const EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '회의',
            location: '서울 오크우드 호텔',
          ),
          persistedEvent: persisted,
        ),
        isTrue,
      );
    });

    test('does not hydrate coordinates across different event ids', () {
      expect(
        EventEditScreen.shouldHydratePersistedCoordinates(
          routeEvent: const EventModel(
            id: 'event-2',
            userId: 'user-1',
            title: '다른 일정',
            location: '서울 오크우드 호텔',
          ),
          persistedEvent: persisted,
        ),
        isFalse,
      );
    });

    test('does not hydrate an id-less draft by matching the location label',
        () {
      expect(
        EventEditScreen.shouldHydratePersistedCoordinates(
          routeEvent: const EventModel(
            id: '',
            userId: 'user-1',
            title: '새 일정',
            location: '강남역',
          ),
          persistedEvent: persisted,
        ),
        isFalse,
      );
    });

    test('keeps route coordinates when they are already resolved', () {
      expect(
        EventEditScreen.shouldHydratePersistedCoordinates(
          routeEvent: const EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '회의',
            location: '임시 장소',
            locationLat: 35.0,
            locationLng: 129.0,
          ),
          persistedEvent: persisted,
        ),
        isFalse,
      );
    });
  });

  group('route draft 날짜 프리필 (음성 요청 날짜 우선)', () {
    final year = DateTime.now().year + 1;
    final requestedStart = DateTime(year, 3, 15, 9);
    final requestedEnd = DateTime(year, 3, 15, 10);

    // calendar_style_event_editor.dart 날짜 칩과 동일한 라벨 규칙.
    String dateLabel(DateTime value) {
      const labels = <int, String>{
        DateTime.monday: '월',
        DateTime.tuesday: '화',
        DateTime.wednesday: '수',
        DateTime.thursday: '목',
        DateTime.friday: '금',
        DateTime.saturday: '토',
        DateTime.sunday: '일',
      };
      return '${value.year % 100}. ${value.month}. ${value.day}.'
          '(${labels[value.weekday]})';
    }

    testWidgets('eventId가 있어도 화면은 요청한 draft 날짜를 유지한다', (tester) async {
      // 회귀: 음성 대화가 '/event/edit/{id}' + extra draft로 진입시켰을 때,
      // persisted 재조회/좌표 hydrate 과정에서도 요청한 startAt/endAt이
      // 원래 persisted 날짜로 되돌아가면 안 된다.
      final persistedOriginalStart = DateTime(year, 3, 19, 9);
      final fake = _RecordingEventRepository(
        EventModel(
          id: 'event-1',
          userId: 'user-1',
          title: '회의',
          startAt: persistedOriginalStart,
          endAt: DateTime(year, 3, 19, 10),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            event: EventModel(
              id: 'event-1',
              userId: 'user-1',
              title: '회의',
              startAt: requestedStart,
              endAt: requestedEnd,
            ),
            eventId: 'event-1',
            eventRepository: fake,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editor = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      expect(editor.startAt, planflowLocal(requestedStart));
      expect(editor.endAt, planflowLocal(requestedEnd));
      expect(
        find.text(dateLabel(planflowLocal(requestedStart))),
        findsWidgets,
      );
      // 원래 persisted 날짜는 어디에도 표시되지 않는다.
      expect(
        find.text(dateLabel(planflowLocal(persistedOriginalStart))),
        findsNothing,
      );
    });

    testWidgets('반복 occurrence draft는 anchor를 유지하고 이동된 날짜를 표시한다',
        (tester) async {
      final originalOccurrence = DateTime(year, 3, 1, 10);
      final draft = EventModel(
        id: 'occurrence-1',
        userId: 'user-1',
        title: '주간 회의',
        startAt: requestedStart,
        endAt: requestedEnd,
        parentEventId: 'series-1',
        overriddenOccurrenceDate: originalOccurrence,
      );

      await tester.pumpWidget(MaterialApp(home: EventEditScreen(event: draft)));
      await tester.pumpAndSettle();

      final editor = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      // 표시되는 날짜는 이동 후(요청) 날짜다.
      expect(editor.startAt, planflowLocal(requestedStart));
      expect(
        find.text(dateLabel(planflowLocal(requestedStart))),
        findsWidgets,
      );
      // anchor(parent_event_id + overridden_occurrence_date)는 화면이 들고
      // 있는 draft에 그대로 남아, 저장 시 이 이동이 "원래 occurrence의 이동"으로
      // 기록될 수 있어야 한다. 시리즈 전체 조작으로 바뀌면 안 된다.
      final screen = tester.widget<EventEditScreen>(
        find.byType(EventEditScreen),
      );
      expect(screen.event!.id, 'occurrence-1');
      expect(screen.event!.parentEventId, 'series-1');
      expect(screen.event!.overriddenOccurrenceDate, originalOccurrence);
    });
  });

  group('shouldClearLocationCoordinatesOnTextChange', () {
    test('데이터 로드 중(isApplyingLoadedEvent=true)에는 절대 좌표를 지우지 않는다', () {
      // 회귀: fetchEvent로 불러온 event.location을 _locationController.text에
      // 프로그램적으로 대입할 때도 TextField.onChanged가 호출돼, 이 가드가
      // 없으면 방금 불러온 정상 좌표가 지워지고 다음날 알람이 엉뚱한 장소로 울렸다.
      expect(
        EventEditScreen.shouldClearLocationCoordinatesOnTextChange(
          isApplyingLoadedEvent: true,
          changedText: '래온동물병원',
          resolvedLocationLabel: null,
          hasCoordinates: true,
        ),
        isFalse,
      );
    });

    test('사용자가 실제로 텍스트를 바꾸면 좌표를 지운다', () {
      expect(
        EventEditScreen.shouldClearLocationCoordinatesOnTextChange(
          isApplyingLoadedEvent: false,
          changedText: '다른 장소',
          resolvedLocationLabel: '래온동물병원',
          hasCoordinates: true,
        ),
        isTrue,
      );
    });

    test('텍스트가 이미 해석된 라벨과 같으면 지우지 않는다', () {
      expect(
        EventEditScreen.shouldClearLocationCoordinatesOnTextChange(
          isApplyingLoadedEvent: false,
          changedText: '래온동물병원',
          resolvedLocationLabel: '래온동물병원',
          hasCoordinates: true,
        ),
        isFalse,
      );
    });

    test('좌표가 원래 없었으면 지울 것도 없다', () {
      expect(
        EventEditScreen.shouldClearLocationCoordinatesOnTextChange(
          isApplyingLoadedEvent: false,
          changedText: '아무 텍스트',
          resolvedLocationLabel: null,
          hasCoordinates: false,
        ),
        isFalse,
      );
    });
  });

  group('normalizeReminderOffset', () {
    test('정상 범위 내 값(60분)은 그대로 유지', () {
      final result = EventEditScreen.normalizeReminderOffset(60);
      expect(result, const Duration(minutes: 60));
    });

    test('정상 범위 내 값(30분)은 그대로 유지', () {
      final result = EventEditScreen.normalizeReminderOffset(30);
      expect(result, const Duration(minutes: 30));
    });

    test('정상 범위 내 최대값(1440분)은 그대로 유지', () {
      final result = EventEditScreen.normalizeReminderOffset(1440);
      expect(result, const Duration(minutes: 1440));
    });

    test('정상 범위 내 최소값(0분)은 그대로 유지', () {
      final result = EventEditScreen.normalizeReminderOffset(0);
      expect(result, const Duration(minutes: 0));
    });

    test('음수(-30분)는 기본값(60분)으로 폴백', () {
      final result = EventEditScreen.normalizeReminderOffset(-30);
      expect(result, const Duration(minutes: 60));
    });

    test('범위 초과 비정상값(10140분)은 기본값(60분)으로 폴백', () {
      // 일정이 7일 뒤로 이동했을 때 역산값: 7*24*60 + 60 = 10140분
      // 이것이 "169시간 전" 같은 비정상 표시를 만드는 경우
      final result = EventEditScreen.normalizeReminderOffset(10140);
      expect(result, const Duration(minutes: 60));
    });

    test('범위 초과 다른 값(2000분)도 기본값(60분)으로 폴백', () {
      final result = EventEditScreen.normalizeReminderOffset(2000);
      expect(result, const Duration(minutes: 60));
    });

    test('범위 경계 바로 위(1441분)는 기본값으로 폴백', () {
      final result = EventEditScreen.normalizeReminderOffset(1441);
      expect(result, const Duration(minutes: 60));
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  testWidgets('EventEditScreen uses inline calendar style editor',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(_fixtureYear, 5, 13, 0),
            endAt: DateTime.utc(_fixtureYear, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    expect(find.text('하루'), findsNothing);
    expect(find.text('연속'), findsNothing);
    expect(find.text('서울 (GMT+9:00)'), findsNothing);
    expect(find.text('저장'), findsOneWidget);
    expect(find.text('기본 정보'), findsOneWidget);
    expect(find.text('날짜 · 시간'), findsOneWidget);
    expect(find.text('시작 시간 조정'), findsNothing);

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('시작 시간 조정'), findsOneWidget);
  });

  testWidgets(
      'EventEditScreen displays draft date while retaining source event',
      (tester) async {
    final source = EventModel(
      id: 'event-source',
      userId: 'user-1',
      title: '원본 일정',
      startAt: DateTime.utc(_fixtureYear, 6, 12, 9),
      endAt: DateTime.utc(_fixtureYear, 6, 12, 10),
      isCritical: true,
      useStrongAlarm: true,
    );
    final draft = EventModel(
      id: source.id,
      userId: source.userId,
      title: '수정 일정',
      startAt: DateTime.utc(_fixtureYear, 6, 18, 9),
      endAt: DateTime.utc(_fixtureYear, 6, 18, 10),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(event: draft, originalEvent: source),
      ),
    );
    await tester.pumpAndSettle();

    final calendarEditor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    expect(calendarEditor.startAt, DateTime(_fixtureYear, 6, 18, 18));
    expect(find.text('수정 일정'), findsOneWidget);
    expect(find.text('${_fixtureYear % 100}. 6. 18.(목)'), findsWidgets);
  });

  testWidgets('EventEditScreen initializes new event date from selected date',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          initialDate: DateTime(_fixtureYear, 6, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('${_fixtureYear % 100}. 6. 15.(월)'), findsWidgets);
  });

  testWidgets('EventEditScreen keeps duration when start date changes',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '김창민 만나기',
            startAt: DateTime.utc(_fixtureYear, 6, 12, 9),
            endAt: DateTime.utc(_fixtureYear, 6, 12, 10),
            category: '개인',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('${_fixtureYear % 100}. 6. 12.(금)'), findsWidgets);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    editor.onStartChanged(DateTime(_fixtureYear, 6, 10, 9));
    await tester.pumpAndSettle();

    expect(find.text('${_fixtureYear % 100}. 6. 10.(수)'), findsWidgets);
    expect(find.text('${_fixtureYear % 100}. 6. 12.(금)'), findsNothing);
  });

  testWidgets(
      'EventEditScreen asks for full-screen consent when critical is enabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final permissions = _FakePermissionService();

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          permissionService: permissions,
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(_fixtureYear, 5, 13, 0),
            endAt: DateTime.utc(_fixtureYear, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('알림 옵션'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('알림 옵션'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('중요한 일정'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('중요한 일정'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('중요한 일정으로 표시'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();
    // 중요 표시 활성화 후 강한 알람 토글 — 이때 권한 다이얼로그가 열림
    await tester.scrollUntilVisible(
      find.text('강한 알람'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('강한 알람'));
    await tester.pumpAndSettle();

    expect(find.text('중요한 일정 알림 권한이 필요해요'), findsOneWidget);

    await tester.tap(find.text('허용하러 가기'));
    await tester.pumpAndSettle();

    expect(permissions.notificationPermissionsRequested, isTrue);
    expect(permissions.exactAlarmRequested, isTrue);
    expect(permissions.fullScreenIntentRequested, isTrue);
  });

  testWidgets('EventEditScreen keeps expanded sections visible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(_fixtureYear, 5, 13, 0),
            endAt: DateTime.utc(_fixtureYear, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    final cases = <({String header, String revealed})>[
      (header: '반복 설정', revealed: '반복 안 함'),
      (header: '설명 · 준비물', revealed: '준비물'),
      (header: '알림 옵션', revealed: '미리알림'),
      (header: '중요한 일정', revealed: '중요한 일정으로 표시'),
    ];

    for (final item in cases) {
      await tester.scrollUntilVisible(
        find.text(item.header),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(item.header));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.header));
      await tester.pumpAndSettle();

      final revealedRect = tester.getRect(find.text(item.revealed).last);
      expect(revealedRect.bottom, lessThanOrEqualTo(640));

      await tester.tap(find.text(item.header));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('EventEditScreen back falls back to home when opened directly',
      (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.eventEdit,
      routes: [
        GoRoute(
          path: AppRoutes.eventEdit,
          builder: (_, __) => EventEditScreen(
            event: EventModel(
              id: 'event-1',
              userId: 'user-1',
              title: '알림으로 연 일정',
              startAt: DateTime.utc(_fixtureYear, 5, 13, 0),
              endAt: DateTime.utc(_fixtureYear, 5, 13, 1),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('홈탭')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('홈탭'), findsOneWidget);
  });

  group('group save-scope', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      authProvider.setUser('user-1');
    });

    tearDown(() {
      authProvider.setUser(null);
    });

    GroupContextProvider buildContextProvider() {
      return GroupContextProvider(
        repository: _FakeGroupRepository(
          groups: <GroupModel>[
            GroupModel(
              id: 'group-1',
              createdBy: 'leader-1',
              name: '우리 팀',
              createdAt: DateTime.utc(_fixtureYear, 6, 11),
            ),
          ],
          membersByGroupId: <String, List<GroupMemberModel>>{
            'group-1': <GroupMemberModel>[
              GroupMemberModel(
                id: 'member-1',
                groupId: 'group-1',
                userId: 'user-1',
                role: 'member',
              ),
            ],
          },
        ),
      );
    }

    testWidgets('shows save-scope card when a group is selected',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            initialDate: DateTime(_fixtureYear, 6, 15),
            groupContextProvider: buildContextProvider(),
            groupEventRepository: _FakeGroupEventRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('저장 범위'), findsOneWidget);
      expect(find.text('개인 + 우리 팀'), findsOneWidget);
    });

    testWidgets(
        'auto-share preference ON defaults new event save target to personalAndGroup',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'planflow:group_auto_share:v1:user-1:group-1': true,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            initialDate: DateTime(_fixtureYear, 6, 15),
            groupContextProvider: buildContextProvider(),
            groupEventRepository: _FakeGroupEventRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 자동 공유 기본값이 적용돼 "개인 + 우리 팀"이 선택돼 있어야 한다.
      final scopeCard = tester.widget<ScheduleSaveScopeCard>(
        find.byType(ScheduleSaveScopeCard),
      );
      expect(scopeCard.selected, ScheduleSaveTarget.personalAndGroup);
    });

    testWidgets(
        'auto-share preference OFF keeps new event save target personalOnly',
        (tester) async {
      // pref 미설정(기본 OFF)
      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            initialDate: DateTime(_fixtureYear, 6, 15),
            groupContextProvider: buildContextProvider(),
            groupEventRepository: _FakeGroupEventRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scopeCard = tester.widget<ScheduleSaveScopeCard>(
        find.byType(ScheduleSaveScopeCard),
      );
      expect(scopeCard.selected, ScheduleSaveTarget.personalOnly);
    });

    testWidgets(
        'user tapping a save-scope option is not overwritten by auto-share default',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'planflow:group_auto_share:v1:user-1:group-1': true,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            initialDate: DateTime(_fixtureYear, 6, 15),
            groupContextProvider: buildContextProvider(),
            groupEventRepository: _FakeGroupEventRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('개인 일정만'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      final scopeCard = tester.widget<ScheduleSaveScopeCard>(
        find.byType(ScheduleSaveScopeCard),
      );
      expect(scopeCard.selected, ScheduleSaveTarget.personalOnly);
    });

    testWidgets('defaults the group picker to the most recently shared groups',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'planflow:group_last_shared_ids:v1:user-1': <String>['group-2'],
      });

      final provider = GroupContextProvider(
        repository: _FakeGroupRepository(
          groups: <GroupModel>[
            GroupModel(
              id: 'group-1',
              createdBy: 'user-1',
              name: '우리 팀',
              createdAt: DateTime.utc(_fixtureYear, 6, 11),
            ),
            GroupModel(
              id: 'group-2',
              createdBy: 'leader-2',
              name: '동아리',
              createdAt: DateTime.utc(_fixtureYear, 6, 12),
            ),
          ],
          membersByGroupId: <String, List<GroupMemberModel>>{
            'group-1': <GroupMemberModel>[
              GroupMemberModel(
                id: 'member-1',
                groupId: 'group-1',
                userId: 'user-1',
                role: 'leader',
              ),
            ],
            'group-2': <GroupMemberModel>[
              GroupMemberModel(
                id: 'member-2',
                groupId: 'group-2',
                userId: 'user-1',
                role: 'member',
              ),
            ],
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            initialDate: DateTime(_fixtureYear, 6, 15),
            groupContextProvider: provider,
            groupEventRepository: _FakeGroupEventRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // provider.selectedGroup 기본값(리더 그룹인 group-1)이 아니라, 마지막으로
      // 공유했던 group-2가 저장 범위 카드에 반영돼야 한다.
      expect(find.text('개인 + 동아리'), findsOneWidget);
      expect(find.text('개인 + 우리 팀'), findsNothing);
    });

    // 참고: "그룹 일정도 같이 수정할까요?" 다이얼로그(_chooseLinkedGroupEditScope)는
    // _handleSave() 내부에서 AppEnv.isSupabaseReady && 로그인 사용자 존재 조건을
    // 통과해야 도달한다. 이 프로젝트의 다른 위젯 테스트들도 실제 Supabase 로그인
    // 세션을 mock하지 않으므로(event_detail_screen_test.dart 등도 삭제 흐름만
    // 검증하고 currentUser가 필요한 저장 흐름은 다루지 않음), 여기서도 동일한
    // 인프라 한계로 저장 버튼을 통한 다이얼로그 노출까지는 직접 검증하지 못한다.
    // 대신 위 테스트들로 _saveTarget/_shouldSavePersonalEvent 판정과 저장 범위
    // 카드 UI가 정상 동작함을 확인했고, _chooseLinkedGroupEditScope 호출부는
    // 소스 리뷰로 개인만 수정/그룹도 같이 수정 두 옵션이 배선돼 있음을 확인했다.
  });
}

class _FakePermissionService extends AppPermissionService {
  bool notificationPermissionsRequested = false;
  bool exactAlarmRequested = false;
  bool fullScreenIntentRequested = false;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: true,
      locationGranted: true,
      calendarGranted: true,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: notificationPermissionsRequested,
        exactAlarmsEnabled: exactAlarmRequested,
        fullScreenIntentStatus: fullScreenIntentRequested
            ? PermissionCheckState.granted
            : PermissionCheckState.denied,
      ),
    );
  }

  @override
  Future<NotificationPermissionStatus> requestNotificationPermissions() async {
    notificationPermissionsRequested = true;
    return const NotificationPermissionStatus(
      notificationsEnabled: true,
      exactAlarmsEnabled: false,
      fullScreenIntentStatus: PermissionCheckState.denied,
    );
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactAlarmRequested = true;
    return true;
  }

  @override
  Future<bool> requestFullScreenIntentPermission() async {
    fullScreenIntentRequested = true;
    return true;
  }
}

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;

  @override
  Future<List<GroupModel>> listGroups() async => groups;

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    return membersByGroupId[groupId] ?? const <GroupMemberModel>[];
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }
}

class _FakeGroupEventRepository extends GroupEventRepository {
  final createdEvents = <GroupEventModel>[];

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    final saved = event.copyWith(
      id: 'group-event-${createdEvents.length + 1}',
    );
    createdEvents.add(saved);
    return saved;
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

/// 좌표 hydrate가 startAt/endAt을 건드리지 않음을 검증하기 위한 최소 fake.
class _RecordingEventRepository extends EventRepository {
  _RecordingEventRepository(this.persisted);

  final EventModel persisted;
  int fetchEventCalls = 0;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    fetchEventCalls++;
    return persisted;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => [persisted];

  @override
  Future<EventModel> createEvent(EventModel event) => Future.value(event);

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel> updateEvent(EventModel event) => Future.value(event);
}
