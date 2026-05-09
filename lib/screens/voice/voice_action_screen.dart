import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/home_widget_service.dart';
import '../../services/manual_event_side_effect_service.dart';

enum VoiceScheduleAction { add, edit, delete, query, choose }

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
  bool _hasChosenAction = false;

  late VoiceScheduleAction _selectedAction;

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  bool get _isDelete => _selectedAction == VoiceScheduleAction.delete;
  bool get _isEdit => _selectedAction == VoiceScheduleAction.edit;
  bool get _isAdd => _selectedAction == VoiceScheduleAction.add;
  bool get _isQuery => _selectedAction == VoiceScheduleAction.query;
  bool get _isChoose => _selectedAction == VoiceScheduleAction.choose;

  @override
  void initState() {
    super.initState();
    _selectedAction = widget.action;
    unawaited(_loadCandidates());
  }

  String _actionTitle() {
    switch (_selectedAction) {
      case VoiceScheduleAction.add:
        return '음성으로 일정 추가';
      case VoiceScheduleAction.edit:
        return '음성으로 일정 수정';
      case VoiceScheduleAction.delete:
        return '음성으로 일정 삭제';
      case VoiceScheduleAction.query:
        return '음성으로 일정 조회';
      case VoiceScheduleAction.choose:
        return '음성으로 일정 관리';
    }
  }

  String _actionDescription() {
    switch (_selectedAction) {
      case VoiceScheduleAction.add:
        return '인식된 내용을 바로 저장하지 않고, 확인 화면으로 먼저 보냅니다.';
      case VoiceScheduleAction.edit:
        return '말한 내용과 가장 가까운 일정을 고른 뒤 편집 화면에서 다시 확인해 주세요.';
      case VoiceScheduleAction.delete:
        return '말한 내용과 가장 가까운 일정을 고른 뒤 삭제를 다시 확인해 주세요.';
      case VoiceScheduleAction.query:
        return 'DB에서 직접 일정을 찾아 카드로 보여드립니다.';
      case VoiceScheduleAction.choose:
        return '무엇을 할지 먼저 고른 뒤 그에 맞는 일정 후보를 확인해 주세요.';
    }
  }

  String _candidateActionLabel() {
    if (_isDelete) {
      return '삭제하기';
    }
    if (_isEdit) {
      return '수정하기';
    }
    return '상세 보기';
  }

  IconData _candidateActionIcon() {
    if (_isDelete) {
      return Icons.delete_outline;
    }
    if (_isEdit) {
      return Icons.edit_note;
    }
    return Icons.visibility_outlined;
  }

  Future<void> _openAddConfirm() async {
    await _recordVoiceLog(
      action: 'add',
      result: 'confirm_opened',
    );
    if (!mounted) {
      return;
    }
    final parsed = <String, dynamic>{
      'raw_text': widget.rawText,
      'memo': widget.rawText,
      'parse_pending': true,
    };
    await context.push(AppRoutes.confirm, extra: parsed);
  }

  Future<void> _openQueryResult(EventModel event) async {
    await _recordVoiceLog(
      action: 'query',
      targetEventId: event.id,
      result: 'opened',
    );
    if (!mounted) {
      return;
    }
    await context.push(
      '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
      extra: event,
    );
  }

  Future<void> _loadCandidates() async {
    if (_isAdd) {
      setState(() {
        _events.clear();
        _message = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final userId = _resolveUserId();
      if (userId == null) {
        setState(() {
          _message = '로그인 후 음성으로 일정을 관리할 수 있어요.';
          _isLoading = false;
        });
        return;
      }

      if (!AppEnv.isSupabaseReady && widget.eventRepository == null) {
        setState(() {
          _message = 'Supabase 설정이 없어 저장된 일정을 불러올 수 없어요.';
          _isLoading = false;
        });
        return;
      }

      final events = await _repository.listEvents(userId: userId);
      final filteredEvents = _filterEventsForAction(events);
      final ranked = _rankEvents(filteredEvents, widget.rawText);
      if (!mounted) {
        return;
      }
      setState(() {
        _events
          ..clear()
          ..addAll(ranked);
        _message = _emptyMessageForAction(ranked);
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '저장된 일정을 불러오지 못했어요. 로그인 상태와 스토리지를 확인해 주세요.';
        _isLoading = false;
      });
    }
  }

  Future<void> _selectAction(VoiceScheduleAction action) async {
    setState(() {
      _selectedAction = action;
      _hasChosenAction = true;
      _events.clear();
      _message = action == VoiceScheduleAction.add ? '일정 확인 화면으로 이동합니다.' : null;
      _isLoading = action != VoiceScheduleAction.add;
    });

    if (action == VoiceScheduleAction.add) {
      await _openAddConfirm();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    await _loadCandidates();
  }

  List<EventModel> _filterEventsForAction(List<EventModel> events) {
    if (!_isQuery) {
      return events;
    }

    final range = _queryDateRange(widget.rawText);
    if (range == null) {
      return events;
    }

    return events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final localStart = planflowLocal(startAt);
      return !localStart.isBefore(range.start) &&
          localStart.isBefore(range.end);
    }).toList(growable: false);
  }

  String? _emptyMessageForAction(List<EventModel> ranked) {
    if (ranked.isNotEmpty) {
      return null;
    }
    if (!_isQuery) {
      return '조건에 맞는 일정을 찾지 못했어요. 아래에서 새 일정으로 추가하거나 다시 말해 주세요.';
    }

    final rangeLabel = _queryRangeLabel(widget.rawText);
    return '$rangeLabel 일정은 아직 없어요. 새 일정이 필요하면 “추가”로 바로 등록할 수 있습니다.';
  }

  _DateRange? _queryDateRange(String rawText) {
    final normalized = rawText.replaceAll(RegExp(r'\s+'), ' ');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (normalized.contains('내일')) {
      final start = today.add(const Duration(days: 1));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (normalized.contains('모레')) {
      final start = today.add(const Duration(days: 2));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (RegExp(r'(이번\s*주|이번주|주간)').hasMatch(normalized)) {
      final start = today.subtract(Duration(days: today.weekday - 1));
      return _DateRange(start, start.add(const Duration(days: 7)));
    }
    if (normalized.contains('오늘')) {
      return _DateRange(today, today.add(const Duration(days: 1)));
    }
    return null;
  }

  String _queryRangeLabel(String rawText) {
    final normalized = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.contains('내일')) {
      return '내일';
    }
    if (normalized.contains('모레')) {
      return '모레';
    }
    if (RegExp(r'(이번\s*주|이번주|주간)').hasMatch(normalized)) {
      return '이번 주';
    }
    if (normalized.contains('오늘')) {
      return '오늘';
    }
    return '다가오는';
  }

  String _querySummaryText(List<EventModel> events) {
    final rangeLabel = _queryRangeLabel(widget.rawText);
    if (events.isEmpty) {
      return '$rangeLabel 일정은 아직 없습니다.';
    }

    return '$rangeLabel 일정은 ${events.length}개입니다.';
  }

  List<_QueryDayGroup> _buildQueryTimeline(List<EventModel> events) {
    final ordered = [...events]..sort((a, b) {
        final aStart = a.startAt;
        final bStart = b.startAt;
        if (aStart == null && bStart == null) {
          return a.title.compareTo(b.title);
        }
        if (aStart == null) {
          return 1;
        }
        if (bStart == null) {
          return -1;
        }
        final compare = aStart.compareTo(bStart);
        if (compare != 0) {
          return compare;
        }
        return a.title.compareTo(b.title);
      });

    final grouped = <DateTime, List<EventModel>>{};
    final nullStartEvents = <EventModel>[];
    for (final event in ordered) {
      final startAt = event.startAt;
      if (startAt == null) {
        nullStartEvents.add(event);
        continue;
      }
      final dayKey = planflowLocalDay(startAt);
      grouped.putIfAbsent(dayKey, () => <EventModel>[]).add(event);
    }

    final dayGroups = grouped.entries.map((entry) {
      final buckets = <String, List<EventModel>>{
        '오전': <EventModel>[],
        '오후': <EventModel>[],
        '저녁': <EventModel>[],
        '시간 미정': <EventModel>[],
      };

      for (final event in entry.value) {
        final label = _queryBucketLabel(event.startAt);
        buckets.putIfAbsent(label, () => <EventModel>[]).add(event);
      }

      return _QueryDayGroup(
        label: _koreanDateLabel(entry.key),
        events: entry.value,
        buckets: buckets.entries
            .where((bucket) => bucket.value.isNotEmpty)
            .map((bucket) => MapEntry(bucket.key, bucket.value))
            .toList(growable: false),
      );
    }).toList(growable: false);

    if (nullStartEvents.isNotEmpty) {
      dayGroups.add(
        _QueryDayGroup(
          label: '시간 미정',
          events: nullStartEvents,
          buckets: <MapEntry<String, List<EventModel>>>[
            MapEntry<String, List<EventModel>>('시간 미정', nullStartEvents),
          ],
        ),
      );
    }

    return dayGroups;
  }

  String _queryBucketLabel(DateTime? value) {
    if (value == null) {
      return '시간 미정';
    }
    final local = planflowLocal(value);
    if (local.hour < 12) {
      return '오전';
    }
    if (local.hour < 18) {
      return '오후';
    }
    return '저녁';
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

    return ranked.map((item) => item.event).take(10).toList(growable: false);
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
      '추가',
      '등록',
      '보여',
      '찾아',
      '조회',
      '오늘',
      '내일',
      '모레',
      '이번',
      '이번주',
      '이번 주',
      '무엇',
      '뭐',
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
    await _recordVoiceLog(
      action: 'edit',
      targetEventId: event.id,
      result: 'opened',
    );
    if (!mounted) {
      return;
    }
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
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: const Color(0xFFB42318),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('삭제'),
                ),
              ),
            ],
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
      if (!mounted) {
        return;
      }
      await _recordVoiceLog(
        action: 'delete',
        targetEventId: event.id,
        result: 'deleted',
      );
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
          const HomeWidgetNextEventData(title: '다가올 일정이 없어요'),
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

  Future<void> _recordVoiceLog({
    required String action,
    String? targetEventId,
    required String result,
  }) async {
    if (!AppEnv.isSupabaseReady) {
      return;
    }

    final userId = _resolveUserId();
    if (userId == null) {
      return;
    }

    try {
      await Supabase.instance.client
          .from('voice_logs')
          .insert(<String, dynamic>{
        'user_id': userId,
        'event_id': targetEventId,
        'raw_text': widget.rawText,
        'parsed_json': <String, dynamic>{
          'action': action,
          'target_event_id': targetEventId,
          'result': result,
        },
      });
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen voice log save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _actionTitle();
    final description = _actionDescription();

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadCandidates,
          child: ListView(
            cacheExtent: 1200,
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              _CommandCard(
                title: title,
                rawText: widget.rawText,
                description: description,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              if (_isChoose || _hasChosenAction) ...[
                _ActionChooserCard(
                  currentAction: _selectedAction,
                  onSelected: _selectAction,
                ),
                const SizedBox(height: 12),
              ],
              if (_isAdd) ...[
                _AddConfirmCard(
                  rawText: widget.rawText,
                  onContinue: _openAddConfirm,
                ),
                const SizedBox(height: 12),
              ],
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_message != null)
                _EmptyCard(
                  message: _message!,
                  rawText: widget.rawText,
                  showRecoveryActions: !_isAdd,
                  onAdd: _openAddConfirm,
                  onRetryVoice: () => context.go(AppRoutes.voice),
                  onOpenCalendar: () => context.go(AppRoutes.calendar),
                )
              else ...[
                Text(
                  _isQuery ? '단순 조회 결과' : '대상 일정',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                if (_isQuery) ...[
                  _QueryOverviewCard(
                    summary: _querySummaryText(_events),
                    rangeLabel: _queryRangeLabel(widget.rawText),
                  ),
                  const SizedBox(height: 12),
                  ..._buildQueryTimeline(_events).map(
                    (dayGroup) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _QueryDayGroupCard(
                        dayGroup: dayGroup,
                        actionLabel: _candidateActionLabel(),
                        actionIcon: _candidateActionIcon(),
                        isDanger: _isDelete,
                        disabled: _isDeleting,
                        onTapEvent: (event) => _openQueryResult(event),
                      ),
                    ),
                  ),
                ] else ...[
                  ..._events.map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _EventCandidateCard(
                        event: event,
                        actionLabel: _candidateActionLabel(),
                        actionIcon: _candidateActionIcon(),
                        isDanger: _isDelete,
                        disabled: _isDeleting,
                        onTap: () => _isDelete
                            ? _confirmDelete(event)
                            : _isEdit
                                ? _openEdit(event)
                                : _openQueryResult(event),
                      ),
                    ),
                  ),
                ],
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

class _DateRange {
  const _DateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;
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
              rawText.trim().isEmpty ? '내용이 비어 있어요.' : rawText.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroup {
  const _QueryDayGroup({
    required this.label,
    required this.events,
    required this.buckets,
  });

  final String label;
  final List<EventModel> events;
  final List<MapEntry<String, List<EventModel>>> buckets;
}

class _QueryOverviewCard extends StatelessWidget {
  const _QueryOverviewCard({
    required this.summary,
    required this.rangeLabel,
  });

  final String summary;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: const Color(0xFFEAF4FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF92BEE8), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.record_voice_over_outlined,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$rangeLabel 일정 요약',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textPrimary,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroupCard extends StatelessWidget {
  const _QueryDayGroupCard({
    required this.dayGroup,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final _QueryDayGroup dayGroup;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

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
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    dayGroup.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${dayGroup.events.length}개',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...dayGroup.buckets.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _QueryBucketSection(
                  label: entry.key,
                  events: entry.value,
                  actionLabel: actionLabel,
                  actionIcon: actionIcon,
                  isDanger: isDanger,
                  disabled: disabled,
                  onTapEvent: onTapEvent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryBucketSection extends StatelessWidget {
  const _QueryBucketSection({
    required this.label,
    required this.events,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final String label;
  final List<EventModel> events;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primaryMid,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
        ...events.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _QueryEventCard(
              event: event,
              actionLabel: actionLabel,
              actionIcon: actionIcon,
              isDanger: isDanger,
              disabled: disabled,
              onTap: () => onTapEvent(event),
            ),
          ),
        ),
      ],
    );
  }
}

class _QueryEventCard extends StatelessWidget {
  const _QueryEventCard({
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
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeStr = _formatTimeChip(startAt);

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
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    timeStr,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
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
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      startAt == null
                          ? '시간 미정'
                          : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    if ((event.location ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

  String _formatTimeChip(DateTime? value) {
    if (value == null) {
      return '미정';
    }
    final hour = value.hour;
    final period = hour < 12
        ? '오전'
        : hour < 18
            ? '오후'
            : '저녁';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    final minute =
        value.minute == 0 ? '' : '\n${value.minute.toString().padLeft(2, '0')}';
    return '$period\n$displayHour시$minute';
  }
}

class _AddConfirmCard extends StatelessWidget {
  const _AddConfirmCard({
    required this.rawText,
    required this.onContinue,
  });

  final String rawText;
  final VoidCallback onContinue;

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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '일정 추가 확인',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '음성 원문을 확인한 뒤 일정 확인 화면으로 넘겨드립니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onContinue,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('확인 화면으로 이동'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChooserCard extends StatelessWidget {
  const _ActionChooserCard({
    required this.currentAction,
    required this.onSelected,
  });

  final VoiceScheduleAction currentAction;
  final ValueChanged<VoiceScheduleAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = <(VoiceScheduleAction, String, IconData)>[
      (VoiceScheduleAction.add, '추가', Icons.add_circle_outline),
      (VoiceScheduleAction.edit, '수정', Icons.edit_note),
      (VoiceScheduleAction.delete, '삭제', Icons.delete_outline),
      (VoiceScheduleAction.query, '조회', Icons.search),
    ];

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
              '무엇을 할까요?',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ...options.map((option) {
              final selected = currentAction == option.$1;
              final button = selected
                  ? FilledButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    );
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: button,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.message,
    this.rawText,
    this.showRecoveryActions = false,
    this.onAdd,
    this.onRetryVoice,
    this.onOpenCalendar,
  });

  final String message;
  final String? rawText;
  final bool showRecoveryActions;
  final VoidCallback? onAdd;
  final VoidCallback? onRetryVoice;
  final VoidCallback? onOpenCalendar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            if (showRecoveryActions) ...[
              const SizedBox(height: 12),
              if (rawText != null && rawText!.trim().isNotEmpty)
                Text(
                  '말한 내용: ${rawText!.trim()}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('새 일정으로 추가'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onRetryVoice,
                    icon: const Icon(Icons.mic_none),
                    label: const Text('다시 말하기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenCalendar,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('일정 탭 보기'),
                  ),
                ],
              ),
            ],
          ],
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
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);

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
