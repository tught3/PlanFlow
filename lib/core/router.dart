import 'package:go_router/go_router.dart';

import '../screens/placeholder_screen.dart';
import '../screens/shell_screen.dart';
import 'constants.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.root,
  routes: <RouteBase>[
    GoRoute(
      path: AppRoutes.root,
      builder: (context, state) => const ShellScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const ShellScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.planner,
      builder: (context, state) => const ShellScreen(initialIndex: 1),
    ),
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const ShellScreen(initialIndex: 2),
    ),
  ],
  errorBuilder: (context, state) => const PlaceholderScreen(
    title: 'Not Found',
    message: 'Requested route could not be found.',
  ),
);
