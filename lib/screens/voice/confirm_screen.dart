import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../services/home_widget_service.dart';
import '../../services/notification_service.dart';

class ConfirmScreen extends StatefulWidget {
  ConfirmScreen({
    super.key,
    this.parsedSchedule = const <String, dynamic>{},
    this.userId,
    this.eventRepository,
    ConfirmScreenBackend? backend,
    NotificationService? notificationService,
    HomeWidgetService? homeWidgetService,
  })  : backend = backend ?? const SupabaseConfirmScreenBackend(),
        notificationService = notificationService ?? NotificationService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final Map<String, dynamic> parsedSchedule;
  final String? userId;
  final EventRepository? eventRepository;
  final ConfirmScreenBackend backend;
  final NotificationService notificationService;
  final HomeWidgetService homeWidgetService;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

abstract class ConfirmScreenBackend {
  const ConfirmScreenBackend();

  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  });

  Future<void> insertPreActions(List<Map<String, dynamic>> payloads);

  Future<void> insertReminders(List<Map<String, dynamic>> payloads);

  Future<void> insertLocationHistory(Map<String, dynamic> payload);

  Future<void> insertVoiceLog(Map<String, dynamic> payload);
}

class SupabaseConfirmScreenBackend extends ConfirmScreenBackend {
  const SupabaseConfirmScreenBackend();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async {
    final response = await _client
        .from('location_history')
        .select('supplies, visited_at')
        .eq('user_id', userId)
        .eq('location', location)
        .order('visited_at', ascending: false)
        .limit(10);

    final supplies = <String>[];
    final seen = <String>{};

    for (final row in response as List<dynamic>) {
      final rowMap = Map<String, dynamic>.from(row as Map);
      final rowSupplies = rowMap['supplies'];
      if (rowSupplies is! List) {
        continue;
      }

      for (final item in rowSupplies) {
        final supply = item.toString().trim();
        if (supply.isEmpty || seen.contains(supply)) {
          continue;
        }
        seen.add(supply);
        supplies.add(supply);
      }
    }

    return supplies;
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('pre_actions').insert(payloads);
  }

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('reminders').insert(payloads);
  }

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {
    await _client.from('location_history').insert(payload);
  }

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {
    await _client.from('voice_logs').insert(payload);
  }
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _newSupplyController;
  late final List<String> _supplies;
  late final List<_PreActionDraft> _preActions;
  late DateTime _startAt;
  DateTime? _endAt;
  late bool _isCritical;
  bool _isSaving = false;
  bool _isLoadingPastSupplies = false;
  List<String> _pastSupplies = const <String>[];
  Timer? _locationDebounce;
  bool _hasFollowUpFailures = false;

  bool get _parseFailed => widget.parsedSchedule['parse_failed'] == true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['title']) ?? '',
    );
    _locationController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['location']) ?? '',
    );
    _memoController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['memo']) ??
          _stringValue(widget.parsedSchedule['raw_text']),
    );
    _newSupplyController = TextEditingController();
    _supplies = _stringListValue(widget.parsedSchedule['supplies']);
    _preActions = _initialPreActions();
    _startAt = _dateTimeValue(widget.parsedSchedule['start_at']) ??
        DateTime.now().add(const Duration(hours: 1));
    _endAt = _dateTimeValue(widget.parsedSchedule['end_at']);
    _isCritical = widget.parsedSchedule['is_critical'] == true;
    _locationController.addListener(_schedulePastSupplyLookup);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPastSupplies();
    });
  }

  @override
  void dispose() {
    _locationDebounce?.cancel();
    _locationController.removeListener(_schedulePastSupplyLookup);
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _newSupplyController.dispose();
    for (final draft in _preActions) {
      draft.dispose();
    }
    super.dispose();
  }

  void _schedulePastSupplyLookup() {
    _locationDebounce?.cancel();
    _locationDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _loadPastSupplies();
      }
    });
  }

  Future<void> _loadPastSupplies() async {
    final location = _locationController.text.trim();
    final userId = _resolveUserId();
    if (location.isEmpty || userId == null) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
          _isLoadingPastSupplies = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingPastSupplies = true;
      });
    }

    try {
      final pastSupplies = await widget.backend.fetchPastSupplies(
        userId: userId,
        location: location,
      );
      if (!mounted || location != _locationController.text.trim()) {
        return;
      }
      setState(() {
        _pastSupplies = pastSupplies;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPastSupplies = false;
        });
      }
    }
  }

  String? _resolveUserId() {
    final userId =
        widget.userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      return null;
    }
    return userId.trim();
  }

  EventRepository? _resolveEventRepository() {
    if (widget.eventRepository != null) {
      return widget.eventRepository;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return EventRepository.supabase();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showMessage('제목을 입력해 주세요.');
      return;
    }

    final userId = _resolveUserId();
    if (userId == null) {
      _showMessage('로그인이 필요합니다.');
      return;
    }

    final repository = _resolveEventRepository();
    if (repository == null) {
      _showMessage('Supabase 환경이 설정되지 않아 저장할 수 없어요.');
      if (mounted) {
        context.go(AppRoutes.home);
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final savedEvent = await repository.createEvent(
        EventModel(
          id: '',
          userId: userId,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          location: _emptyToNull(_locationController.text),
          memo: _emptyToNull(_memoController.text),
          supplies: List<String>.unmodifiable(_supplies),
          isCritical: _isCritical,
        ),
      );

      await _saveRelatedRecords(
        userId: userId,
        event: savedEvent,
      );
      await _updateHomeWidget(repository, savedEvent);

      if (mounted) {
        _showMessage(
          '일정을 저장했어요${_hasFollowUpFailures ? ', 일부 후속 저장은 다시 시도해 주세요.' : '.'}',
        );
        context.go(AppRoutes.home);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('저장하지 못했어요. 로그인과 Supabase 설정을 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _saveRelatedRecords({
    required String userId,
    required EventModel event,
  }) async {
    _hasFollowUpFailures = false;
    final eventStartAt = event.startAt ?? _startAt;
    final preActionPayloads = _buildPreActionPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );
    final reminderPayloads = _buildReminderPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );

    await _tryFollowUp(
      () => widget.backend.insertPreActions(preActionPayloads),
    );
    await _tryFollowUp(
      () => widget.backend.insertReminders(reminderPayloads),
    );

    final location = _emptyToNull(_locationController.text);
    if (location != null) {
      await _tryFollowUp(
        () => widget.backend.insertLocationHistory(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'location': location,
          'supplies': event.supplies,
        }),
      );
    }

    final rawText = _stringValue(widget.parsedSchedule['raw_text']);
    if (rawText != null) {
      await _tryFollowUp(
        () => widget.backend.insertVoiceLog(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'raw_text': rawText,
          'parsed_json': widget.parsedSchedule,
        }),
      );
    }

    final eventReminderNotifyAt =
        eventStartAt.subtract(const Duration(minutes: 60));
    final criticalAlarmNotifyAt =
        eventStartAt.subtract(const Duration(minutes: 30));
    await _tryFollowUp(
      () => widget.notificationService.scheduleEventReminder(
        id: widget.notificationService.notificationIdFor('${event.id}:push'),
        title: event.title,
        body: '이벤트 시작: ${event.title}',
        notifyAt: eventReminderNotifyAt,
      ),
    );

    if (_isCritical) {
      await _tryFollowUp(
        () => widget.notificationService.scheduleCriticalAlarm(
          id: widget.notificationService
              .notificationIdFor('${event.id}:critical'),
          title: event.title,
          notifyAt: criticalAlarmNotifyAt,
          body: '중요 일정이 곧 시작됩니다.',
        ),
      );
    }
  }

  Future<void> _tryFollowUp(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _hasFollowUpFailures = true;
    }
  }

  List<Map<String, dynamic>> _buildPreActionPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    return _preActions
        .map((draft) {
          final title = draft.titleController.text.trim();
          if (title.isEmpty) {
            return null;
          }

          final offsetHours =
              int.tryParse(draft.offsetController.text.trim()) ?? 1;
          final notifyAt = eventStartAt.subtract(
            Duration(hours: offsetHours < 0 ? 0 : offsetHours),
          );

          return <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': title,
            'notify_at': notifyAt.toIso8601String(),
            'is_done': false,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _buildReminderPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    final payloads = <Map<String, dynamic>>[
      _reminderPayload(
        userId: userId,
        eventId: eventId,
        type: 'push',
        notifyAt: eventStartAt.subtract(const Duration(minutes: 60)),
      ),
    ];

    if (_isCritical) {
      payloads.add(
        _reminderPayload(
          userId: userId,
          eventId: eventId,
          type: 'system_alarm',
          notifyAt: eventStartAt.subtract(const Duration(minutes: 30)),
        ),
      );
    }

    return payloads;
  }

  Future<void> _updateHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
    try {
      final nextEvent = await _resolveNextEvent(repository) ?? fallbackEvent;
      await widget.homeWidgetService.updateNextEvent(
        title: nextEvent.title,
        eventId: nextEvent.id,
        startAt: nextEvent.startAt,
        location: nextEvent.location,
        isCritical: nextEvent.isCritical,
      );
    } catch (_) {}
  }

  Future<EventModel?> _resolveNextEvent(EventRepository repository) async {
    final userId = _resolveUserId();
    if (userId == null) {
      return null;
    }

    final now = DateTime.now();
    final events = await repository.listEvents(userId: userId);
    final remainingToday = events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return startAt.year == now.year &&
          startAt.month == now.month &&
          startAt.day == now.day &&
          !startAt.isBefore(now);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    if (remainingToday.isEmpty) {
      return null;
    }
    return remainingToday.first;
  }

  Future<void> _addSupplyFromInput() async {
    final supply = _newSupplyController.text.trim();
    if (supply.isEmpty) {
      return;
    }

    setState(() {
      _addSupply(supply);
      _newSupplyController.clear();
    });
  }

  void _addSupply(String supply) {
    if (_supplies.contains(supply)) {
      return;
    }
    _supplies.add(supply);
  }

  void _removeSupply(String supply) {
    setState(() {
      _supplies.remove(supply);
    });
  }

  void _addPreAction() {
    setState(() {
      _preActions.add(_PreActionDraft.manual());
    });
  }

  void _removePreAction(_PreActionDraft draft) {
    setState(() {
      _preActions.remove(draft);
      draft.dispose();
    });
  }

  void _applyPastSupply(String supply) {
    setState(() {
      _addSupply(supply);
    });
  }

  List<_PreActionDraft> _initialPreActions() {
    final rawPreActions = widget.parsedSchedule['pre_actions'];
    if (rawPreActions is! List) {
      return <_PreActionDraft>[];
    }

    return rawPreActions
        .whereType<Map>()
        .map(
          (item) => _PreActionDraft.auto(
            title: _stringValue(item['title']),
            offsetHours: _intValue(item['offset_hours']) ?? 1,
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _reminderPayload({
    required String userId,
    required String eventId,
    required String type,
    required DateTime notifyAt,
  }) {
    return <String, dynamic>{
      'event_id': eventId,
      'user_id': userId,
      'type': type,
      'notify_at': notifyAt.toIso8601String(),
      'is_sent': false,
    };
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = _locationController.text.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('일정 확인')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: PlanFlowColors.briefing,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'GPT가 정리한 내용을 확인하고 바로 저장할 수 있어요. 필요한 항목은 지금 수정해도 됩니다.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            if (_parseFailed)
              Card(
                color: theme.colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(AppConstants.defaultPadding),
                  child: Text(
                    '자동 파싱에 실패했어요. 내용을 확인하고 직접 입력해 주세요.',
                  ),
                ),
              ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '제목',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: '장소',
                helperText: '같은 장소의 과거 준비물을 아래에서 다시 쓸 수 있어요.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            if (_isLoadingPastSupplies)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else if (_pastSupplies.isNotEmpty && location.isNotEmpty) ...[
              _SuggestionsCard(
                title: '같은 장소의 준비물',
                subtitle: '이전 일정에서 자주 쓰던 준비물을 눌러 바로 추가할 수 있어요.',
                chips: _pastSupplies
                    .map(
                      (supply) => ActionChip(
                        label: Text(supply),
                        onPressed: () => _applyPastSupply(supply),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
            ],
            _SuppliesEditor(
              supplies: _supplies,
              newSupplyController: _newSupplyController,
              onAdd: _addSupplyFromInput,
              onRemove: _removeSupply,
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _SectionHeader(
              title: '선행행동',
              actionLabel: '추가',
              onAction: _addPreAction,
            ),
            const SizedBox(height: 8),
            if (_preActions.isEmpty)
              _EmptyInlineHint(
                message: '선행행동이 없어요. 준비물 정리, 출발 준비 같은 항목을 추가해 보세요.',
                actionLabel: '선행행동 추가',
                onAction: _addPreAction,
              )
            else
              ..._preActions.asMap().entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PreActionEditorCard(
                        draft: entry.value,
                        index: entry.key + 1,
                        onDelete: () => _removePreAction(entry.value),
                      ),
                    ),
                  ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _DateTimeTile(
              label: '시작 시간',
              value: _startAt,
              onTap: () async {
                final picked = await _pickDateTime(_startAt);
                if (picked != null) {
                  setState(() {
                    _startAt = picked;
                    if (_endAt != null && _endAt!.isBefore(_startAt)) {
                      _endAt = null;
                    }
                  });
                }
              },
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _DateTimeTile(
              label: '종료 시간',
              value: _endAt,
              emptyLabel: '종료 시간 없음',
              onTap: () async {
                final picked = await _pickDateTime(_endAt ?? _startAt);
                if (picked != null) {
                  setState(() {
                    _endAt = picked;
                  });
                }
              },
              trailing: _endAt == null
                  ? null
                  : IconButton(
                      tooltip: '종료 시간 지우기',
                      onPressed: () {
                        setState(() {
                          _endAt = null;
                        });
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(
                labelText: '메모',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            SwitchListTile(
              value: _isCritical,
              onChanged: (value) {
                setState(() {
                  _isCritical = value;
                });
              },
              title: const Text('중요 알림'),
              subtitle: const Text('중요 일정이면 더 강한 알림에 함께 등록돼요.'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isSaving ? '저장 중' : '일정 저장'),
            ),
          ],
        ),
      ),
    );
  }

  String? _stringValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  String? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  List<String> _stringListValue(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  DateTime? _dateTimeValue(Object? value) {
    final text = _stringValue(value);
    if (text == null) {
      return null;
    }
    return DateTime.tryParse(text);
  }

  int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  Future<DateTime?> _pickDateTime(DateTime initialValue) async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialValue,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (pickedDate == null || !mounted) {
      return null;
    }

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialValue),
    );
    if (pickedTime == null) {
      return null;
    }

    return DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
  }
}

class _PreActionDraft {
  _PreActionDraft.auto({
    String? title,
    int? offsetHours,
  })  : isAuto = true,
        titleController = TextEditingController(text: title ?? ''),
        offsetController = TextEditingController(
          text: (offsetHours ?? 1).toString(),
        );

  _PreActionDraft.manual()
      : isAuto = false,
        titleController = TextEditingController(),
        offsetController = TextEditingController(text: '1');

  final bool isAuto;
  final TextEditingController titleController;
  final TextEditingController offsetController;

  void dispose() {
    titleController.dispose();
    offsetController.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add, size: 18),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

class _SuppliesEditor extends StatelessWidget {
  const _SuppliesEditor({
    required this.supplies,
    required this.newSupplyController,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> supplies;
  final TextEditingController newSupplyController;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '준비물',
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '칩으로 추가하거나 과거 장소 준비물을 눌러 바로 넣을 수 있어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            if (supplies.isEmpty)
              Text(
                '아직 준비물이 없어요. 아래에서 하나씩 추가해 보세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: supplies
                    .map(
                      (supply) => InputChip(
                        label: Text(supply),
                        onDeleted: () => onRemove(supply),
                        deleteIconColor: PlanFlowColors.primaryMid,
                        side: const BorderSide(
                          color: PlanFlowColors.primaryFaint,
                          width: 0.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: newSupplyController,
                    decoration: const InputDecoration(
                      labelText: '준비물 추가',
                      hintText: '예: 충전기',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => onAdd(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onAdd,
                  child: const Text('추가'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionsCard extends StatelessWidget {
  const _SuggestionsCard({
    required this.title,
    required this.subtitle,
    required this.chips,
  });

  final String title;
  final String subtitle;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: chips,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreActionEditorCard extends StatelessWidget {
  const _PreActionEditorCard({
    required this.draft,
    required this.index,
    required this.onDelete,
  });

  final _PreActionDraft draft;
  final int index;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(draft.isAuto ? '자동' : '수동'),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(
                    color: PlanFlowColors.primaryFaint,
                    width: 0.5,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('삭제'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '선행행동 $index',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: draft.titleController,
              decoration: const InputDecoration(
                labelText: '행동 이름',
                hintText: '예: 준비물 다시 확인',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: draft.offsetController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '몇 시간 전',
                helperText: '예: 2는 시작 2시간 전',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyInlineHint extends StatelessWidget {
  const _EmptyInlineHint({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _DateTimeTile extends StatelessWidget {
  const _DateTimeTile({
    required this.label,
    required this.value,
    required this.onTap,
    this.emptyLabel,
    this.trailing,
  });

  final String label;
  final DateTime? value;
  final String? emptyLabel;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = value == null
        ? emptyLabel ?? '미설정'
        : MaterialLocalizations.of(context).formatFullDate(value!);
    final time = value == null
        ? null
        : MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(value!),
          );

    return ListTile(
      tileColor: PlanFlowColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      title: Text(label),
      subtitle: Text(time == null ? text : '$text · $time'),
      trailing: trailing ??
          const Icon(Icons.edit_calendar, color: PlanFlowColors.primaryMid),
      onTap: onTap,
    );
  }
}
