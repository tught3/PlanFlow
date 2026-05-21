import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/models/pre_action_model.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/app_feedback_service.dart';
import '../../services/background_task_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/home_widget_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/smart_preparation_alarm_service.dart';

class EventDetailScreen extends StatefulWidget {
  EventDetailScreen({
    super.key,
    this.event,
    this.eventId,
    this.eventRepository,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
    SmartPreparationAlarmService? smartPreparationAlarmService,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService(),
        smartPreparationAlarmService = smartPreparationAlarmService ??
            const SmartPreparationAlarmService();

  final EventModel? event;
  final String? eventId;
  final EventRepository? eventRepository;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;
  final SmartPreparationAlarmService smartPreparationAlarmService;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  EventModel? _event;
  bool _isLoading = false;
  bool _isDeleting = false;
  bool _isSavingSupplies = false;
  String? _loadError;
  final Set<String> _checkedSupplies = <String>{};
  List<PreActionModel> _smartPreparationAlarms = const <PreActionModel>[];

  String? get _resolvedEventId {
    final routeId = widget.eventId?.trim();
    if (routeId != null && routeId.isNotEmpty) {
      return routeId;
    }
    final extraId = widget.event?.id.trim();
    if (extraId != null && extraId.isNotEmpty) {
      return extraId;
    }
    return null;
  }

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  @override
  void initState() {
    super.initState();
    _event = widget.event;
    _syncCheckedSupplies();
    _loadLatestEvent();
  }

  Future<void> _loadLatestEvent() async {
    final eventId = _resolvedEventId;
    if (eventId == null || eventId.isEmpty || !AppEnv.isSupabaseReady) {
      setState(() {
        _loadError = _event == null ? '일정 정보를 불러오지 못했습니다.' : null;
      });
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() {
        _loadError = _event == null ? '로그인 후 일정 정보를 다시 확인할 수 있습니다.' : null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final latestEvent = await _repository.fetchEvent(
        eventId,
        userId: user.id,
      );
      final smartPreparationAlarms = latestEvent == null
          ? const <PreActionModel>[]
          : await widget.smartPreparationAlarmService.listForEvent(
              eventId: latestEvent.id,
              userId: user.id,
            );
      if (!mounted) {
        return;
      }
      setState(() {
        _event = latestEvent ?? _event;
        _smartPreparationAlarms = smartPreparationAlarms;
        _loadError = latestEvent == null ? '일정을 다시 찾지 못했습니다.' : null;
        _syncCheckedSupplies();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError = _event == null ? '일정 정보를 불러오지 못했습니다.' : null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _syncCheckedSupplies() {
    final supplies = _event?.supplies.toSet() ?? const <String>{};
    final persisted = _event?.suppliesChecked.toSet() ?? const <String>{};
    _checkedSupplies
      ..clear()
      ..addAll(persisted.where(supplies.contains));
    _checkedSupplies.removeWhere((item) => !supplies.contains(item));
  }

  Future<void> _toggleSupply(String item) async {
    final event = _event;
    if (event == null || _isSavingSupplies) {
      return;
    }

    final previous = Set<String>.from(_checkedSupplies);
    setState(() {
      _isSavingSupplies = true;
      if (_checkedSupplies.contains(item)) {
        _checkedSupplies.remove(item);
      } else {
        _checkedSupplies.add(item);
      }
    });

    try {
      final saved = await _repository.updateSuppliesChecked(
        eventId: event.id,
        suppliesChecked: _checkedSupplies.toList(growable: false),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _event = saved;
        _syncCheckedSupplies();
      });
      EventRefreshBus.instance.notifyChanged(
        reason: 'event_supplies_checked_updated',
        eventId: saved.id,
        startAt: saved.startAt,
      );
    } catch (error, stackTrace) {
      debugPrint('Supply checklist save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _checkedSupplies
          ..clear()
          ..addAll(previous);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('준비물 체크 상태를 저장하지 못했습니다. 다시 시도해 주세요.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSavingSupplies = false;
        });
      }
    }
  }

  Future<void> _deleteEvent() async {
    final event = _event;
    if (event == null) {
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('일정 삭제'),
        content: Text('"${event.title}" 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.'),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: PlanFlowColors.primary,
                    backgroundColor: PlanFlowColors.primaryFaint,
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: const Color(0xFFB42318),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('삭제'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) {
      return;
    }

    setState(() {
      _isDeleting = true;
    });

    try {
      if (AppEnv.isSupabaseReady) {
        await _repository.deleteEvent(event.id);
        unawaited(_runDeleteFollowUps(event));
      }

      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('일정을 삭제했습니다.')),
        );
        EventRefreshBus.instance.notifyChanged(
          reason: 'event_deleted',
          eventId: event.id,
          startAt: event.startAt,
        );
        context.go(AppRoutes.calendar);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('삭제하지 못했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  Future<void> _runDeleteFollowUps(EventModel event) {
    return BackgroundTaskService.run(
      () async {
        final user = Supabase.instance.client.auth.currentUser;
        final settings =
            user == null ? null : await _fetchSettingsOrNull(user.id);
        await _runFollowUpStep(
          'cleanup_after_delete',
          () => widget.sideEffectService.cleanupAfterDelete(
            event.id,
            userId: user?.id,
            prepTimeMin: settings?.prepTimeMin ??
                SmartPreparationAlarmService.defaultPrepTimeMin,
            prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
                SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
            departPreAlarmOffset: settings?.departPreAlarmOffset ??
                SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
            departureSafetyMargin: Duration(
              minutes: settings?.departureSafetyMarginMin ??
                  DepartureAlarmService.safetyMargin.inMinutes,
            ),
            travelMode: settings?.travelMode ?? 'car',
          ),
        );
        await _runFollowUpStep(
          'resync_external_preparation_after_delete',
          () => _resyncExternalPreparationAfterDelete(event),
        );
        await _runFollowUpStep(
          'refresh_home_widget_after_delete',
          () => _refreshHomeWidget(_repository),
        );
      },
      owner: 'EventDetailScreen',
      label: 'delete_follow_ups',
      failureMessage: '삭제는 완료됐지만 알림/위젯 정리 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.',
    );
  }

  Future<void> _runFollowUpStep(
    String label,
    Future<void> Function() task,
  ) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('EventDetailScreen follow-up failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
      AppFeedbackService.showSnackBar(_followUpFailureMessage(label));
    }
  }

  String _followUpFailureMessage(String label) {
    final taskName = switch (label) {
      'cleanup_after_delete' => '삭제된 일정의 알림 정리',
      'resync_external_preparation_after_delete' => '삭제 후 준비알람 다시 계산',
      'refresh_home_widget_after_delete' => '홈 위젯 갱신',
      _ => '후속 작업',
    };
    return '삭제는 완료됐지만 $taskName 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.';
  }

  Future<void> _refreshHomeWidget(EventRepository repository) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return;
      }

      final now = DateTime.now();
      final events = await repository.listEvents(userId: user.id);
      await widget.homeWidgetService.updateSchedulePayload(
        HomeWidgetSchedulePayloadBuilder.fromEvents(
          events: events,
          now: now,
        ),
      );
    } catch (_) {
      // Widget refresh should not block event deletion.
    }
  }

  Future<void> _resyncExternalPreparationAfterDelete(
    EventModel deletedEvent,
  ) async {
    final deletedStartAt = deletedEvent.startAt;
    if (deletedStartAt == null) {
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      return;
    }
    try {
      final settings = await _fetchSettingsOrNull(user.id);
      final events = await _repository.listEvents(userId: user.id);
      await widget.sideEffectService.resyncExternalPreparationForDay(
        dayEvents: events,
        userId: user.id,
        dayReference: deletedStartAt,
        prepTimeMin: settings?.prepTimeMin ??
            SmartPreparationAlarmService.defaultPrepTimeMin,
        prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
            SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
        departPreAlarmOffset: settings?.departPreAlarmOffset ??
            SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
        departureSafetyMargin: Duration(
          minutes: settings?.departureSafetyMarginMin ??
              DepartureAlarmService.safetyMargin.inMinutes,
        ),
        travelMode: settings?.travelMode ?? 'car',
      );
    } catch (error, stackTrace) {
      debugPrint(
        'EventDetailScreen external prep delete resync skipped: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<UserSettingsModel?> _fetchSettingsOrNull(String userId) async {
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    try {
      return await SettingsRepository.supabase().fetchSettings(userId);
    } catch (error, stackTrace) {
      debugPrint('EventDetailScreen settings lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = _event;

    if (event == null) {
      return Scaffold(
        backgroundColor: PlanFlowColors.background,
        appBar: AppBar(title: const Text('일정 상세')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoading)
                  const CircularProgressIndicator()
                else
                  const Icon(Icons.event_busy_outlined, size: 40),
                const SizedBox(height: 12),
                Text(_loadError ?? '일정 정보를 불러오지 못했습니다.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isLoading ? null : _loadLatestEvent,
                  icon: const Icon(Icons.refresh),
                  label: const Text('다시 불러오기'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final timeLabel = _formatTimeRange(event.startAt, event.endAt);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('일정 상세'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _isLoading ? null : _loadLatestEvent,
            icon: _isLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          TextButton.icon(
            onPressed: () => context.push(
              '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
              extra: event,
            ),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('편집'),
          ),
        ],
      ),
      body: SafeArea(
        child: ResponsiveContent(
          maxWidth: 760,
          child: ListView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              _HeaderCard(
                title: event.title,
                time: timeLabel ?? '시간 미정',
                critical: event.isCritical,
              ),
              if (_loadError != null) ...[
                const SizedBox(height: AppConstants.sectionSpacing),
                _InfoCard(
                  title: '최신 정보 확인',
                  children: [
                    Text(
                      _loadError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppConstants.sectionSpacing),
              _InfoCard(
                title: '기본 정보',
                children: [
                  if (timeLabel != null)
                    _InfoRow(label: '시간', value: timeLabel),
                  if (event.location != null)
                    _InfoRow(label: '장소', value: event.location!),
                  _InfoRow(
                    label: '중요 상태',
                    value: event.isCritical ? '중요 일정' : '일반 일정',
                    valueColor:
                        event.isCritical ? theme.colorScheme.error : null,
                  ),
                  _InfoRow(
                    label: '등록일',
                    value: event.createdAt != null
                        ? _formatDate(event.createdAt!)
                        : '정보 없음',
                  ),
                ],
              ),
              if (event.supplies.isNotEmpty) ...[
                const SizedBox(height: AppConstants.sectionSpacing),
                _InfoCard(
                  title: '준비물',
                  children: [
                    _SupplyChecklist(
                      supplies: event.supplies,
                      checkedSupplies: _checkedSupplies,
                      isSaving: _isSavingSupplies,
                      onToggle: _toggleSupply,
                    ),
                  ],
                ),
              ],
              if (_smartPreparationAlarms.isNotEmpty) ...[
                const SizedBox(height: AppConstants.sectionSpacing),
                _InfoCard(
                  title: SmartPreparationAlarmService.label,
                  children: [
                    _SmartPreparationAlarmList(
                      alarms: _smartPreparationAlarms,
                      formatDateTime: _formatDateTime,
                    ),
                  ],
                ),
              ],
              if (event.memo != null && event.memo!.trim().isNotEmpty) ...[
                const SizedBox(height: AppConstants.sectionSpacing),
                _InfoCard(
                  title: '메모',
                  children: [
                    Text(
                      event.memo!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppConstants.sectionSpacing),
              FilledButton.icon(
                onPressed: () => context.push(
                  '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
                  extra: event,
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('일정 편집'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _isDeleting ? null : _deleteEvent,
                icon: _isDeleting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.delete_outline,
                      ),
                label: Text(
                  _isDeleting ? '삭제 중...' : '일정 삭제',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB42318),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final localStart = planflowLocal(start);
    final dateStr =
        '${localStart.year}-${localStart.month.toString().padLeft(2, '0')}-${localStart.day.toString().padLeft(2, '0')}';
    final startTimeStr =
        '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return '$dateStr $startTimeStr';
    }
    final localEnd = planflowLocal(end);
    final endTimeStr =
        '${localEnd.hour.toString().padLeft(2, '0')}:${localEnd.minute.toString().padLeft(2, '0')}';
    return '$dateStr $startTimeStr - $endTimeStr';
  }

  String _formatDate(DateTime value) {
    final local = planflowLocal(value);
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime value) {
    final local = planflowLocal(value);
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${_formatDate(local)} $hour:$minute';
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.title,
    required this.time,
    required this.critical,
  });

  final String title;
  final String time;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: critical
              ? const Color(0xFFB42318).withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: critical ? 1.5 : 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (critical)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE3DD),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '중요',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              time,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmartPreparationAlarmList extends StatelessWidget {
  const _SmartPreparationAlarmList({
    required this.alarms,
    required this.formatDateTime,
  });

  final List<PreActionModel> alarms;
  final String Function(DateTime value) formatDateTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        for (var index = 0; index < alarms.length; index += 1) ...[
          if (index > 0)
            const Divider(
              height: 18,
              color: PlanFlowColors.primaryFaint,
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.notifications_active_outlined,
                  color: PlanFlowColors.primaryMid,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alarms[index].title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      alarms[index].notifyAt == null
                          ? '알림 시간 미정'
                          : '${formatDateTime(alarms[index].notifyAt!)} 알림',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = <Widget>[];

    for (final child in children) {
      if (sections.isNotEmpty) {
        sections.add(const SizedBox(height: 12));
      }
      sections.add(child);
    }

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ...sections,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _SupplyChecklist extends StatelessWidget {
  const _SupplyChecklist({
    required this.supplies,
    required this.checkedSupplies,
    required this.isSaving,
    required this.onToggle,
  });

  final List<String> supplies;
  final Set<String> checkedSupplies;
  final bool isSaving;
  final Future<void> Function(String item) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: supplies.map((item) {
        final checked = checkedSupplies.contains(item);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isSaving ? null : () => onToggle(item),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: checked
                    ? const Color(0xFFEAF5EE)
                    : PlanFlowColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: checked
                      ? const Color(0xFF8BBF99)
                      : PlanFlowColors.primaryFaint,
                  width: 0.6,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    checked ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: checked
                        ? const Color(0xFF2E7D32)
                        : PlanFlowColors.primaryMid,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: checked
                            ? PlanFlowColors.textSecondary
                            : PlanFlowColors.textPrimary,
                        decoration: checked
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}
