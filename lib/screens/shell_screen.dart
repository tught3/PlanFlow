import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/env.dart';
import '../core/responsive.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/settings_repository.dart';
import '../providers/auth_provider.dart';
import '../services/app_permission_service.dart';
import '../services/briefing_scheduler_service.dart';
import '../services/calendar_auto_sync_service.dart';
import '../services/critical_alarm_channel_migration_service.dart';
import '../services/departure_alarm_service.dart';
import '../services/external_calendar_sync_guide_service.dart';
import '../l10n/app_l10n.dart';
import 'calendar/calendar_screen.dart';
import 'home_screen.dart';
import 'settings/settings_screen.dart';

const _shellDestinations = <_ShellDestination>[
  _ShellDestination(
    label: '홈',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  _ShellDestination(
    label: '일정',
    icon: Icons.event_note_outlined,
    selectedIcon: Icons.event_note,
  ),
  _ShellDestination(
    label: '설정',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

class _ShellDestination {
  const _ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class ShellScreen extends StatefulWidget {
  const ShellScreen({
    super.key,
    this.initialIndex = 0,
    this.initialCalendarDate,
    this.initialSettingsAction,
  });

  final int initialIndex;
  final DateTime? initialCalendarDate;
  final SettingsInitialAction? initialSettingsAction;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with WidgetsBindingObserver {
  late int _currentIndex;
  late final ScrollController _homeScrollController;
  final AppPermissionService _permissionService = AppPermissionService();
  final CalendarAutoSyncService _calendarAutoSyncService =
      CalendarAutoSyncService();
  late final ExternalCalendarSyncGuideService _externalCalendarGuideService =
      ExternalCalendarSyncGuideService(
    calendarAutoSyncService: _calendarAutoSyncService,
  );
  final DepartureAlarmService _departureAlarmService =
      const DepartureAlarmService();
  final CriticalAlarmChannelMigrationService _criticalAlarmMigrationService =
      const CriticalAlarmChannelMigrationService();
  final BriefingSchedulerService _briefingSchedulerService =
      BriefingSchedulerService();
  bool _checkedPermissionOnboarding = false;
  bool _checkedExternalCalendarGuide = false;
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
      unawaited(_migrateFutureCriticalAlarms());
      unawaited(_refreshDepartureAlarmsAndMonitor());
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
      unawaited(_refreshDepartureAlarmsAndMonitor());
    }
  }

  void _handleAuthChanged() {
    final currentUserId = authProvider.userId;
    if (_observedUserId == currentUserId) {
      return;
    }

    _observedUserId = currentUserId;
    _checkedPermissionOnboarding = false;
    _checkedExternalCalendarGuide = false;

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
        unawaited(_migrateFutureCriticalAlarms());
        unawaited(_refreshDepartureAlarmsAndMonitor());
        unawaited(_ensureBriefingsScheduled(reason: 'auth_changed'));
      }
    });
  }

  Future<void> _refreshDepartureAlarmsAndMonitor() async {
    final result = await _departureAlarmService.refreshUpcoming();
    await _departureAlarmService.scheduleNextMonitor(
      interval: result.nextMonitorInterval,
    );
  }

  Future<void> _migrateFutureCriticalAlarms() async {
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    await _criticalAlarmMigrationService.migrateFutureCriticalAlarmsIfNeeded(
      userId,
    );
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
    if (oldWidget.initialCalendarDate != widget.initialCalendarDate &&
        widget.initialCalendarDate != null &&
        _currentIndex != 1) {
      setState(() {
        _currentIndex = 1;
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
      await context.push(AppRoutes.permissionOnboarding);
    }

    if (mounted) {
      await _maybeShowExternalCalendarSyncGuide();
    }
  }

  Future<void> _maybeShowExternalCalendarSyncGuide() async {
    if (_checkedExternalCalendarGuide || !mounted) {
      return;
    }
    _checkedExternalCalendarGuide = true;

    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final shouldShow =
        await _externalCalendarGuideService.shouldShowForUser(userId);
    if (!shouldShow || !mounted) {
      return;
    }

    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('외부 캘린더 동기화 안내'),
          content: const Text(
            '기존에 다른 캘린더 프로그램(구글, 네이버, 삼성)을 쓰고 계셨다면 '
            '일정 동기화를 위해 설정탭에서 동기화를 진행해 주세요.',
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('동기화 안 함'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('동기화 설정'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );

    await _externalCalendarGuideService.markSeen(userId);
    if (!mounted) {
      return;
    }

    if (openSettings == true) {
      context.go('${AppRoutes.settings}?open=naver-caldav');
    }
  }

  List<NavigationDestination> _buildNavigationBarDestinations() {
    final labels = _localizedDestinationLabels();
    return _shellDestinations.indexed
        .map(
          (entry) => NavigationDestination(
            icon: Icon(entry.$2.icon),
            selectedIcon: Icon(entry.$2.selectedIcon),
            label: labels[entry.$1],
          ),
        )
        .toList(growable: false);
  }

  List<String> _localizedDestinationLabels() {
    final l10n = appL10n(context);
    return <String>[l10n.homeTab, l10n.calendarTab, l10n.settingsTab];
  }

  List<NavigationRailDestination> _buildNavigationRailDestinations() {
    final labels = _localizedDestinationLabels();
    return _shellDestinations.indexed
        .map(
          (entry) => NavigationRailDestination(
            icon: Icon(entry.$2.icon),
            selectedIcon: Icon(entry.$2.selectedIcon),
            label: Text(labels[entry.$1]),
          ),
        )
        .toList(growable: false);
  }

  Widget _buildShellBody() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _handleTabSwipe,
      child: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(scrollController: _homeScrollController),
          CalendarScreen(initialDate: widget.initialCalendarDate),
          SettingsScreen(
            key: ValueKey<String?>(
              'settings-${authProvider.userId}-'
              '${widget.initialSettingsAction?.name ?? 'none'}',
            ),
            userId: authProvider.userId,
            initialAction: widget.initialSettingsAction,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return NavigationBar(
      selectedIndex: _currentIndex,
      onDestinationSelected: _goToTab,
      destinations: _buildNavigationBarDestinations(),
    );
  }

  Widget _buildNavigationRail(PlanFlowResponsiveSize layoutSize) {
    final extended = layoutSize == PlanFlowResponsiveSize.expanded;

    return SafeArea(
      child: NavigationRail(
        selectedIndex: _currentIndex,
        onDestinationSelected: _goToTab,
        labelType: extended ? null : NavigationRailLabelType.selected,
        extended: extended,
        minWidth: 72,
        minExtendedWidth: 208,
        destinations: _buildNavigationRailDestinations(),
      ),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final windowInfo = PlanFlowResponsive.windowInfoOf(
            context,
            constraints: constraints,
          );
          final layoutSize = windowInfo.sizeClass;
          final useRail = windowInfo.useNavigationRail;

          return Scaffold(
            body: useRail
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildNavigationRail(layoutSize),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(child: _buildShellBody()),
                    ],
                  )
                : _buildShellBody(),
            bottomNavigationBar: useRail ? null : _buildBottomNavigationBar(),
          );
        },
      ),
    );
  }
}
