import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/korean_holidays.dart';

import '_harness/app_harness.dart';
import '_harness/seed/fixture_events.dart';

/// PlanFlow iOS Simulator E2E Phase P4 — FLOW2: Schedule CRUD.
///
/// **설계 결정(왜 `pumpPlanFlowApp`을 쓰지 않는가)**: `EventDetailScreen`/
/// `EventEditScreen`은 진입 즉시 `AppEnv.isSupabaseReady`로 게이트된
/// 네트워크 조회를 시도한다(`_loadLatestEvent`/`_loadEventIfNeeded`/
/// `_loadGroupContextIfNeeded`, 전부 소스 확인함). `pumpPlanFlowApp`으로
/// 전체 앱을 부팅하면 (1) 전역 `appRouter`의 `redirect`가 미인증 상태에서
/// 보호된 경로(`/event/detail` 등)로의 이동을 전부 `/login`으로 되돌리고
/// (2) `authProvider`에 세션을 주입할 DI 지점이 없다(FLOW1 스킵 사유 참고)
/// — 따라서 전체 부팅 경로로는 이 화면들에 도달할 방법이 없다.
///
/// 대신 이 파일은 `Supabase.initialize()`를 전혀 호출하지 않는다(=
/// `AppEnv.isSupabaseReady`가 항상 false로 유지된다 — 각 테스트 파일은
/// 별도 프로세스라 다른 파일의 상태와 섞이지 않는다). 그 결과 위 네트워크
/// 게이트가 전부 조기 반환하므로, 두 화면을 **자체 로컬 `GoRouter`**에
/// 얹어 실제 프로덕션 라우팅 경로(`context.push`/`context.pop`, extra 전달)
/// 그대로 구동할 수 있다 — fake repository 없이도 순수하게 안전하다.
///
/// Windows 로컬 환경에는 iOS 시뮬레이터가 없어 이 파일은 `dart analyze`로만
/// 검증됐다. 실제 실행·통과 여부는 CI(P8, macOS 러너)에서 확인한다.
void main() {
  ensureIntegrationTestBinding();

  group('FLOW2 schedule CRUD', () {
    testWidgets('단순 일정 상세 화면이 제목과 일반 상태를 렌더한다', (tester) async {
      final event = FixtureEvents.simple();
      final router = _scheduleRouter(
        initialLocation: AppRoutes.eventDetail,
        initialExtra: event,
      );
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      expect(find.text(event.title), findsOneWidget);
      expect(find.text('일반 일정'), findsOneWidget);
      expect(find.text('일정 편집'), findsOneWidget);
    });

    testWidgets('중요 일정은 상세 화면에 "중요 일정" 상태로 표시된다', (tester) async {
      final event = FixtureEvents.critical();
      final router = _scheduleRouter(
        initialLocation: AppRoutes.eventDetail,
        initialExtra: event,
      );
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      expect(find.text('중요 일정'), findsOneWidget);
    });

    testWidgets(
      '반복 일정은 RRULE 데이터를 유지하며 상세 화면이 정상 렌더된다 '
      '(반복 표시 UI 자체는 EventDetailScreen에 없음 — 아래 주석 참고)',
      (tester) async {
        final event = FixtureEvents.recurringWeekly();
        // 데이터 계약 확인: 픽스처가 실제로 매주 반복 RRULE을 갖는다.
        expect(event.recurrenceRule, isNotNull);
        expect(event.recurrenceRule, startsWith('FREQ=WEEKLY;BYDAY='));

        final router = _scheduleRouter(
          initialLocation: AppRoutes.eventDetail,
          initialExtra: event,
        );
        await tester.pumpWidget(_wrap(router));
        await tester.pumpAndSettle();

        // lib/screens/event/event_detail_screen.dart 전문을 확인한 결과
        // recurrenceRule을 화면에 표시하는 위젯이 없다(제목/시간/중요
        // 상태/등록일/메모만 렌더). 그래서 여기서는 "반복 일정을 열어도
        // 화면이 깨지지 않는다"만 실측하고, 반복 표시 자체는 검증
        // 대상에서 제외한다 — 완료 보고에 이 한계를 남긴다.
        expect(find.text(event.title), findsOneWidget);
      },
    );

    testWidgets(
      '공휴일 인접 일정의 날짜는 KoreanHolidays 기준 실제 공휴일이며 상세 화면이 정상 렌더된다 '
      '(월간 캘린더 그리드의 공휴일 강조 UI는 별도 스크린이라 범위 밖)',
      (tester) async {
        final event = FixtureEvents.nearHoliday();
        // 데이터 계약 확인: 픽스처의 시작일이 실제로 KoreanHolidays 기준
        // 공휴일이다(FixtureEvents.nearHoliday() 생성 시 이미 assert로도
        // 보증되지만, 릴리즈 빌드에서 assert가 꺼질 수 있으므로 여기서
        // 다시 명시적으로 확인한다).
        expect(KoreanHolidays.isHoliday(event.startAt!), isTrue);

        final router = _scheduleRouter(
          initialLocation: AppRoutes.eventDetail,
          initialExtra: event,
        );
        await tester.pumpWidget(_wrap(router));
        await tester.pumpAndSettle();

        // 공휴일 강조 표시는 lib/screens/calendar/calendar_screen.dart의
        // 월간 그리드 셀 렌더링에만 존재한다(grep 확인). 그 화면은
        // EventPrefetchService/실 Supabase 조회에 강하게 결합돼 있고
        // repository 주입 seam이 없어(2026-09-03 확인) 네트워크 없이
        // 안전하게 구동할 수 없다 — 이번 P4 범위에서는 상세 화면 렌더 +
        // 날짜의 공휴일 여부(데이터 계약)까지만 검증한다.
        expect(find.text(event.title), findsOneWidget);
      },
    );

    testWidgets('extra 없이 편집 화면을 열면 "일정 만들기" 제목이 뜬다(생성 모드)', (
      tester,
    ) async {
      final router = _scheduleRouter(initialLocation: AppRoutes.eventEdit);
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      expect(find.text('일정 만들기'), findsOneWidget);
      expect(find.text('저장'), findsOneWidget);
    });

    testWidgets('기존 일정 extra로 편집 화면을 열면 "일정 편집" 제목이 뜬다(수정 모드)', (
      tester,
    ) async {
      final event = FixtureEvents.simple();
      final router = _scheduleRouter(
        initialLocation: '${AppRoutes.eventEdit}/${event.id}',
        initialExtra: event,
      );
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      expect(find.text('일정 편집'), findsOneWidget);
    });

    testWidgets('상세 화면의 "일정 편집" 버튼이 실제 push/pop 내비게이션으로 편집 화면을 오간다', (
      tester,
    ) async {
      final event = FixtureEvents.simple();
      final router = _scheduleRouter(
        initialLocation: AppRoutes.eventDetail,
        initialExtra: event,
      );
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      // 편집 화면 전용 위젯(저장 버튼)이 push 전에는 없어야 한다.
      expect(find.text('저장'), findsNothing);

      await tester.tap(find.text('일정 편집'));
      await tester.pumpAndSettle();
      expect(find.text('저장'), findsOneWidget);

      // 뒤로가기는 GoRouter.pop()을 직접 호출한다 — push된 상태에서는
      // 상세 화면의 BackButton이 push 이전 위젯 트리에도 여전히 남아있어
      // (Navigator 스택이 두 화면을 모두 유지) find.byType(BackButton)이
      // 항상 2개를 반환해 탭 대상이 모호해진다. router.pop()은 실제
      // EventEditScreen의 BackButton이 호출하는 것과 동일한
      // GoRouter.pop() 경로라 내비게이션 계약은 동일하게 검증된다.
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('저장'), findsNothing);
      expect(find.text(event.title), findsOneWidget);
    });

    testWidgets('상세 화면에서 삭제를 취소하면 화면에 그대로 남는다', (tester) async {
      final event = FixtureEvents.simple();
      final router = _scheduleRouter(
        initialLocation: AppRoutes.eventDetail,
        initialExtra: event,
      );
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle();

      await tester.tap(find.text('일정 삭제').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('일정을 삭제할까요?'), findsOneWidget);

      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.textContaining('일정을 삭제할까요?'), findsNothing);
      expect(find.text(event.title), findsOneWidget);
    });

    testWidgets(
      '상세 화면에서 삭제를 확정하면 성공 스낵바가 뜨고 캘린더 자리표시 화면으로 이동한다 '
      '(AppEnv.isSupabaseReady=false라 실제 repository.deleteEvent 호출은 스킵됨 — 소스로 확인)',
      (tester) async {
        final event = FixtureEvents.simple();
        final router = _scheduleRouter(
          initialLocation: AppRoutes.eventDetail,
          initialExtra: event,
        );
        await tester.pumpWidget(_wrap(router));
        await tester.pumpAndSettle();

        await tester.tap(find.text('일정 삭제').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('삭제'));
        await tester.pumpAndSettle();

        expect(find.text('일정을 삭제했습니다.'), findsOneWidget);
        expect(find.text('E2E calendar placeholder'), findsOneWidget);
      },
    );
  });
}

