import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/onboarding/permission_onboarding_screen.dart';
import '../screens/auth/reset_password_screen.dart';
import '../data/models/event_model.dart';
import '../screens/briefing/briefing_launch_screen.dart';
import '../screens/event/event_detail_screen.dart';
import '../screens/event/event_edit_screen.dart';
import '../screens/placeholder_screen.dart';
import '../screens/settings/naver_ics_import_screen.dart';
import '../screens/splash/splash_screen.dart';
import '../screens/voice/confirm_screen.dart';
import '../screens/voice/voice_action_screen.dart';
import '../screens/voice/voice_input_screen.dart';
import '../screens/shell_screen.dart';
import 'constants.dart';
import 'env.dart';
import '../providers/auth_provider.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.root,
  refreshListenable: authProvider,
  redirect: (context, state) {
    final path = state.uri.path;
    final isAuthPath =
        path == AppRoutes.login || path == AppRoutes.resetPassword;

    if (path == AppRoutes.root) {
      if (!authProvider.hasResolvedInitialSession) {
        return null;
      }
      return authProvider.isSignedIn ? AppRoutes.home : AppRoutes.login;
    }

    if (!AppEnv.isSupabaseReady) {
      return isAuthPath ? null : AppRoutes.login;
    }

    if (!authProvider.hasResolvedInitialSession && !isAuthPath) {
      return AppRoutes.root;
    }

    if (authProvider.isPasswordRecovery && path != AppRoutes.resetPassword) {
      return AppRoutes.resetPassword;
    }

    if (!authProvider.isSignedIn && !isAuthPath) {
      return AppRoutes.login;
    }

    if (authProvider.isSignedIn &&
        path == AppRoutes.login &&
        !authProvider.isPasswordRecovery) {
      return AppRoutes.home;
    }

    return null;
  },
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
      path: AppRoutes.permissionOnboarding,
      builder: (context, state) => const PermissionOnboardingScreen(),
    ),
    GoRoute(
      path: AppRoutes.resetPassword,
      builder: (context, state) => const ResetPasswordScreen(),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const ShellScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.calendar,
      builder: (context, state) => ShellScreen(
        initialIndex: 1,
        initialCalendarDate: _parseRouteDate(
          state.uri.queryParameters['date'],
        ),
      ),
    ),
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const ShellScreen(initialIndex: 2),
    ),
    GoRoute(
      path: AppRoutes.briefing,
      builder: (context, state) {
        final type = state.uri.queryParameters['type'] ?? 'morning';
        return BriefingLaunchScreen(isMorning: type != 'evening');
      },
    ),
    GoRoute(
      path: AppRoutes.naverIcsImport,
      builder: (context, state) {
        final paths = state.extra is List
            ? (state.extra! as List)
                .map((item) => item.toString())
                .where((path) => path.trim().isNotEmpty)
                .toList(growable: false)
            : const <String>[];
        return NaverIcsImportScreen(initialPaths: paths);
      },
    ),
    GoRoute(
      path: AppRoutes.voice,
      builder: (context, state) => VoiceInputScreen(
        autoStartOverride: _isAutoStart(state) ? true : null,
      ),
    ),
    GoRoute(
      path: AppRoutes.voiceLauncher,
      redirect: (context, state) => '${AppRoutes.voice}?autoStart=1',
    ),
    GoRoute(
      path: AppRoutes.voiceConversation,
      redirect: (context, state) => '${AppRoutes.voice}?autoStart=1',
    ),
    GoRoute(
      path: AppRoutes.voiceAction,
      builder: (context, state) {
        final extra = state.extra is Map<String, dynamic>
            ? state.extra! as Map<String, dynamic>
            : const <String, dynamic>{};
        final actionText = extra['action']?.toString() ?? 'edit';
        final action = VoiceScheduleAction.values.firstWhere(
          (candidate) => candidate.name == actionText,
          orElse: () => VoiceScheduleAction.choose,
        );
        final rawText = extra['raw_text']?.toString() ?? '';
        return VoiceActionScreen(
          key: ValueKey(
            'voice-action-${action.name}-${rawText.hashCode}',
          ),
          rawText: rawText,
          action: action,
        );
      },
    ),
    GoRoute(
      path: AppRoutes.confirm,
      builder: (context, state) {
        final parsedSchedule = state.extra is Map<String, dynamic>
            ? state.extra! as Map<String, dynamic>
            : const <String, dynamic>{};
        return ConfirmScreen(parsedSchedule: parsedSchedule);
      },
    ),
    GoRoute(
      path: AppRoutes.eventDetail,
      builder: (context, state) {
        final event =
            state.extra is EventModel ? state.extra! as EventModel : null;
        return EventDetailScreen(
          event: event,
          eventId: _resolveEventId(state, event),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.eventDetailWithId,
      builder: (context, state) {
        final event =
            state.extra is EventModel ? state.extra! as EventModel : null;
        return EventDetailScreen(
          event: event,
          eventId: _resolveEventId(state, event),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.eventEdit,
      builder: (context, state) {
        final event =
            state.extra is EventModel ? state.extra! as EventModel : null;
        return EventEditScreen(
          event: event,
          eventId: _resolveEventId(state, event),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.eventEditWithId,
      builder: (context, state) {
        final event =
            state.extra is EventModel ? state.extra! as EventModel : null;
        return EventEditScreen(
          event: event,
          eventId: _resolveEventId(state, event),
        );
      },
    ),
  ],
  errorBuilder: (context, state) => const PlaceholderScreen(
    title: '화면을 찾을 수 없어요',
    message: '요청한 화면 경로를 찾지 못했습니다.',
  ),
);

String? _resolveEventId(GoRouterState state, EventModel? event) {
  final pathId = state.pathParameters['eventId']?.trim();
  if (pathId != null && pathId.isNotEmpty) {
    return pathId;
  }

  final queryId = state.uri.queryParameters['eventId']?.trim();
  if (queryId != null && queryId.isNotEmpty) {
    return queryId;
  }

  final querySnakeId = state.uri.queryParameters['event_id']?.trim();
  if (querySnakeId != null && querySnakeId.isNotEmpty) {
    return querySnakeId;
  }

  final extraId = event?.id.trim();
  if (extraId != null && extraId.isNotEmpty) {
    return extraId;
  }

  return null;
}

bool _isAutoStart(GoRouterState state) {
  final value = state.uri.queryParameters['autoStart'] ??
      state.uri.queryParameters['autostart'];
  return value == '1' || value == 'true';
}

DateTime? _parseRouteDate(String? raw) {
  final normalized = raw?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return DateTime.tryParse(normalized);
}
