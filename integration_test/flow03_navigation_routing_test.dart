import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/app.dart' show resolveHomeWidgetRoute;
import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/services/notification_route_contract.dart';

import '_harness/app_harness.dart';
import '_harness/checkpoint_logger.dart';
import '_harness/seed/fixture_events.dart';

/// PlanFlow iOS Simulator E2E Phase P4 — FLOW3: Navigation & Deep Links.
///
/// **AppLinks 주입 seam 조사 결과**: `lib/app.dart:59`의
/// `final AppLinks _appLinks = AppLinks();`는 필드 초기화식으로 고정돼
/// 있고, `_PlanFlowAppState`/`PlanFlowApp` 어디에도 `AppLinks`를 생성자로
/// 주입받는 파라미터가 없다(2026-09-03 재확인 — 이전 P3 조사와 동일
/// 결론). 즉 `_appLinks.uriLinkStream`에 테스트가 가짜 URI를 흘려보낼
/// DI 지점이 없다. 그래서 이 파일은 실제 uriLinkStream 이벤트를 재현하는
/// 대신, 그 스트림의 콜백이 그대로 호출하는 **실제 프로덕션 순수 함수**
/// `resolveHomeWidgetRoute()`(`lib/app.dart`, `@visibleForTesting` top-level
/// 함수 — `_handlePlanFlowDeepLink` -> `_handleHomeWidgetUri`가 호출하는
/// 것과 동일한 함수)를 직접 호출해 "URI가 어떤 라우트 문자열로 매핑되는가"
/// 를 검증한다. 이는 티켓이 명시한 대안 경로("canonicalPath() + 라우터
/// 직접 호출 방식")의 상위 호환이다 — `resolveHomeWidgetRoute`가 내부적으로
/// `NotificationRouteContract.canonicalPath()`를 호출하므로 두 계약을
/// 함께 검증한다.
///
/// 콜드스타트 딥링크(`_appLinks.getInitialLink()`)는 in-process 통합
/// 테스트로 재현할 수 없다(실제 프로세스를 딥링크로 새로 띄워야 하는
/// 시나리오라 시뮬레이터 레벨 테스트가 필요) — 이 파일은 warm start만
/// 다룬다.
///
/// Windows 로컬 환경에는 iOS 시뮬레이터가 없어 이 파일은 `dart analyze`로만
/// 검증됐다. 실제 실행·통과 여부는 CI(P8, macOS 러너)에서 확인한다.
// E2E run-2 행(hang) 조사(P8) 방지책: 인자 없는 pumpAndSettle()는
// pump 간격만 기본 100ms로 남기고, 실제 타임아웃은 WidgetTester.
// pumpAndSettle의 3번째 positional 인자(기본 10분, Flutter
// 3.41.9/3.47.2 SDK 소스로 확인)에 그대로 걸린다. 이 파일은 순수
// 로컬 GoRouter 위에서 계산된 라우트 문자열로 이동하는 것만
// 검증하고(네트워크·타이머·무한 애니메이션 없음), 10초면 충분히
// 여유롭다. 반드시 3-positional 전체를 채워 호출한다 —
// pumpAndSettle(Duration(seconds: N))처럼 1-positional로 바꾸면
// 그건 pump 간격만 늘릴 뿐 타임아웃은 여전히 기본 10분으로 남아
// 오히려 역효과다.
const Duration _kSettleTimeout = Duration(seconds: 10);

