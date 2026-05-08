import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/early_bird_email_repository.dart';
import '../../services/app_permission_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/home_header_summary_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../widgets/planflow_voice_fab.dart';

enum _HomeLoadState {
  loading,
  ready,
  supabaseMissing,
  signedOut,
  error,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.scrollController,
  });

  final ScrollController? scrollController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final HomeHeaderSummaryService _headerSummaryService =
      HomeHeaderSummaryService();
  EventModel? _pastTodayEvent;
  List<EventModel> _todayEvents = const <EventModel>[];
  List<EventModel> _upcomingEvents = const <EventModel>[];
  Set<String> _smartPreparationEventIds = const <String>{};
  HomeHeaderSummary? _headerSummary;
  _HomeLoadState _loadState = _HomeLoadState.loading;
  String? _loadMessage;
  bool _headerSummaryLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EventRefreshBus.instance.latest.addListener(_handleEventRefresh);
    _loadTodayEvents();
    unawaited(_loadHomeHeaderSummary());
  }

  @override
  void dispose() {
    EventRefreshBus.instance.latest.removeListener(_handleEventRefresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadTodayEvents();
      unawaited(_loadHomeHeaderSummary());
    }
  }

  void _handleEventRefresh() {
    _loadTodayEvents();
    unawaited(_loadHomeHeaderSummary());
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
    if (mounted) {
      setState(() {
        _loadState = _HomeLoadState.loading;
        _loadMessage = null;
      });
    }

    if (!AppEnv.isSupabaseReady) {
      if (mounted) {
        setState(() {
          _pastTodayEvent = null;
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _smartPreparationEventIds = const <String>{};
          _loadState = _HomeLoadState.supabaseMissing;
        });
      }
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _pastTodayEvent = null;
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _smartPreparationEventIds = const <String>{};
          _loadState = _HomeLoadState.signedOut;
        });
      }
      return;
    }

    try {
      final repository = EventRepository.supabase();
      final allEvents = await repository.listEvents(userId: user.id);
      final now = DateTime.now();
      final todayEvents = allEvents.where((event) {
        return _eventIntersectsDay(event, now);
      }).toList(growable: false)
        ..sort((a, b) =>
            (a.startAt ?? DateTime(0)).compareTo(b.startAt ?? DateTime(0)));
      final pastTodayEvents = todayEvents
          .where((event) => _isPastEvent(event, now))
          .toList(growable: false);
      final currentTodayEvents = todayEvents
          .where((event) => !_isPastEvent(event, now))
          .toList(growable: false);
      final upcomingEvents = allEvents.where((event) {
        final startAt = event.startAt;
        return startAt != null &&
            !startAt.isBefore(now) &&
            !_isSameDate(startAt, now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
      final visibleEventIds = <String>{
        if (pastTodayEvents.isNotEmpty) pastTodayEvents.last.id,
        ...currentTodayEvents.map((event) => event.id),
        ...upcomingEvents.take(3).map((event) => event.id),
      };
      var smartPreparationEventIds = const <String>{};
      try {
        smartPreparationEventIds = await const SmartPreparationAlarmService()
            .listEventIdsWithSmartAlarms(
          userId: user.id,
          eventIds: visibleEventIds,
        );
      } catch (error, stackTrace) {
        debugPrint('Home smart preparation lookup failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }

      if (mounted) {
        setState(() {
          _pastTodayEvent =
              pastTodayEvents.isEmpty ? null : pastTodayEvents.last;
          _todayEvents = currentTodayEvents;
          _upcomingEvents = upcomingEvents.take(3).toList(growable: false);
          _smartPreparationEventIds = smartPreparationEventIds;
          _loadState = _HomeLoadState.ready;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _pastTodayEvent = null;
          _todayEvents = const <EventModel>[];
          _upcomingEvents = const <EventModel>[];
          _smartPreparationEventIds = const <String>{};
          _loadState = _HomeLoadState.error;
          _loadMessage = '오늘 일정을 불러오지 못했어요. 새로고침해 주세요.';
        });
      }
      debugPrint('HomeScreen load failed: $error');
    } finally {
      // Loading state is replaced by one of the terminal states above.
    }
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
                          color: PlanFlowColors.primary.withValues(alpha: 0.16),
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
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: Colors.white,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w900,
                                  height: 1.18,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 132),
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
                  const SizedBox(height: 12),
                  if (isLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_loadState != _HomeLoadState.ready) ...[
                    _HomeStatusCard(
                      state: _loadState,
                      message: _loadMessage,
                      onRefresh: _loadTodayEvents,
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    if (_pastTodayEvent != null) ...[
                      Text(
                        '지나간 일정',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: PlanFlowColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _TodayEventCard(
                        event: _pastTodayEvent!,
                        isPast: true,
                        hasSmartPrepAlarm: _smartPreparationEventIds
                            .contains(_pastTodayEvent!.id),
                        onTap: () => context.push(
                          '${AppRoutes.eventDetail}/${Uri.encodeComponent(_pastTodayEvent!.id)}',
                          extra: _pastTodayEvent,
                        ),
                      ),
                      const SizedBox(height: 12),
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
                            const SizedBox(height: 12),
                            Text(
                              '오늘 일정 안내',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: PlanFlowColors.primary,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '현재 남은 오늘 일정이 없어요. 새 일정이 생기면 준비물과 스마트 준비 알람을 함께 정리해 드릴게요.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                                height: 1.35,
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
                  const _EarlyBirdBanner(),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
    );
  }

  bool _isSameDate(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
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
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final endAt = event.endAt ?? startAt;
    return startAt.isBefore(dayEnd) && !endAt.isBefore(dayStart);
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
          '환경값이 없어서 오늘 일정을 불러올 수 없어요.',
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
              const Text(
                'PlanFlow',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  color: PlanFlowColors.primaryMid,
                  letterSpacing: -1.2,
                ),
              ),
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
    final startAt = event.startAt;
    final timeStr = startAt != null
        ? '${startAt.hour.toString().padLeft(2, '0')}:${startAt.minute.toString().padLeft(2, '0')}'
        : '';
    final multiDayLabel = _multiDayProgressLabel(event);

    final borderColor = event.isCritical && !isPast
        ? const Color(0xFFB42318).withValues(alpha: 0.4)
        : PlanFlowColors.primaryFaint;
    final accentColor = isPast
        ? PlanFlowColors.textSecondary
        : event.isCritical
            ? const Color(0xFFB42318)
            : PlanFlowColors.primaryMid;

    return Card(
      color: isPast ? PlanFlowColors.surfaceFaint : PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: borderColor,
          width: event.isCritical && !isPast ? 1.5 : 0.5,
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
                                : PlanFlowColors.primaryMid,
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
    final first = DateTime(
      event.startAt!.year,
      event.startAt!.month,
      event.startAt!.day,
    );
    final last = DateTime(
      event.endAt!.year,
      event.endAt!.month,
      event.endAt!.day,
    );
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
    final startAt = event.startAt;
    final dateLabel = startAt == null ? '시간 미정' : _formatDateTime(startAt);

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

  String _formatDateTime(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
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
            '무제한 음성 등록, AI 브리핑, 스마트 준비 알람을 먼저 만나보세요.\n출시 시 특별 할인 혜택을 드립니다.',
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
