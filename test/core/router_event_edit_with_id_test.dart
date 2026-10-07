import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/event_edit_route_payload.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';

/// 회귀: 음성 대화 화면은 `context.push('${AppRoutes.eventEdit}/{id}',
/// extra: draft)`로 편집 화면에 진입한다. 실제 프로덕션 라우트
/// (eventEditWithId)의 builder가 state.extra(EventModel draft)를
/// EventEditScreen에 그대로 전달하는지, 전달된 draft의 날짜가 화면에
/// 그대로 표시되는지 검증한다. extra를 무시하거나 원래 일정으로
/// 대체하면 사용자가 요청한 날짜가 사라진다.
void main() {
  final year = DateTime.now().year + 1;

  // 전역 appRouter는 auth redirect 등 부수 로직이 붙어 있으므로, 실제
  // production eventEditWithId GoRoute만 작은 GoRouter로 조립해 검증한다.
  GoRouter routerWithProductionEditorRoute() {
    final editorRoute = appRouter.configuration.routes
        .whereType<GoRoute>()
        .firstWhere((route) => route.path == AppRoutes.eventEditWithId);
    return GoRouter(
      initialLocation: '/test-home',
      routes: [
        GoRoute(
          path: '/test-home',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        editorRoute,
      ],
    );
  }

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

  testWidgets('eventEditWithId builder는 extra draft를 그대로 전달해 요청 날짜를 표시한다',
      (tester) async {
    final requestedStart = DateTime(year, 3, 15, 9);
    final requestedEnd = DateTime(year, 3, 15, 10);
    final draft = EventModel(
      id: 'route-event-1',
      userId: 'user-1',
      title: '회의',
      startAt: requestedStart,
      endAt: requestedEnd,
    );
    final router = routerWithProductionEditorRoute();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    unawaited(
      router.push('${AppRoutes.eventEdit}/route-event-1', extra: draft),
    );
    await tester.pumpAndSettle();

    final screen = tester.widget<EventEditScreen>(
      find.byType(EventEditScreen),
    );
    expect(screen.eventId, 'route-event-1');
    expect(screen.event, isNotNull);
    expect(screen.event!.id, 'route-event-1');
    expect(screen.event!.startAt, requestedStart);
    expect(screen.event!.endAt, requestedEnd);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    expect(editor.startAt, planflowLocal(requestedStart));
    expect(editor.endAt, planflowLocal(requestedEnd));
    expect(find.text(dateLabel(planflowLocal(requestedStart))), findsWidgets);
  });

  testWidgets('반복 occurrence draft도 anchor를 유지한 채 요청 날짜로 진입한다', (tester) async {
    final movedStart = DateTime(year, 3, 15, 9);
    final originalOccurrence = DateTime(year, 3, 1, 10);
    final draft = EventModel(
      id: 'occurrence-1',
      userId: 'user-1',
      title: '주간 회의',
      startAt: movedStart,
      endAt: DateTime(year, 3, 15, 10),
      parentEventId: 'series-1',
      overriddenOccurrenceDate: originalOccurrence,
    );
    final router = routerWithProductionEditorRoute();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    unawaited(router.push('${AppRoutes.eventEdit}/occurrence-1', extra: draft));
    await tester.pumpAndSettle();

    final screen = tester.widget<EventEditScreen>(
      find.byType(EventEditScreen),
    );
    // anchor는 route 전달 과정에서 유실되지 않는다.
    expect(screen.event!.id, 'occurrence-1');
    expect(screen.event!.parentEventId, 'series-1');
    expect(screen.event!.overriddenOccurrenceDate, originalOccurrence);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    // 표시되는 날짜는 이동 후(요청) 날짜이지, anchor가 가리키는 원래
    // occurrence 날짜가 아니다.
    expect(editor.startAt, planflowLocal(movedStart));
    expect(find.text(dateLabel(planflowLocal(movedStart))), findsWidgets);
    expect(
      find.text(dateLabel(planflowLocal(originalOccurrence))),
      findsNothing,
    );
  });

  testWidgets(
      'DTO payload push: builder가 draft를 event로, source를 originalEvent로 전달한다',
      (tester) async {
    // canonical source는 이전 날짜, draft는 사용자가 요청한 +7일 날짜다.
    final canonicalOldStart = DateTime(year, 3, 8, 9);
    final canonicalOldEnd = DateTime(year, 3, 8, 10);
    final requestedStart = canonicalOldStart.add(const Duration(days: 7));
    final requestedEnd = canonicalOldEnd.add(const Duration(days: 7));
    final original = EventModel(
      id: 'route-dto-single',
      userId: 'user-1',
      title: '회의',
      startAt: canonicalOldStart,
      endAt: canonicalOldEnd,
      memo: 'source-meta',
      suppliesChecked: const ['물'],
      isCritical: true,
      useStrongAlarm: true,
    );
    final draft = EventModel(
      id: 'route-dto-single',
      userId: 'user-1',
      title: '회의',
      startAt: requestedStart,
      endAt: requestedEnd,
      memo: 'source-meta',
      suppliesChecked: const ['물'],
      isCritical: true,
      useStrongAlarm: true,
    );
    final router = routerWithProductionEditorRoute();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    unawaited(
      router.push(
        '${AppRoutes.eventEdit}/route-dto-single',
        extra: EventEditRoutePayload(draft: draft, original: original),
      ),
    );
    await tester.pumpAndSettle();

    final screen = tester.widget<EventEditScreen>(
      find.byType(EventEditScreen),
    );
    // 요청(draft) 일정이 route 전달 과정에서 유실되지 않는다.
    expect(screen.eventId, 'route-dto-single');
    expect(screen.event, isNotNull);
    expect(screen.event!.id, 'route-dto-single');
    expect(screen.event!.startAt, requestedStart);
    expect(screen.event!.endAt, requestedEnd);
    // source 메타(강한 알람/준비물 확인/중요/메모)가 draft에 그대로 보존된다.
    expect(screen.event!.useStrongAlarm, isTrue);
    expect(screen.event!.isCritical, isTrue);
    expect(screen.event!.suppliesChecked, ['물']);
    expect(screen.event!.memo, 'source-meta');
    // 저장 소스(original)는 canonical 이전 날짜를 유지한 채 별도로 전달된다.
    expect(screen.originalEvent, isNotNull);
    expect(screen.originalEvent!.id, 'route-dto-single');
    expect(screen.originalEvent!.startAt, canonicalOldStart);
    expect(screen.originalEvent!.useStrongAlarm, isTrue);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    // 표시되는 날짜는 요청(draft) 날짜이지 canonical 이전 날짜가 아니다.
    expect(editor.startAt, planflowLocal(requestedStart));
    expect(editor.endAt, planflowLocal(requestedEnd));
    expect(find.text(dateLabel(planflowLocal(requestedStart))), findsWidgets);
    expect(
      find.text(dateLabel(planflowLocal(canonicalOldStart))),
      findsNothing,
    );
  });

  testWidgets(
      'DTO payload push: 반복 series에서 originalOccurrenceStartAt가 선택 회차를 유지한다',
      (tester) async {
    // source는 반복 base(1일), 선택된 이전 회차는 15일, 이동 요청은 22일이다.
    final baseStart = DateTime(year, 1, 1, 10);
    final selectedOccurrence = DateTime(year, 1, 15, 10);
    final movedStart = DateTime(year, 1, 22, 9);
    final original = EventModel(
      id: 'series-dto-1',
      userId: 'user-1',
      title: '주간 회의',
      startAt: baseStart,
      endAt: DateTime(year, 1, 1, 11),
      recurrenceRule: 'RRULE:FREQ=WEEKLY',
    );
    final draft = EventModel(
      id: 'occurrence-dto-1',
      userId: 'user-1',
      title: '주간 회의',
      startAt: movedStart,
      endAt: DateTime(year, 1, 22, 10),
      parentEventId: 'series-dto-1',
      overriddenOccurrenceDate: selectedOccurrence,
    );
    final router = routerWithProductionEditorRoute();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    unawaited(
      router.push(
        '${AppRoutes.eventEdit}/occurrence-dto-1',
        extra: EventEditRoutePayload(
          draft: draft,
          original: original,
          originalOccurrenceStartAt: selectedOccurrence,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final screen = tester.widget<EventEditScreen>(
      find.byType(EventEditScreen),
    );
    // 요청(draft) 이동 회차 정보는 유실되지 않는다.
    expect(screen.eventId, 'occurrence-dto-1');
    expect(screen.event, isNotNull);
    expect(screen.event!.id, 'occurrence-dto-1');
    expect(screen.event!.startAt, movedStart);
    expect(screen.event!.parentEventId, 'series-dto-1');
    expect(screen.event!.overriddenOccurrenceDate, selectedOccurrence);

    // source는 반복 base(1일)이고, 선택된 이전 회차(15일)는 payload 값 그대로
    // 전달된다. base 날짜나 draft 날짜(22일)로 대체되지 않는다.
    expect(screen.originalEvent, isNotNull);
    expect(screen.originalEvent!.id, 'series-dto-1');
    expect(screen.originalEvent!.startAt, baseStart);
    expect(screen.originalEvent!.recurrenceRule, 'RRULE:FREQ=WEEKLY');
    expect(screen.originalOccurrenceStartAt, selectedOccurrence);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    // 표시 날짜는 이동 후(요청) 22일이며, base 1일/이전 회차 15일 칩은 없다.
    expect(editor.startAt, planflowLocal(movedStart));
    expect(find.text(dateLabel(planflowLocal(movedStart))), findsWidgets);
    expect(
      find.text(dateLabel(planflowLocal(selectedOccurrence))),
      findsNothing,
    );
    expect(find.text(dateLabel(planflowLocal(baseStart))), findsNothing);
  });
}