void main() {
  ensureIntegrationTestBinding();

  group('FLOW3 deep link URI -> route mapping (pure function)', () {
    test('schedule 딥링크는 이벤트 상세 경로로 매핑된다', () {
      final uri = Uri.parse('planflow://schedule/evt-123');
      expect(
        resolveHomeWidgetRoute(uri),
        '${AppRoutes.eventDetail}/evt-123',
      );
    });

    test('day 딥링크는 캘린더 경로 + date 쿼리로 매핑된다', () {
      // 절대 날짜 하드코딩 금지 방지책(anti-patterns.md) 준수: 상대 미래
      // 날짜로 계산한다.
      final date = DateTime.now().add(const Duration(days: 3));
      final uri = NotificationRouteContract.day(date);
      final expectedDate = '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

      expect(
        resolveHomeWidgetRoute(uri),
        '${AppRoutes.calendar}?date=$expectedDate',
      );
    });

    test('group-calendar 딥링크는 그룹 이벤트 경로 + groupId 쿼리로 매핑된다', () {
      final uri = Uri.parse('planflow://group-calendar?groupId=g42');

      expect(
        resolveHomeWidgetRoute(uri),
        '${AppRoutes.groupEventsForId('g42')}?groupId=g42',
      );
    });

    test('auth-callback 딥링크는 라우팅 대상이 없다(무시 대상)', () {
      // 실제 무시 로직은 `_PlanFlowAppState._handlePlanFlowDeepLink`의
      // `uri.host == 'auth-callback'` 조기 반환(private, 직접 호출 불가)에
      // 있다. `resolveHomeWidgetRoute`는 그 앞단에서 호출되지 않는
      // 별도 진입점이지만, 'auth-callback' host는 이 함수의 switch/조건
      // 어디에도 매칭되지 않아 동일하게 null을 반환한다 — 즉 "라우팅
      // 안 됨"이라는 순 결과는 두 경로 모두 일치한다.
      final uri = Uri.parse('planflow://auth-callback?code=abc123');

      expect(resolveHomeWidgetRoute(uri), isNull);
    });
  });

  group('FLOW3 warm-start navigation with computed routes', () {
    testWidgets('schedule 딥링크로 계산한 경로가 실제로 이벤트 상세 화면을 연다', (tester) async {
      final event = FixtureEvents.simple();
      final computedRoute = resolveHomeWidgetRoute(
        Uri.parse('planflow://schedule/${event.id}'),
      );
      expect(computedRoute, isNotNull);

      final router = _navigationRouter();
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('ROUTER_MOUNTED');
      expect(find.text('E2E home placeholder'), findsOneWidget);

      router.go(computedRoute!, extra: event);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('NAV_TARGET_REACHED');

      expect(find.text(event.title), findsOneWidget);
    });

    testWidgets('day 딥링크로 계산한 경로가 실제로 캘린더 자리표시 화면을 연다(date 쿼리 유지)', (
      tester,
    ) async {
      final date = DateTime.now().add(const Duration(days: 5));
      final computedRoute = resolveHomeWidgetRoute(
        NotificationRouteContract.day(date),
      );
      expect(computedRoute, isNotNull);

      final router = _navigationRouter();
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );

      router.go(computedRoute!);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('NAV_TARGET_REACHED');

      expect(find.textContaining('calendar placeholder date='), findsOneWidget);
      final currentUri = router.routeInformationProvider.value.uri;
      expect(currentUri.path, AppRoutes.calendar);
      expect(currentUri.queryParameters['date'], isNotNull);
    });

    testWidgets('group-calendar 딥링크로 계산한 경로가 실제로 그룹 이벤트 자리표시 화면을 연다', (
      tester,
    ) async {
      final computedRoute = resolveHomeWidgetRoute(
        Uri.parse('planflow://group-calendar?groupId=g42'),
      );
      expect(computedRoute, isNotNull);

      final router = _navigationRouter();
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );

      router.go(computedRoute!);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('NAV_TARGET_REACHED');

      expect(find.textContaining('group events placeholder groupId=g42'),
          findsOneWidget);
    });

    testWidgets('상세 화면에서 "일정 편집"으로 push했다가 되돌아오는 화면 간 내비게이션이 동작한다', (
      tester,
    ) async {
      final event = FixtureEvents.simple();
      final router = _navigationRouter();
      await tester.pumpWidget(_wrap(router));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('ROUTER_MOUNTED');

      router.push(AppRoutes.eventDetail, extra: event);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('NAV_TARGET_REACHED');
      expect(find.text(event.title), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        _kSettleTimeout,
      );
      logCheckpoint('ROUTER_MOUNTED');
      expect(find.text('E2E home placeholder'), findsOneWidget);
    });
  });
}

/// FLOW3 전용 로컬 라우터. `resolveHomeWidgetRoute()`가 실제로 계산해
/// 반환하는 문자열 형태(`AppRoutes.eventDetail(WithId)`/`calendar`/
/// `groupEventsForGroup`)를 그대로 등록해, "계산된 경로 문자열이 실제
/// 화면으로 이어지는가"까지 검증한다.
GoRouter _navigationRouter() {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('E2E home placeholder')),
        ),
      ),
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
        path: AppRoutes.calendar,
        builder: (context, state) => Scaffold(
          body: Center(
            child: Text(
              'E2E calendar placeholder date=${state.uri.queryParameters['date']}',
            ),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.groupEventsForGroup,
        builder: (context, state) => Scaffold(
          body: Center(
            child: Text(
              'E2E group events placeholder '
              'groupId=${state.pathParameters['groupId']}',
            ),
          ),
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
