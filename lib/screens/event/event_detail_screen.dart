import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/home_widget_service.dart';
import '../../services/manual_event_side_effect_service.dart';

class EventDetailScreen extends StatefulWidget {
  EventDetailScreen({
    super.key,
    this.event,
    this.eventId,
    this.eventRepository,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final EventModel? event;
  final String? eventId;
  final EventRepository? eventRepository;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  EventModel? _event;
  bool _isLoading = false;
  bool _isDeleting = false;
  String? _loadError;

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
      if (!mounted) {
        return;
      }
      setState(() {
        _event = latestEvent ?? _event;
        _loadError = latestEvent == null ? '일정을 다시 찾지 못했습니다.' : null;
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
            ),
            child: const Text('삭제'),
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
        await widget.sideEffectService.cleanupAfterDelete(event.id);
        unawaited(_refreshHomeWidget(_repository));
      }

      if (mounted) {
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

  Future<void> _refreshHomeWidget(EventRepository repository) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return;
      }

      final now = DateTime.now();
      final events = await repository.listEvents(userId: user.id);
      final nextEvents = events.where((event) {
        final startAt = event.startAt;
        return startAt != null && !startAt.isBefore(now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

      final widgetService = widget.homeWidgetService;
      if (nextEvents.isEmpty) {
        await widgetService.updateNextEventData(
          const HomeWidgetNextEventData(title: '예정된 일정이 없어요'),
        );
        return;
      }

      final nextEvent = nextEvents.first;
      await widgetService.updateNextEvent(
        title: nextEvent.title,
        eventId: nextEvent.id,
        startAt: nextEvent.startAt,
        location: nextEvent.location,
        isCritical: nextEvent.isCritical,
        upcomingEvents: nextEvents
            .take(3)
            .map(
              (event) => HomeWidgetListEventData(
                title: event.title,
                startAt: event.startAt,
                location: event.location,
              ),
            )
            .toList(growable: false),
      );
    } catch (_) {
      // Widget refresh should not block event deletion.
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
                if (timeLabel != null) _InfoRow(label: '시간', value: timeLabel),
                if (event.location != null)
                  _InfoRow(label: '장소', value: event.location!),
                _InfoRow(
                  label: '중요 상태',
                  value: event.isCritical ? '중요 일정' : '일반 일정',
                  valueColor: event.isCritical ? theme.colorScheme.error : null,
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: event.supplies
                        .map(
                          (item) => Chip(
                            backgroundColor: PlanFlowColors.tagNormalBg,
                            side: const BorderSide(
                              color: PlanFlowColors.primaryFaint,
                              width: 0.5,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            avatar: const Icon(
                              Icons.backpack_outlined,
                              size: 14,
                              color: PlanFlowColors.tagNormalText,
                            ),
                            label: Text(item),
                            labelStyle: theme.textTheme.labelSmall?.copyWith(
                              color: PlanFlowColors.primaryMid,
                              fontSize: 9,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        )
                        .toList(),
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
            OutlinedButton.icon(
              onPressed: _isDeleting ? null : _deleteEvent,
              icon: _isDeleting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFB42318),
                    ),
              label: Text(
                _isDeleting ? '삭제 중...' : '일정 삭제',
                style: const TextStyle(color: Color(0xFFB42318)),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFFFE3DD)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _formatTimeRange(DateTime? start, DateTime? end) {
    if (start == null) {
      return null;
    }
    final dateStr =
        '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final startTimeStr =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return '$dateStr $startTimeStr';
    }
    final endTimeStr =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    return '$dateStr $startTimeStr - $endTimeStr';
  }

  String _formatDate(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
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
