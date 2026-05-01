import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/event/event_detail_screen.dart';
import '../screens/event/event_edit_screen.dart';
import '../screens/placeholder_screen.dart';
import '../screens/splash/splash_screen.dart';
import '../screens/voice/confirm_screen.dart';
import '../screens/voice/voice_input_screen.dart';
import '../screens/shell_screen.dart';
import 'constants.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.root,
  routes: <RouteBase>[
    GoRoute(
      path: AppRoutes.root,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: AppRoutes.login,
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const ShellScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.calendar,
      builder: (context, state) => const ShellScreen(initialIndex: 1),
    ),
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const ShellScreen(initialIndex: 2),
    ),
    GoRoute(
      path: AppRoutes.voice,
      builder: (context, state) => const VoiceInputScreen(),
    ),
    GoRoute(
      path: AppRoutes.confirm,
      builder: (context, state) => const ConfirmScreen(),
    ),
    GoRoute(
      path: AppRoutes.eventDetail,
      builder: (context, state) => const EventDetailScreen(),
    ),
    GoRoute(
      path: AppRoutes.eventEdit,
      builder: (context, state) => const EventEditScreen(),
    ),
  ],
  errorBuilder: (context, state) => const PlaceholderScreen(
    title: 'Not Found',
    message: 'Requested route could not be found.',
  ),
);
