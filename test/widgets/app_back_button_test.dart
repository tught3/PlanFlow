import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/widgets/app_back_button.dart';

void main() {
  group('resolveBackFallbackPath', () {
    test('direct group detail returns the group list', () {
      expect(
        resolveBackFallbackPath(Uri.parse('/groups/group-123')),
        AppRoutes.groups,
      );
    });

    test('group child returns its group detail', () {
      expect(
        resolveBackFallbackPath(Uri.parse('/groups/group-123/members')),
        AppRoutes.groupDetailForId('group-123'),
      );
    });

    test('static group route returns the group list', () {
      expect(
        resolveBackFallbackPath(Uri.parse(AppRoutes.groupMembers)),
        AppRoutes.groups,
      );
    });

    test('non-group deep link returns home', () {
      expect(
        resolveBackFallbackPath(Uri.parse(AppRoutes.settings)),
        AppRoutes.home,
      );
    });
  });

  testWidgets('direct group detail falls back to the group list',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/groups/group-123',
      routes: <RouteBase>[
        GoRoute(
          path: '/groups',
          builder: (context, state) => const Text('group-list'),
        ),
        GoRoute(
          path: '/groups/:groupId',
          builder: (context, state) => const AppBackButton(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('app-back-button')));
    await tester.pumpAndSettle();

    expect(find.text('group-list'), findsOneWidget);
  });

  testWidgets('direct group child falls back to its group detail',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/groups/group-123/members',
      routes: <RouteBase>[
        GoRoute(
          path: '/groups',
          builder: (context, state) => const Text('group-list'),
        ),
        GoRoute(
          path: '/groups/:groupId',
          builder: (context, state) => const Text('group-detail'),
        ),
        GoRoute(
          path: '/groups/:groupId/members',
          builder: (context, state) => const AppBackButton(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('app-back-button')));
    await tester.pumpAndSettle();

    expect(find.text('group-detail'), findsOneWidget);
  });

  testWidgets('normal push stack pops to the group list', (tester) async {
    final router = GoRouter(
      initialLocation: '/groups',
      routes: <RouteBase>[
        GoRoute(
          path: '/groups',
          builder: (context, state) => TextButton(
            onPressed: () => context.push('/groups/group-123'),
            child: const Text('open-group'),
          ),
        ),
        GoRoute(
          path: '/groups/:groupId',
          builder: (context, state) => const AppBackButton(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-group'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('app-back-button')));
    await tester.pumpAndSettle();

    expect(find.text('open-group'), findsOneWidget);
  });
}