/// FLOW2 전용 로컬 라우터. 프로덕션 `lib/core/router.dart`의 관련 경로
/// 상수(`AppRoutes.eventDetail(WithId)`/`eventEdit(WithId)`/`calendar`)를
/// 그대로 재사용해 실제 `context.push`/`context.pop` 호출이 향하는 경로와
/// 일치시킨다. `redirect`는 두지 않는다 — 인증 게이트를 재현하는 것이 이
/// 스위트의 목적이 아니라, 인증과 무관하게 항상 도달 가능해야 하는 CRUD
/// 화면 자체를 검증하는 것이 목적이다.
GoRouter _scheduleRouter({required String initialLocation, Object? initialExtra}) {
  return GoRouter(
    initialLocation: initialLocation,
    initialExtra: initialExtra,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.eventDetail,
        builder: (context, state) => EventDetailScreen(
          event: state.extra is EventModel ? state.extra! as EventModel : null,
        ),
      ),
      GoRoute(
        path: AppRoutes.eventDetailWithId,
        builder: (context, state) => EventDetailScreen(
          event: state.extra is EventModel ? state.extra! as EventModel : null,
          eventId: state.pathParameters['eventId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.eventEdit,
        builder: (context, state) => EventEditScreen(
          event: state.extra is EventModel ? state.extra! as EventModel : null,
        ),
      ),
      GoRoute(
        path: AppRoutes.eventEditWithId,
        builder: (context, state) => EventEditScreen(
          event: state.extra is EventModel ? state.extra! as EventModel : null,
          eventId: state.pathParameters['eventId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.calendar,
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('E2E calendar placeholder')),
        ),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('E2E home placeholder')),
        ),
      ),
    ],
  );
}

Widget _wrap(GoRouter router) {
  return MaterialApp.router(
    routerConfig: router,
    locale: const Locale('ko', 'KR'),
    supportedLocales: const <Locale>[Locale('ko', 'KR'), Locale('en', 'US')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
  );
}
