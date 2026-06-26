import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/early_bird_email_repository.dart';
import '../../services/app_permission_service.dart';
import '../../services/briefing_scheduler_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/event_prefetch_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/location_lookup_service.dart';
import '../../services/home_header_summary_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/remote_config_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../widgets/planflow_logo.dart';
import '../../widgets/planflow_voice_fab.dart';

enum _HomeLoadState {
  loading,
  ready,
  supabaseMissing,
  signedOut,
  error,
}

@visibleForTesting
String formatHomeUpcomingDateTime(DateTime value, {DateTime? now}) {
  final localNow = planflowLocal(now ?? DateTime.now());
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final targetDay = DateTime(value.year, value.month, value.day);
  final time =
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  if (targetDay == today.add(const Duration(days: 1))) {
    return '내일 $time';
  }
  if (targetDay == today.add(const Duration(days: 2))) {
    return '모레 $time';
  }

  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$month/$day $time';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.scrollController,
    this.userIdOverride,
    this.eventRepository,
    this.smartPreparationAlarmService = const SmartPreparationAlarmService(),
    this.homeWidgetService,
    this.loadHeaderSummary = true,
    this.nowProvider,
    BriefingSchedulerService? briefingSchedulerService,
  }) : _briefingSchedulerService = briefingSchedulerService;

  final ScrollController? scrollController;
  final String? userIdOverride;
  final EventRepository? eventRepository;
  final SmartPreparationAlarmService smartPreparationAlarmService;
  final HomeWidgetService? homeWidgetService;
  final bool loadHeaderSummary;
  final DateTime Function()? nowProvider;
  final BriefingSchedulerService? _briefingSchedulerService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final HomeHeaderSummaryService _headerSummaryService =
      HomeHeaderSummaryService();
  late final BriefingSchedulerService _briefingSchedulerService;
  late final HomeWidgetService _homeWidgetService;
  List<EventModel> _pastTodayEvents = const <EventModel>[];
  List<EventModel> _recentPastEvents = const <EventModel>[];
  List<EventModel> _todayEvents = const <EventModel>[];
  List<EventModel> _upcomingEvents = const <EventModel>[];
  Set<String> _smartPreparationEventIds = const <String>{};
  HomeHeaderSummary? _headerSummary;
  _HomeLoadState _loadState = _HomeLoadState.loading;
  String? _loadMessage;
  int _consecutiveFailures = 0;
  Timer? _retryTimer;
  bool _hasRenderedContent = false;
  bool _headerSummaryLoading = true;
  bool _isPlayingMorningBriefing = false;
  bool _isPlayingEveningBriefing = false;
  int _homeWidgetRefreshGeneration = 0;
  Future<void> _homeWidgetRefreshQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _briefingSchedulerService =
        widget._briefingSchedulerService ?? BriefingSchedulerService();
    _homeWidgetService = widget.homeWidgetService ?? HomeWidgetService();
    WidgetsBinding.instance.addObserver(this);
    EventRefreshBus.instance.latest.addListener(_handleEventRefresh);
    _loadTodayEvents();
    if (widget.loadHeaderSummary) {
      unawaited(_loadHomeHeaderSummary());
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _homeWidgetRefreshGeneration += 1;
    EventRefreshBus.instance.latest.removeListener(_handleEventRefresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final Duration delay;
    if (_consecutiveFailures >= 6) {
      delay = const Duration(hours: 1);
    } else if (_consecutiveFailures >= 3) {
      delay = const Duration(minutes: 10);
    } else {
      return;
    }
    _retryTimer = Timer(delay, () {
      if (mounted) _loadTodayEvents();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_cacheForegroundLocation());
      _loadTodayEvents();
      if (widget.loadHeaderSummary) {
        unawaited(_loadHomeHeaderSummary());
      }
    }
  }

  Future<void> _cacheForegroundLocation() async {
    try {
      final permissionService = AppPermissionService();
      final locationGranted = await permissionService.checkLocationPermission();
      if (!locationGranted) {
        return;
      }
      final lastKnownLocation = await permissionService.getLastKnownLocation();
      final currentLocation = lastKnownLocation == null
          ? await permissionService.getCurrentLocation()
          : null;
      final location = lastKnownLocation ?? currentLocation;
      if (location == null) {
        return;
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble(
        DepartureAlarmService.cachedOriginLatKey,
        location.latitude,
      );
      await preferences.setDouble(
        DepartureAlarmService.cachedOriginLngKey,
        location.longitude,
      );
      await preferences.setString(
        DepartureAlarmService.cachedOriginAtKey,
        DateTime.now().toIso8601String(),
      );
    } catch (error, stackTrace) {
      debugPrint('Home foreground location cache failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _handleEventRefresh() {
    final userId = Supabase.instance.client.auth.currentSession?.user.id;
    EventPrefetchService().invalidate(userId: userId);
    _loadTodayEvents();
    if (widget.loadHeaderSummary) {
      unawaited(_loadHomeHeaderSummary());
    }
  }

  Future<void> _loadHomeHeaderSummary() async {
    if (mounted) {
      setState(() {
        _headerSummaryLoading = true;
      });
    }
    try {
      final permissionService = AppPermissionService();
      final locationGranted = await permissionService.checkLocationPermission();
      GeoPoint? location;
      if (locationGranted) {
        final lastKnownLocation =
            await permissionService.getLastKnownLocation();
        if (lastKnownLocation != null && mounted) {
          final cachedSummary = await _headerSummaryService.load(
            location: lastKnownLocation,
          );
          setState(() {
            _headerSummary = cachedSummary;
            _headerSummaryLoading = false;
          });
        }
        location = await permissionService.getCurrentLocation();
        location ??= lastKnownLocation;
      }
      final summary = await _headerSummaryService.load(location: location);
      if (mounted) {
        setState(() {
          _headerSummary = summary;
          _headerSummaryLoading = false;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('Home header summary load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _headerSummary = const HomeHeaderSummary(
            weatherLabel: '날씨 확인 중',
            detailLine: '날씨를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.',
            isReady: false,
          );
          _headerSummaryLoading = false;
        });
      }
    }
  }

  Future<void> _loadTodayEvents() async {
    final shouldShowLoading = !_hasRenderedContent;

    if (!AppEnv.isSupabaseReady) {
      if (mounted) {
        setState(() {
          _clearHomeContent();
          _loadState = _HomeLoadState.supabaseMissing;
        });
      }
      return;
    }
    final resolvedUserId = _resolveUserId();
    if (resolvedUserId == null) {
      if (mounted) {
        setState(() {
          _clearHomeContent();
          _loadState = _HomeLoadState.signedOut;
        });
      }
      return;
    }

    final repository = widget.eventRepository ?? EventRepository.supabase();
    final prefetchService = EventPrefetchService();
    final cachedEvents = prefetchService.getCached(resolvedUserId);
    if (cachedEvents != null) {
      await _applyHomeEvents(
        resolvedUserId,
        cachedEvents,
        refreshHomeWidget: false,
      );
      unawaited(
        _refreshHomeEvents(
          userId: resolvedUserId,
          repository: repository,
          showLoading: false,
        ),
      );
      return;
    }

    await _refreshHomeEvents(
      userId: resolvedUserId,
      repository: repository,
      showLoading: shouldShowLoading,
    );
  }

  Future<void> _refreshHomeEvents({
    required String userId,
    required EventRepository repository,
    required bool showLoading,
  }) async {
    if (showLoading && mounted) {
      setState(() {
        _loadState = _HomeLoadState.loading;
        _loadMessage = null;
      });
    }

    try {
      final allEvents = await repository.listEvents(userId: userId);
      EventPrefetchService().store(userId, allEvents);
      await _applyHomeEvents(userId, allEvents);
      unawaited(_resolveEventsMissingCoords(allEvents, repository));
    } catch (error) {
      debugPrint('HomeScreen load failed: $error');
      if (mounted) {
        _consecutiveFailures++;
        _scheduleRetry();
      }
    } finally {
      // Loading state is replaced by one of the terminal states above.
    }
  }

  Future<void> _applyHomeEvents(
    String userId,
    List<EventModel> allEvents, {
    bool refreshHomeWidget = true,
  }) async {
    final now = widget.nowProvider?.call() ?? DateTime.now();
    final todayEvents = allEvents.where((event) {
      return _eventIntersectsDay(event, now);
    }).toList(growable: false)
      ..sort((a, b) =>
          (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)));
    final pastTodayEvents = todayEvents
        .where((event) => _isPastEvent(event, now))
        .toList(growable: false);
    final visiblePastTodayEvents = homeVisiblePastTodayEvents(pastTodayEvents);
    final recentPastEvents = homeRecentPastEvents(
      allEvents,
      now: now,
    );
    final currentTodayEvents = todayEvents
        .where((event) => !_isPastEvent(event, now))
        .toList(growable: false);
    final upcomingEvents = allEvents.where((event) {
      final startAt = event.startAt;
      return startAt != null &&
          !startAt.isBefore(now) &&
          !planflowIsSameLocalDay(startAt, now);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    final visibleEventIds = <String>{
      ...visiblePastTodayEvents.map((event) => event.id),
      ...currentTodayEvents.map((event) => event.id),
      ...upcomingEvents.take(3).map((event) => event.id),
    };
    var smartPreparationEventIds = const <String>{};
    try {
      smartPreparationEventIds =
          await widget.smartPreparationAlarmService.listEventIdsWithSmartAlarms(
        userId: userId,
        eventIds: visibleEventIds,
      );
    } catch (error, stackTrace) {
      debugPrint('Home smart preparation lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    if (mounted) {
      setState(() {
        _pastTodayEvents = visiblePastTodayEvents;
        _recentPastEvents = recentPastEvents;
        _todayEvents = currentTodayEvents;
        _upcomingEvents = upcomingEvents.take(3).toList(growable: false);
        _smartPreparationEventIds = smartPreparationEventIds;
        _loadState = _HomeLoadState.ready;
        _loadMessage = null;
        _hasRenderedContent = true;
        _consecutiveFailures = 0;
        _retryTimer?.cancel();
      });
    }

    if (refreshHomeWidget) {
      _scheduleHomeWidgetRefresh(allEvents, now: now);
    }
  }

  Future<void> _resolveEventsMissingCoords(
    List<EventModel> allEvents,
    EventRepository repository,
  ) async {
    final missing = allEvents
        .where(
          (e) =>
              e.location != null &&
              e.location!.trim().isNotEmpty &&
              e.locationLat == null,
        )
        .toList();
    if (missing.isEmpty) return;
    final service = LocationLookupService();
    for (final event in missing) {
      try {
        final results = await service.search(event.location!, origin: null);
        if (results.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final best = results.first;
        await repository.updateEvent(EventModel(
          id: event.id,
          userId: event.userId,
          title: event.title,
          startAt: event.startAt,
          endAt: event.endAt,
          location: event.location,
          locationLat: best.latitude,
          locationLng: best.longitude,
          memo: event.memo,
          supplies: event.supplies,
          suppliesChecked: event.suppliesChecked,
          participants: event.participants,
          targets: event.targets,
          isCritical: event.isCritical,
          useStrongAlarm: event.useStrongAlarm,
          recurrenceRule: event.recurrenceRule,
          isAllDay: event.isAllDay,
          isMultiDay: event.isMultiDay,
          parentEventId: event.parentEventId,
          category: event.category,
          source: event.source,
          externalId: event.externalId,
          externalCalendarId: event.externalCalendarId,
          externalEtag: event.externalEtag,
          externalUpdatedAt: event.externalUpdatedAt,
          lastSyncedAt: event.lastSyncedAt,
          createdAt: event.createdAt,
          updatedAt: event.updatedAt,
        ));
      } catch (e) { debugPrint('HomeScreen 위치 동기화 무시: $e'); }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) {
      EventRefreshBus.instance.notifyChanged(reason: 'location_resolved');
      unawaited(const DepartureAlarmService().refreshUpcoming());
    }
  }

  void _scheduleHomeWidgetRefresh(
    List<EventModel> allEvents, {
    required DateTime now,
  }) {
    final generation = ++_homeWidgetRefreshGeneration;
    final eventsSnapshot = List<EventModel>.of(allEvents, growable: false);
    final previous = _homeWidgetRefreshQueue.catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('Home widget refresh queue recovered: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );

    final next = previous.then((_) async {
      if (generation != _homeWidgetRefreshGeneration) {
        return;
      }
      await _homeWidgetService.refreshScheduleFromEvents(
        eventsSnapshot,
        now: now,
      );
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint('Home widget refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    });

    _homeWidgetRefreshQueue = next;
    unawaited(next);
  }

  void _clearHomeContent() {
    _pastTodayEvents = const <EventModel>[];
    _recentPastEvents = const <EventModel>[];
    _todayEvents = const <EventModel>[];
    _upcomingEvents = const <EventModel>[];
    _smartPreparationEventIds = const <String>{};
    _hasRenderedContent = false;
  }

  String? _resolveUserId() {
    final overrideUserId = widget.userIdOverride?.trim();
    if (overrideUserId != null && overrideUserId.isNotEmpty) {
      return overrideUserId;
    }
    return Supabase.instance.client.auth.currentSession?.user.id;
  }

  Future<void> _playBriefing({required bool isMorning}) async {
    final user = Supabase.instance.client.auth.currentSession?.user;
    if (user == null) {
      _showSnack('일정을 확인하려면 로그인 세션을 다시 확인해 주세요.');
      return;
    }
    if (_isPlayingMorningBriefing || _isPlayingEveningBriefing) {
      return;
    }

    setState(() {
      if (isMorning) {
        _isPlayingMorningBriefing = true;
      } else {
        _isPlayingEveningBriefing = true;
      }
    });

    try {
      final result = await _briefingSchedulerService.executeBriefing(
        isMorning: isMorning,
        userId: user.id,
        isManualTrigger: true,
      );
      _showSnack(result.message);
    } catch (error, stackTrace) {
      debugPrint('Home briefing play failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('브리핑 재생에 실패했습니다. 알림/TTS 설정을 확인해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          if (isMorning) {
            _isPlayingMorningBriefing = false;
          } else {
            _isPlayingEveningBriefing = false;
          }
        });
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoading = _loadState == _HomeLoadState.loading;

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 96,
        titleSpacing: AppConstants.defaultPadding,
        backgroundColor: PlanFlowColors.background,
        surfaceTintColor: Colors.transparent,
        title: _HomeHeader(onVoice: () => context.push(AppRoutes.voice)),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: isLoading ? null : _loadTodayEvents,
            icon: isLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: PlanFlowColors.background,
          child: RefreshIndicator(
            onRefresh: _loadTodayEvents,
            child: SingleChildScrollView(
              controller: widget.scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppConstants.defaultPadding,
                12,
                AppConstants.defaultPadding,
                96,
              ),
              child: ResponsiveContent(
                maxWidth: context.planflowWindowInfo.contentMaxWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: PlanFlowColors.primaryMid,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color:
                                PlanFlowColors.primary.withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  _todayEvents.isEmpty
                                      ? '오늘은 여유로운\n하루예요 😊'
                                      : '오늘 ${_todayEvents.length}개의\n일정이 있어요',
                                  style:
                                      theme.textTheme.headlineSmall?.copyWith(
                                    color: Colors.white,
                                    fontSize: 25,
                                    fontWeight: FontWeight.w900,
                                    height: 1.18,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 132),
                                child: _HomeInfoChip(
                                  icon: _headerSummary?.weatherIcon ??
                                      Icons.wb_sunny_outlined,
                                  label: _headerSummaryLoading
                                      ? '날씨 확인 중'
                                      : (_headerSummary?.weatherLabel ??
                                          '날씨 확인 중'),
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.16),
                                  borderColor:
                                      Colors.white.withValues(alpha: 0.30),
                                  foregroundColor: Colors.white,
                                  onTap: _headerSummaryLoading
                                      ? null
                                      : () => _showHeaderSummarySheet(
                                            context,
                                            title: '날씨 정보',
                                            summary: _headerSummary,
                                          ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _BriefingQuickActions(
                      isMorningLoading: _isPlayingMorningBriefing,
                      isEveningLoading: _isPlayingEveningBriefing,
                      onMorning: () => _playBriefing(isMorning: true),
                      onEvening: () => _playBriefing(isMorning: false),
                    ),
                    const SizedBox(height: 12),
                    if (isLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_loadState == _HomeLoadState.supabaseMissing ||
                        _loadState == _HomeLoadState.signedOut) ...[
                      _HomeStatusCard(
                        state: _loadState,
                        message: _loadMessage,
                        onRefresh: _loadTodayEvents,
                      ),
                      const SizedBox(height: 12),
                    ] else ...[
                      if (_pastTodayEvents.isNotEmpty) ...[
                        _HomeSectionHeader(
                          title: '지나간 일정',
                          actionLabel: '최근 12시간',
                          onAction: _recentPastEvents.isEmpty
                              ? null
                              : () => _showRecentPastEventsSheet(
                                    context,
                                    _recentPastEvents,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        ..._pastTodayEvents.map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _TodayEventCard(
                              event: event,
                              isPast: true,
                              hasSmartPrepAlarm:
                                  _smartPreparationEventIds.contains(event.id),
                              onTap: () => context.push(
                                '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                                extra: event,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        '오늘 일정',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_todayEvents.isNotEmpty) ...[
                        ..._todayEvents.map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _TodayEventCard(
                              event: event,
                              hasSmartPrepAlarm:
                                  _smartPreparationEventIds.contains(event.id),
                              onTap: () => context.push(
                                '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                                extra: event,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ] else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: PlanFlowColors.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: PlanFlowColors.primaryFaint,
                              width: 0.8,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: PlanFlowColors.primaryFaint,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Icon(
                                      Icons.calendar_month_outlined,
                                      color: PlanFlowColors.primaryMid,
                                      size: 26,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      '오늘 일정 안내',
                                      style:
                                          theme.textTheme.titleMedium?.copyWith(
                                        color: PlanFlowColors.primary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '오늘 남은 일정이 없어요. 이미 지나간 일정은 위에 정리해 두었고, 이제 잠깐 쉬어가도 괜찮아요.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: PlanFlowColors.textSecondary,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () =>
                                      context.push(AppRoutes.voice),
                                  icon: const Icon(Icons.mic, size: 18),
                                  label: const Text('음성으로 새 일정 추가하기'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        PlanFlowColors.tertiaryAccent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    if (_loadState == _HomeLoadState.ready &&
                        _upcomingEvents.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '다가오는 일정',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._upcomingEvents.map(
                        (event) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _UpcomingEventCard(
                            event: event,
                            onTap: () => context.push(
                              '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                              extra: event,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (RemoteConfigService.earlyBirdBannerVisible)
                      const _EarlyBirdBanner(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
        showPulse: _loadState == _HomeLoadState.ready &&
            _todayEvents.isEmpty &&
            _upcomingEvents.isEmpty &&
            _pastTodayEvents.isEmpty,
      ),
    );
  }

  bool _isPastEvent(EventModel event, DateTime now) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    return (event.endAt ?? startAt).isBefore(now);
  }

  bool _eventIntersectsDay(EventModel event, DateTime day) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    return planflowEventIntersectsLocalDay(
      startAt: startAt,
      endAt: event.endAt,
      day: day,
    );
  }
}

@visibleForTesting
List<EventModel> homeRecentPastEvents(
  Iterable<EventModel> events, {
  required DateTime now,
  Duration lookBack = const Duration(hours: 12),
}) {
  final cutoff = now.subtract(lookBack);
  return events.where((event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final endedAt = event.endAt ?? startAt;
    return endedAt.isBefore(now) && !endedAt.isBefore(cutoff);
  }).toList(growable: false)
    ..sort((a, b) =>
        (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)));
}

@visibleForTesting
List<EventModel> homeVisiblePastTodayEvents(Iterable<EventModel> pastEvents) {
  final sorted = pastEvents.where((event) => event.startAt != null).toList()
    ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  if (sorted.isEmpty) {
    return const <EventModel>[];
  }

  // 모든 이벤트의 로컬 시간을 한 번에 변환 (루프 내 반복 호출 방지)
  final withLocal = sorted
      .map((e) => (event: e, local: planflowLocal(e.startAt!)))
      .toList(growable: false);
  final latestStart = withLocal.last.local;
  return withLocal
      .where((e) =>
          e.local.year == latestStart.year &&
          e.local.month == latestStart.month &&
          e.local.day == latestStart.day &&
          e.local.hour == latestStart.hour &&
          e.local.minute == latestStart.minute)
      .map((e) => e.event)
      .toList(growable: false);
}

class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (actionLabel != null)
          TextButton.icon(
            key: const ValueKey('home-recent-past-events-button'),
            onPressed: onAction,
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right, size: 18),
            label: Text(actionLabel!),
            style: TextButton.styleFrom(
              foregroundColor: PlanFlowColors.primaryMid,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }
}

class _BriefingQuickActions extends StatelessWidget {
  const _BriefingQuickActions({
    required this.isMorningLoading,
    required this.isEveningLoading,
    required this.onMorning,
    required this.onEvening,
  });

  final bool isMorningLoading;
  final bool isEveningLoading;
  final VoidCallback onMorning;
  final VoidCallback onEvening;

  @override
  Widget build(BuildContext context) {
    final isBusy = isMorningLoading || isEveningLoading;

    return Row(
      children: [
        Expanded(
          child: _BriefingQuickButton(
            icon: Icons.wb_sunny_outlined,
            label: '모닝 브리핑 듣기',
            isLoading: isMorningLoading,
            onPressed: isBusy ? null : onMorning,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _BriefingQuickButton(
            icon: Icons.nightlight_outlined,
            label: '이브닝 브리핑 듣기',
            isLoading: isEveningLoading,
            onPressed: isBusy ? null : onEvening,
          ),
        ),
      ],
    );
  }
}

class _BriefingQuickButton extends StatelessWidget {
  const _BriefingQuickButton({
    required this.icon,
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool isLoading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: isLoading
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF5D61A8),
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFB9BDE5),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.88),
        side: const BorderSide(color: Color(0xFF8D91CF)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _HomeStatusCard extends StatelessWidget {
  const _HomeStatusCard({
    required this.state,
    required this.onRefresh,
    this.message,
  });

  final _HomeLoadState state;
  final VoidCallback onRefresh;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (state) {
      _HomeLoadState.supabaseMissing => (
          Icons.cloud_off_outlined,
          'Supabase 설정이 필요해요',
          '빌드 설정값이 없어서 오늘 일정을 불러올 수 없어요.',
        ),
      _HomeLoadState.signedOut => (
          Icons.lock_outline,
          '로그인이 필요해요',
          '로그인한 뒤 내 일정을 다시 불러올 수 있어요.',
        ),
      _HomeLoadState.error => (
          Icons.error_outline,
          '일정 불러오기 실패',
          message ?? '오늘 일정을 불러오지 못했습니다.',
        ),
      _HomeLoadState.loading => (
          Icons.hourglass_top_outlined,
          '일정 확인 중',
          '잠시만 기다려 주세요.',
        ),
      _HomeLoadState.ready => (
          Icons.check_circle_outline,
          '정상',
          '오늘 일정을 불러왔어요.',
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: PlanFlowColors.primaryMid),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('새로고침'),
          ),
        ],
      ),
    );
  }
}

class _HomeInfoChip extends StatelessWidget {
  const _HomeInfoChip({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.borderColor,
    required this.foregroundColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color borderColor;
  final Color foregroundColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foregroundColor),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: foregroundColor,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return chip;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onVoice});

  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final todayLabel = _koreanDateLabel(DateTime.now());

    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PlanFlowLogo(fontSize: 30),
              const SizedBox(height: 4),
              Text(
                todayLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '음성 입력',
          onPressed: onVoice,
          icon: const Icon(
            Icons.mic_none,
            size: 34,
            color: PlanFlowColors.primary,
          ),
        ),
      ],
    );
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }
}

Future<void> _showHeaderSummarySheet(
  BuildContext context, {
  required String title,
  required HomeHeaderSummary? summary,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) {
      final effectiveSummary = summary;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '오늘 날씨를 한눈에 확인할 수 있어요.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 16),
                _SummaryDetailTile(
                  icon:
                      effectiveSummary?.weatherIcon ?? Icons.wb_sunny_outlined,
                  accentColor: const Color(0xFF7A5C2E),
                  backgroundColor: const Color(0xFFFFF4E6),
                  title: '날씨 정보',
                  value: effectiveSummary?.weatherLabel ?? '날씨 확인 중',
                  detail: effectiveSummary?.detailLine ?? '현재 날씨를 불러오지 못했어요.',
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> _showRecentPastEventsSheet(
  BuildContext context,
  List<EventModel> events,
) async {
  final rootContext = context;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.42,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: PlanFlowColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '최근 12시간 지난 일정',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: PlanFlowColors.primary,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${events.length}개 일정이 이미 끝났어요.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    itemCount: events.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final event = events[events.length - 1 - index];
                      final startAt = event.startAt == null
                          ? null
                          : planflowLocal(event.startAt!);
                      return Card(
                        color: PlanFlowColors.surface,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(
                            color: PlanFlowColors.primaryFaint,
                            width: 0.8,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            rootContext.push(
                              '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
                              extra: event,
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: PlanFlowColors.tagDoneBg,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.history,
                                    color: PlanFlowColors.textSecondary,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        event.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          color: PlanFlowColors.primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        startAt == null
                                            ? '시간 미정'
                                            : _formatRecentPastEventTime(
                                                startAt,
                                              ),
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: PlanFlowColors.textSecondary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (event.location != null) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          event.location!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: PlanFlowColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.chevron_right,
                                  color: PlanFlowColors.primaryMid,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

String _formatRecentPastEventTime(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$month/$day $hour:$minute';
}

class _SummaryDetailTile extends StatelessWidget {
  const _SummaryDetailTile({
    required this.icon,
    required this.accentColor,
    required this.backgroundColor,
    required this.title,
    required this.value,
    required this.detail,
  });

  final IconData icon;
  final Color accentColor;
  final Color backgroundColor;
  final String title;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.18),
          width: 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accentColor, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        height: 1.35,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Today Event Card ---
class _TodayEventCard extends StatelessWidget {
  const _TodayEventCard({
    required this.event,
    this.isPast = false,
    this.hasSmartPrepAlarm = false,
    this.onTap,
  });

  final EventModel event;
  final bool isPast;
  final bool hasSmartPrepAlarm;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeStr = startAt != null
        ? '${startAt.hour.toString().padLeft(2, '0')}:${startAt.minute.toString().padLeft(2, '0')}'
        : '';
    final multiDayLabel = _multiDayProgressLabel(event);

    final isMultiDay = event.isMultiDay;
    final borderColor = !isPast && event.isCritical
        ? const Color(0xFFB42318).withValues(alpha: 0.4)
        : !isPast && isMultiDay
            ? const Color(0xFF174F4A).withValues(alpha: 0.3)
            : PlanFlowColors.primaryFaint;
    final accentColor = isPast
        ? PlanFlowColors.textSecondary
        : event.isCritical
            ? const Color(0xFFB42318)
            : isMultiDay
                ? const Color(0xFF174F4A)
                : PlanFlowColors.primaryMid;

    return Card(
      color: isPast
          ? PlanFlowColors.surfaceFaint
          : isMultiDay
              ? const Color(0xFFDDEFE6)
              : PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: borderColor,
          width: (event.isCritical || isMultiDay) && !isPast ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isPast
                      ? PlanFlowColors.tagDoneBg
                      : event.isCritical
                          ? const Color(0xFFFFE3DD)
                          : isMultiDay
                              ? const Color(0xFFBEE3CC)
                              : PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: accentColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: isPast
                            ? PlanFlowColors.textSecondary
                            : isMultiDay
                                ? const Color(0xFF174F4A)
                                : PlanFlowColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (event.location != null)
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isPast
                              ? PlanFlowColors.textDisabled
                              : PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (multiDayLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          multiDayLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isPast
                                ? PlanFlowColors.textDisabled
                                : const Color(0xFF174F4A),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (event.supplies.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.backpack_outlined,
                    size: 16,
                    color: accentColor,
                  ),
                ),
              if (hasSmartPrepAlarm)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _SmallBadge(
                    label: '스마트 준비',
                    isPast: isPast,
                  ),
                ),
              if (isPast)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: _SmallBadge(label: '지난 일정', isPast: true),
                ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: accentColor,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _multiDayProgressLabel(EventModel event) {
    if (!event.isMultiDay || event.startAt == null || event.endAt == null) {
      return null;
    }
    final now = DateTime.now();
    final first = planflowLocalDay(event.startAt!);
    final last = planflowLocalDay(event.endAt!);
    final today = DateTime(now.year, now.month, now.day);
    if (today.isBefore(first) || today.isAfter(last)) {
      return null;
    }
    final total = last.difference(first).inDays + 1;
    final current = today.difference(first).inDays + 1;
    return '진행중 · $current/$total일차';
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({
    required this.label,
    this.isPast = false,
  });

  final String label;
  final bool isPast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isPast ? PlanFlowColors.tagDoneBg : PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isPast
                  ? PlanFlowColors.textSecondary
                  : PlanFlowColors.tagNormalText,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _UpcomingEventCard extends StatelessWidget {
  const _UpcomingEventCard({
    required this.event,
    this.onTap,
  });

  final EventModel event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final dateLabel =
        startAt == null ? '시간 미정' : formatHomeUpcomingDateTime(startAt);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: event.isCritical
              ? const Color(0xFFB42318).withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: event.isCritical ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: event.isCritical
                      ? const Color(0xFFFFE3DD)
                      : PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  event.isCritical
                      ? Icons.priority_high
                      : Icons.schedule_outlined,
                  color: event.isCritical
                      ? const Color(0xFFB42318)
                      : PlanFlowColors.primaryMid,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dateLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: PlanFlowColors.primaryMid,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      event.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (event.location != null)
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                color: PlanFlowColors.primaryMid,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Early Bird Banner ---
class _EarlyBirdBanner extends StatefulWidget {
  const _EarlyBirdBanner();

  @override
  State<_EarlyBirdBanner> createState() => _EarlyBirdBannerState();
}

class _EarlyBirdBannerState extends State<_EarlyBirdBanner> {
  final _emailController = TextEditingController();
  bool _isSubmitting = false;
  bool _isSubmitted = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('올바른 이메일을 입력해 주세요.')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      if (!AppEnv.isSupabaseReady) {
        throw StateError('Supabase is not configured.');
      }

      final repository = EarlyBirdEmailRepository.supabase();
      await repository.saveEmail(email);

      if (mounted) {
        setState(() {
          _isSubmitted = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 얼리버드 신청이 완료되었습니다!'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신청에 실패했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const earlyBirdMessage =
        '현재 어플이 마음에 드신다면 사전 신청해주세요. 유료모델 전환때 특별한 혜택을 드립니다.';

    if (_isSubmitted) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF0E7),
          border: Border.all(
            color: const Color(0xFFC67E52).withValues(alpha: 0.48),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFC67E52).withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🎉 얼리버드 신청 완료!',
              style: TextStyle(
                color: Color(0xFF111111),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'PRO 출시 때 특별 할인 혜택을 보내드릴게요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF222222),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF0E7),
        border: Border.all(
          color: const Color(0xFFC67E52).withValues(alpha: 0.48),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFC67E52).withValues(alpha: 0.10),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🚀 PRO 얼리버드 신청',
            style: TextStyle(
              color: Color(0xFF111111),
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            earlyBirdMessage,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Color(0xFF222222),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: 'your@email.com',
                    hintStyle: TextStyle(
                      color: const Color(0xFF333333).withValues(alpha: 0.72),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.92),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: const Color(0xFFE1A57A).withValues(alpha: 0.28),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: const Color(0xFFE1A57A).withValues(alpha: 0.80),
                        width: 1.2,
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB85C44),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 44),
                ),
                child: _isSubmitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('신청'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
