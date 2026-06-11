import 'package:flutter/foundation.dart';
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
import '../screens/settings/settings_screen.dart';
import '../screens/splash/splash_screen.dart';
import '../features/groups/screens/group_create_screen.dart';
import '../features/groups/screens/group_invite_screen.dart';
import '../features/groups/screens/group_list_screen.dart';
import '../screens/voice/confirm_screen.dart';
import '../screens/voice/voice_action_screen.dart';
import '../screens/voice/voice_conversation_screen.dart';
import '../screens/voice/voice_input_screen.dart';
import '../screens/shell_screen.dart';
import 'constants.dart';
import 'env.dart';
import '../providers/auth_provider.dart';
import 'startup_route_gate.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.root,
  overridePlatformDefaultLocation: true,
  refreshListenable: Listenable.merge(<Listenable>[
    authProvider,
    startupRouteGate,
  ]),
  redirect: (context, state) {
    final path = state.uri.path;
    final isAuthPath =
        path == AppRoutes.login || path == AppRoutes.resetPassword;

    if (path == AppRoutes.root) {
      if (startupRouteGate.suppressLoginRedirects) {
        return null;
      }
      if (!authProvider.hasResolvedInitialSession) {
        return null;
      }
      if (!authProvider.isSignedIn) {
        // 세션 갱신 중이거나 토큰만 만료된 경우: 스플래시에서 대기
        // hasAttemptedStartupSync=false: 첫 syncCurrentSession() 전 → 아직 복구 기회가 남음
        if (authProvider.sessionStatus == AuthSessionStatus.recovering ||
            !authProvider.hasAttemptedStartupSync ||
            (authProvider.sessionStatus == AuthSessionStatus.reauthRequired &&
                authProvider.hasAccountSnapshot)) {
          return null;
        }
        return AppRoutes.login;
      }
      return AppRoutes.home;
    }

    if (!AppEnv.isSupabaseReady) {
      return isAuthPath ? null : AppRoutes.login;
    }

    if (startupRouteGate.suppressLoginRedirects && !isAuthPath) {
      return null;
    }

    if (!authProvider.hasResolvedInitialSession && !isAuthPath) {
      return AppRoutes.root;
    }

    if (authProvider.isPasswordRecovery && path != AppRoutes.resetPassword) {
      return AppRoutes.resetPassword;
    }

    if (!authProvider.isSignedIn && !isAuthPath) {
      // recovering: 세션 복구 중 → 대기
      // reauthRequired + hasAccountSnapshot: 이전 로그인 계정 있음, 토큰만 만료
      //   → 로그인 화면 강제 전환 금지. 앱 내 배너로 안내.
      // hasAttemptedStartupSync=false: 아직 첫 sync 전 → 복구 기회 남음
      if (authProvider.sessionStatus == AuthSessionStatus.recovering ||
          !authProvider.hasAttemptedStartupSync ||
          (authProvider.sessionStatus == AuthSessionStatus.reauthRequired &&
              authProvider.hasAccountSnapshot)) {
        return null;
      }
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
        key: ValueKey<String>('calendar-${state.uri.query}'),
        initialIndex: 1,
        initialCalendarDate: _parseRouteDate(
          state.uri.queryParameters['date'],
        ),
      ),
    ),
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => ShellScreen(
        initialIndex: 2,
        initialSettingsAction: _parseSettingsInitialAction(state),
      ),
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
      builder: (context, state) {
        final extra = state.extra is Map<String, dynamic>
            ? state.extra! as Map<String, dynamic>
            : const <String, dynamic>{};
        return VoiceConversationScreen(
          autoStart: _isAutoStart(state),
          initialText: extra['initial_text']?.toString(),
        );
      },
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
          showDeparturePrompt:
              state.uri.queryParameters['departureAction'] == 'prompt',
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
          showDeparturePrompt:
              state.uri.queryParameters['departureAction'] == 'prompt',
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
          initialDate: _parseRouteDate(state.uri.queryParameters['date']),
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
    GoRoute(
      path: AppRoutes.groups,
      builder: (context, state) => const GroupListScreen(),
    ),
    GoRoute(
      path: AppRoutes.groupCreate,
      builder: (context, state) => const GroupCreateScreen(),
    ),
    GoRoute(
      path: AppRoutes.groupInvites,
      builder: (context, state) => const GroupInviteScreen(),
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

SettingsInitialAction? _parseSettingsInitialAction(GoRouterState state) {
  switch (state.uri.queryParameters['open']) {
    case 'calendar-sync':
      return SettingsInitialAction.calendarSync;
    case 'naver-caldav':
      return SettingsInitialAction.naverCalDav;
  }
  return null;
}

DateTime? _parseRouteDate(String? raw) {
  final normalized = raw?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return DateTime.tryParse(normalized);
}
