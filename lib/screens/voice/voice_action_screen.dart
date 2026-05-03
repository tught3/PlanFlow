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

enum VoiceScheduleAction { edit, delete }

class VoiceActionScreen extends StatefulWidget {
  VoiceActionScreen({
    super.key,
    required this.rawText,
    required this.action,
    this.eventRepository,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
    this.userIdOverride,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final String rawText;
  final VoiceScheduleAction action;
  final EventRepository? eventRepository;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;
  final String? userIdOverride;

  @override
  State<VoiceActionScreen> createState() => _VoiceActionScreenState();
}

class _VoiceActionScreenState extends State<VoiceActionScreen> {
  final List<EventModel> _events = <EventModel>[];
  bool _isLoading = true;
  bool _isDeleting = false;
  String? _message;

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  bool get _isDelete => widget.action == VoiceScheduleAction.delete;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCandidates());
  }

  Future<void> _loadCandidates() async {
    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final userId = _resolveUserId();
      if (userId == null) {
        setState(() {
          _message = '로그인 후 음성으로 일정을 ${_isDelete ? '삭제' : '수정'}할 수 있어요.';
          _isLoading = false;
        });
        return;
      }

      if (!AppEnv.isSupabaseReady && widget.eventRepository == null) {
        setState(() {
          _message = 'Supabase 설정이 없어 저장된 일정을 불러올 수 없습니다.';
          _isLoading = false;
        });
        return;
      }

      final events = await _repository.listEvents(userId: userId);
      final ranked = _rankEvents(events, widget.rawText);
      if (!mounted) {
        return;
      }
      setState(() {
        _events
          ..clear()
          ..addAll(ranked);
        _message = ranked.isEmpty ? '조건에 맞는 일정을 찾지 못했어요.' : null;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '저장된 일정을 불러오지 못했어요. 로그인 상태와 네트워크를 확인해 주세요.';
        _isLoading = false;
      });
    }
  }

  String? _resolveUserId() {
    final override = widget.userIdOverride?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return Supabase.instance.client.auth.currentUser?.id;
  }

  List<EventModel> _rankEvents(List<EventModel> events, String rawText) {
    final now = DateTime.now();
    final tokens = _tokens(rawText);
    final ranked = events.map((event) {
      final searchable = [
        event.title,
        event.location ?? '',
        event.memo ?? '',
        event.supplies.join(' '),
      ].join(' ').toLowerCase();
      var matchScore = 0;
      for (final token in tokens) {
        if (searchable.contains(token)) {
          matchScore += token.length >= 3 ? 2 : 1;
        }
      }
      var score = matchScore;
      final startAt = event.startAt;
      if (startAt != null && !startAt.isBefore(now)) {
        score += 1;
      }
      return _RankedEvent(event: event, score: score, matchScore: matchScore);
    }).toList(growable: false);

    ranked.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      final aStart = a.event.startAt;
      final bStart = b.event.startAt;
      if (aStart == null && bStart == null) {
        return 0;
      }
      if (aStart == null) {
        return 1;
      }
      if (bStart == null) {
        return -1;
      }
      return aStart.compareTo(bStart);
    });

    final hasPositiveMatch = ranked.any((item) => item.matchScore > 0);
    final visible = hasPositiveMatch
        ? ranked.where((item) => item.matchScore > 0)
        : ranked.where((item) {
            final startAt = item.event.startAt;
            return startAt == null || !startAt.isBefore(now);
          });

    return visible.map((item) => item.event).take(10).toList(growable: false);
  }

  List<String> _tokens(String text) {
    const stopWords = {
      '일정',
      '수정',
      '수정해',
      '변경',
      '변경해',
      '바꿔',
      '고쳐',
      '삭제',
      '삭제해',
      '지워',
      '지우기',
      '없애',
      '오늘',
      '내일',
      '모레',
      '오전',
      '오후',
      '으로',
      '에서',
      '에게',
      '해줘',
    };
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^0-9a-z가-힣\s]'), ' ')
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= 2 && !stopWords.contains(token))
        .toList(growable: false);
  }

  Future<void> _openEdit(EventModel event) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('수정할 일정을 열었어요. 확인 후 저장해 주세요.')),
    );
    await context.push(
      '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
      extra: event,
    );
  }

  Future<void> _confirmDelete(EventModel event) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('음성으로 일정 삭제'),
        content: Text('"${event.title}" 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      await _deleteEvent(event);
    }
  }

  Future<void> _deleteEvent(EventModel event) async {
    final userId = _resolveUserId();
    if (userId == null) {
      _showMessage('로그인 후 삭제할 수 있어요.');
      return;
    }

    setState(() {
      _isDeleting = true;
    });

    try {
      await _repository.deleteEvent(event.id, userId: userId);
      await widget.sideEffectService.cleanupAfterDelete(event.id);
      await _refreshHomeWidget(userId);
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_event_deleted',
        eventId: event.id,
        startAt: event.startAt,
      );
      if (!mounted) {
        return;
      }
      _showMessage('일정을 삭제했습니다.');
      context.go(AppRoutes.calendar);
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen delete failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('삭제하지 못했어요. 로그인 상태 또는 Supabase 설정을 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  Future<void> _refreshHomeWidget(String userId) async {
    try {
      final now = DateTime.now();
      final events = await _repository.listEvents(userId: userId);
      final nextEvents = events.where((event) {
        final startAt = event.startAt;
        return startAt != null && !startAt.isBefore(now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

      if (nextEvents.isEmpty) {
        await widget.homeWidgetService.updateNextEventData(
          const HomeWidgetNextEventData(title: '예정된 일정이 없어요'),
        );
        return;
      }

      final nextEvent = nextEvents.first;
      await widget.homeWidgetService.updateNextEvent(
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
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen widget refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _isDelete ? '음성으로 일정 삭제' : '음성으로 일정 수정';

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadCandidates,
          child: ListView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              _CommandCard(
                title: title,
                rawText: widget.rawText,
                description: _isDelete
                    ? '말한 내용과 가장 가까운 일정을 골라 삭제할 수 있어요.'
                    : '말한 내용과 가장 가까운 일정을 골라 편집 화면에서 수정해 주세요.',
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_message != null)
                _EmptyCard(message: _message!)
              else ...[
                Text(
                  '후보 일정',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                ..._events.map(
                  (event) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _EventCandidateCard(
                      event: event,
                      actionLabel: _isDelete ? '삭제하기' : '수정하기',
                      actionIcon:
                          _isDelete ? Icons.delete_outline : Icons.edit_note,
                      isDanger: _isDelete,
                      disabled: _isDeleting,
                      onTap: () =>
                          _isDelete ? _confirmDelete(event) : _openEdit(event),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RankedEvent {
  const _RankedEvent({
    required this.event,
    required this.score,
    required this.matchScore,
  });

  final EventModel event;
  final int score;
  final int matchScore;
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({
    required this.title,
    required this.rawText,
    required this.description,
  });

  final String title;
  final String rawText;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '말한 내용',
              style: theme.textTheme.labelLarge?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              rawText.trim().isEmpty ? '내용 없음' : rawText.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _EventCandidateCard extends StatelessWidget {
  const _EventCandidateCard({
    required this.event,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTap,
  });

  final EventModel event;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startAt = event.startAt;

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      startAt == null
                          ? '시간 미정'
                          : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    if ((event.location ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: disabled ? null : onTap,
                icon: Icon(actionIcon),
                label: Text(actionLabel),
                style: FilledButton.styleFrom(
                  foregroundColor: isDanger ? const Color(0xFFB42318) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
