import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/env.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/settings_repository.dart';
import '../providers/auth_provider.dart';
import '../services/app_permission_service.dart';
import '../services/auth_service.dart';
import '../services/briefing_scheduler_service.dart';
import '../services/calendar_auto_sync_service.dart';
import '../services/departure_alarm_service.dart';
import '../services/naver_calendar_permission_service.dart';
import 'calendar/calendar_screen.dart';
import 'home_screen.dart';
import 'settings/settings_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with WidgetsBindingObserver {
  late int _currentIndex;
  late final ScrollController _homeScrollController;
  final AppPermissionService _permissionService = AppPermissionService();
  final NaverCalendarPermissionService _naverCalendarPermissionService =
      NaverCalendarPermissionService();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  final DepartureAlarmService _departureAlarmService =
      const DepartureAlarmService();
  final BriefingSchedulerService _briefingSchedulerService =
      BriefingSchedulerService();
  final AuthService _authService = AuthService();
  bool _checkedPermissionOnboarding = false;
  bool _checkedNaverCalendarPermission = false;
  bool _showedNaverCalendarDialog = false;
  String? _observedUserId;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _homeScrollController = ScrollController(keepScrollOffset: false);
    _observedUserId = authProvider.userId;
    WidgetsBinding.instance.addObserver(this);
    authProvider.addListener(_handleAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenPermissionOnboarding();
      unawaited(_calendarAutoSyncService.syncConnectedCalendars(
        reason: 'app_start',
      ));
      unawaited(_departureAlarmService.refreshUpcoming());
      unawaited(_departureAlarmService.scheduleNextMonitor());
      unawaited(_ensureBriefingsScheduled(reason: 'app_start'));
    });
  }

  @override
  void dispose() {
    authProvider.removeListener(_handleAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _homeScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(_calendarAutoSyncService.syncConnectedCalendars(
        reason: 'app_resumed',
      ));
      unawaited(_departureAlarmService.refreshUpcoming());
    }
  }

  void _handleAuthChanged() {
    final currentUserId = authProvider.userId;
    if (_observedUserId == currentUserId) {
      return;
    }

    _observedUserId = currentUserId;
    _checkedPermissionOnboarding = false;
    _checkedNaverCalendarPermission = false;
    _showedNaverCalendarDialog = false;

    if (!mounted) {
      return;
    }

    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _maybeOpenPermissionOnboarding();
        unawaited(_calendarAutoSyncService.syncConnectedCalendars(
          reason: 'auth_changed',
          force: true,
        ));
        unawaited(_departureAlarmService.refreshUpcoming());
        unawaited(_departureAlarmService.scheduleNextMonitor());
        unawaited(_ensureBriefingsScheduled(reason: 'auth_changed'));
      }
    });
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialIndex != widget.initialIndex &&
        _currentIndex != widget.initialIndex) {
      setState(() {
        _currentIndex = widget.initialIndex;
      });
    }
  }

  void _showHomeAtTop() {
    if (!_homeScrollController.hasClients) {
      return;
    }

    _homeScrollController.jumpTo(0);
  }

  void _goToTab(int index) {
    if (index == _currentIndex) {
      return;
    }
    setState(() {
      _currentIndex = index;
    });
    switch (index) {
      case 0:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showHomeAtTop();
          }
        });
        context.go(AppRoutes.home);
        break;
      case 1:
        context.go(AppRoutes.calendar);
        break;
      case 2:
        context.go(AppRoutes.settings);
        break;
    }
  }

  void _handleTabSwipe(DragEndDetails details) {
    final velocityX = details.primaryVelocity ?? 0;
    if (velocityX.abs() < 250) {
      return;
    }
    if (velocityX < 0) {
      _goToTab((_currentIndex + 1).clamp(0, 2));
    } else {
      _goToTab((_currentIndex - 1).clamp(0, 2));
    }
  }

  Future<void> _maybeOpenPermissionOnboarding() async {
    if (_checkedPermissionOnboarding || !mounted) {
      return;
    }
    _checkedPermissionOnboarding = true;

    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final completed = await _permissionService.isOnboardingCompleted(userId);
    if (!mounted) {
      return;
    }

    if (!completed) {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return;
      }
      if (snapshot.requiredPermissionsGranted) {
        await _permissionService.markOnboardingCompleted(userId);
      } else {
        await context.push(AppRoutes.permissionOnboarding);
      }
    }

    if (mounted) {
      await _maybeCheckNaverCalendarPermission();
    }
  }

  Future<void> _maybeCheckNaverCalendarPermission() async {
    if (_checkedNaverCalendarPermission ||
        !mounted ||
        !_naverCalendarPermissionService.isNaverSignedIn()) {
      return;
    }
    _checkedNaverCalendarPermission = true;

    final result = await _naverCalendarPermissionService.refreshStatus();
    if (!mounted) {
      return;
    }

    switch (result.status) {
      case NaverCalendarPermissionStatus.granted:
        return;
      case NaverCalendarPermissionStatus.denied:
        await _showNaverCalendarPermissionRequiredDialog(result.message);
        return;
      case NaverCalendarPermissionStatus.networkError:
        _logNaverCalendarStatus(
          result,
          fallback: '네이버 캘린더 연결 확인 중 일시적인 문제가 발생했습니다.',
        );
        return;
      case NaverCalendarPermissionStatus.unknown:
        if (result.message.contains('토큰')) {
          await _showNaverCalendarPermissionRequiredDialog(
            '네이버 캘린더 연결을 완료하려면 네이버 권한 동의가 한 번 더 필요합니다.',
          );
          return;
        }
        _logNaverCalendarStatus(result);
        return;
    }
  }

  Future<void> _showNaverCalendarPermissionRequiredDialog(
    String reason,
  ) async {
    if (_showedNaverCalendarDialog || !mounted) {
      return;
    }
    _showedNaverCalendarDialog = true;

    final reconnect = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('네이버 캘린더 연결이 필요합니다'),
          content: Text(
            '$reason\n\n'
            '네이버 동의 화면에서 선택 권한인 캘린더 일정담기를 체크해야 '
            'PlanFlow 일정을 네이버 캘린더에 보낼 수 있습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('나중에 하기'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('네이버 권한 다시 동의하기'),
            ),
          ],
        );
      },
    );

    if (reconnect == true) {
      await _naverCalendarPermissionService.clearStatus();
      if (!mounted) {
        return;
      }
      _showSnack('네이버 동의 화면에서 캘린더 일정담기를 체크해 주세요.');
      await _authService.reconnectNaverCalendar();
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _ensureBriefingsScheduled({required String reason}) async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      debugPrint('Briefing schedule skipped ($reason): signed out');
      return;
    }

    try {
      final settings = await _loadBriefingSettings(userId);
      final result = await _briefingSchedulerService.scheduleDaily(
        morningTime: settings.morningBriefingAt,
        eveningTime: settings.eveningBriefingAt,
        userId: userId,
      );
      debugPrint(
        'Briefing schedule ensured ($reason): '
        'morning=${result.morning.scheduledAt.toIso8601String()} '
        'scheduled=${result.morning.scheduled}, '
        'evening=${result.evening.scheduledAt.toIso8601String()} '
        'scheduled=${result.evening.scheduled}, userId=$userId',
      );
    } catch (error, stackTrace) {
      debugPrint('Briefing schedule setup skipped ($reason): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<UserSettingsModel> _loadBriefingSettings(String userId) async {
    if (!AppEnv.isSupabaseReady) {
      return UserSettingsModel.defaults(userId: userId);
    }

    try {
      final repository = SettingsRepository.supabase();
      return await repository.fetchSettings(userId) ??
          UserSettingsModel.defaults(userId: userId);
    } catch (error, stackTrace) {
      debugPrint('Briefing settings load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return UserSettingsModel.defaults(userId: userId);
    }
  }

  void _logNaverCalendarStatus(
    NaverCalendarPermissionResult result, {
    String? fallback,
  }) {
    debugPrint(
      'Naver calendar connection skipped: status=${result.status.name} '
      'message=${fallback ?? result.message}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_currentIndex != 0) {
          setState(() {
            _currentIndex = 0;
          });
          context.go(AppRoutes.home);
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _handleTabSwipe,
          child: IndexedStack(
            index: _currentIndex,
            children: [
              HomeScreen(scrollController: _homeScrollController),
              const CalendarScreen(),
              SettingsScreen(
                key: ValueKey<String?>('settings-${authProvider.userId}'),
                userId: authProvider.userId,
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _goToTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '홈',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note),
              label: '일정',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '설정',
            ),
          ],
        ),
      ),
    );
  }
}
