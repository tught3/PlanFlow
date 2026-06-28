import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/time_format_controller.dart';
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
part 'home_widgets.dart';

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
  final time = planflowFormatTime(value.hour, value.minute);

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
    this.locationLookupService,
    BriefingSchedulerService? briefingSchedulerService,
  }) : _briefingSchedulerService = briefingSchedulerService;

  final ScrollController? scrollController;
  final String? userIdOverride;
  final EventRepository? eventRepository;
  final SmartPreparationAlarmService smartPreparationAlarmService;
  final HomeWidgetService? homeWidgetService;
  final bool loadHeaderSummary;
  final DateTime Function()? nowProvider;

  /// 좌표 보정에 쓰는 장소 검색 서비스. 테스트에서 호출 횟수를 세는 fake를
  /// 주입하기 위한 진입점(미주입 시 기본 LocationLookupService 사용).
  final LocationLookupService? locationLookupService;
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

  /// 좌표 보정(_resolveEventsMissingCoords) 재진입 가드.
  /// 좌표 보정 끝에서 EventRefreshBus.notifyChanged를 쏘면 다시 홈 리로드가
  /// 일어나 보정이 재호출된다. 가드가 없으면 보정 패스가 겹쳐 돌며 외부
  /// 지오코딩 API(tmap_poi 등)를 폭주시킨다(2026-06-28 tmap_poi 800회 차단 사건).
  bool _resolvingCoords = false;

  /// 같은 (event, location) 조합의 지오코딩 재시도 쿨다운.
  /// tmap이 못 찾는 위치 문자열은 좌표가 영원히 안 채워져 매 홈 리로드마다
  /// 재검색된다. 시도 시각을 영속 기록해 이 기간 동안은 재검색을 건너뛴다.
  /// 사용자가 위치를 수정하면 키가 바뀌어 즉시 재시도된다(쿨다운 우회).
  static const Duration _geoRetryCooldown = Duration(hours: 24);
  static const String _geoAttemptKeyPrefix = 'geo_resolve_attempt:';

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
    // 재진입 차단: 좌표 보정 끝의 notifyChanged가 홈 리로드를 다시 일으켜
    // 이 함수를 재호출하므로, 이미 보정 중이면 새 패스를 시작하지 않는다.
    if (_resolvingCoords) return;
    final missing = allEvents
        .where(
          (e) =>
              e.location != null &&
              e.location!.trim().isNotEmpty &&
              e.locationLat == null,
        )
        .toList();
    if (missing.isEmpty) return;

    _resolvingCoords = true;
    var resolvedAny = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final cooldownMs = _geoRetryCooldown.inMilliseconds;
      final service = widget.locationLookupService ?? LocationLookupService();

      // 쿨다운 키 누적 방지: 더 이상 존재하지 않는(삭제된) 일정의 시도 키를
      // 정리한다. 키는 현재 일정 id로 시작할 때만 살아있는 것으로 본다
      // (location에 ':'가 있어도 안전하도록 split 대신 prefix 매칭 사용).
      final liveIds = allEvents.map((e) => e.id).toSet();
      final staleKeys = prefs
          .getKeys()
          .where((key) =>
              key.startsWith(_geoAttemptKeyPrefix) &&
              !liveIds.any((id) => key.startsWith('$_geoAttemptKeyPrefix$id:')))
          .toList(growable: false);
      for (final key in staleKeys) {
        await prefs.remove(key);
      }
      for (final event in missing) {
        // 쿨다운: 같은 (event, location)을 최근에 시도했으면 재검색 스킵.
        // location 문자열을 키에 넣어, 사용자가 위치를 고치면 키가 바뀌어
        // 즉시 재시도된다. 시도 기록은 성공/실패/예외 모두에 남겨,
        // 영영 못 찾는 위치가 매 리로드마다 API를 두드리지 않게 한다.
        final attemptKey =
            '$_geoAttemptKeyPrefix${event.id}:${event.location!.trim()}';
        final lastAttemptMs = prefs.getInt(attemptKey);
        if (lastAttemptMs != null && nowMs - lastAttemptMs < cooldownMs) {
          continue;
        }
        try {
          final results = await service.search(event.location!, origin: null);
          // 시도 자체를 기록(빈 결과여도) → 쿨다운 동안 재검색 차단.
          await prefs.setInt(attemptKey, nowMs);
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
          resolvedAny = true;
        } catch (e) {
          // 예외(인증 실패 등)도 시도로 기록해 쿨다운 동안 재호출을 막는다.
          await prefs.setInt(attemptKey, nowMs);
          debugPrint('HomeScreen 위치 동기화 무시: $e');
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _resolvingCoords = false;
    }
    // 실제로 좌표를 채운 경우에만 새로고침을 트리거한다. 무조건 쏘면
    // 홈 리로드 → 좌표 보정 → notifyChanged의 자기피드백 루프가 되어
    // 아무것도 못 풀어도 외부 지오코딩 API를 끝없이 호출한다(폭주 근본 원인).
    if (resolvedAny && mounted) {
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
