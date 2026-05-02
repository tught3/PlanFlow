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

class EventEditScreen extends StatefulWidget {
  EventEditScreen({
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
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
  late DateTime _startAt;
  DateTime? _endAt;
  late bool _critical;
  EventModel? _loadedEvent;
  bool _isLoading = false;
  bool _isSaving = false;

  bool get _isNewEvent => _loadedEvent == null && _resolvedEventId == null;

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
    final event = widget.event;
    _loadedEvent = event;
    _titleController = TextEditingController(text: event?.title ?? '');
    _locationController = TextEditingController(text: event?.location ?? '');
    _memoController = TextEditingController(text: event?.memo ?? '');
    _suppliesController = TextEditingController(
      text: event?.supplies.join(', ') ?? '',
    );
    _startAt = event?.startAt ?? DateTime.now().add(const Duration(hours: 1));
    _endAt = event?.endAt;
    _critical = event?.isCritical ?? false;
    _loadEventIfNeeded();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _suppliesController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (!AppEnv.isSupabaseReady) {
        _showMessage('Supabase 환경값이 설정되지 않았습니다.');
        return;
      }

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _showMessage('로그인 후 저장할 수 있습니다.');
        return;
      }

      final supplies = _suppliesController.text
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);

      final updatedEvent = EventModel(
        id: _loadedEvent?.id ?? _resolvedEventId ?? '',
        userId: user.id,
        title: _titleController.text.trim(),
        startAt: _startAt,
        endAt: _endAt,
        location: _emptyToNull(_locationController.text),
        memo: _emptyToNull(_memoController.text),
        supplies: supplies,
        isCritical: _critical,
        source: _loadedEvent?.source ?? 'manual',
        externalId: _loadedEvent?.externalId,
        createdAt: _loadedEvent?.createdAt,
      );

      late final EventModel savedEvent;
      if (_isNewEvent) {
        savedEvent = await _repository.createEvent(updatedEvent);
      } else {
        savedEvent = await _repository.updateEvent(updatedEvent);
      }

      final sideEffectResult = await widget.sideEffectService.syncAfterSave(
        event: savedEvent,
        userId: user.id,
      );
      unawaited(_refreshHomeWidget(_repository, savedEvent));

      if (mounted) {
        final actionText = _isNewEvent ? '일정을 만들었습니다.' : '일정을 수정했습니다.';
        final warningText = sideEffectResult.isFullySynced
            ? ''
            : ' 알림 동기화가 일부 실패했습니다. 설정을 확인해 주세요.';
        _showMessage('$actionText$warningText');
        EventRefreshBus.instance.notifyChanged(
          reason: _isNewEvent ? 'event_created' : 'event_updated',
          eventId: savedEvent.id,
          startAt: savedEvent.startAt,
        );
        context.go(AppRoutes.calendar);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('저장하지 못했습니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _loadEventIfNeeded() async {
    final eventId = _resolvedEventId;
    if (_loadedEvent != null || eventId == null || !AppEnv.isSupabaseReady) {
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _showMessage('로그인 후 일정 정보를 불러올 수 있습니다.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final event = await _repository.fetchEvent(
        eventId,
        userId: user.id,
      );
      if (!mounted) {
        return;
      }
      if (event == null) {
        _showMessage('수정할 일정을 찾지 못했습니다.');
        return;
      }
      setState(() {
        _loadedEvent = event;
        _titleController.text = event.title;
        _locationController.text = event.location ?? '';
        _memoController.text = event.memo ?? '';
        _suppliesController.text = event.supplies.join(', ');
        _startAt = event.startAt ?? _startAt;
        _endAt = event.endAt;
        _critical = event.isCritical;
      });
    } catch (_) {
      if (mounted) {
        _showMessage('일정 정보를 불러오지 못했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
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
      final nextEvent = nextEvents.isEmpty ? fallbackEvent : nextEvents.first;
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
    } catch (_) {
      // Widget refresh should not block event saves.
    }
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: Text(_isNewEvent ? '일정 만들기' : '일정 편집'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              Text(
                _isLoading
                    ? '일정 정보를 불러오는 중입니다.'
                    : _isNewEvent
                        ? '새 일정의 정보를 입력해 주세요.'
                        : '필요한 정보만 수정하고 저장해 주세요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
              if (_isLoading) ...[
                const SizedBox(height: AppConstants.sectionSpacing),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: '제목'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? '제목을 입력해 주세요.'
                    : null,
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
              TextFormField(
                controller: _locationController,
                decoration: const InputDecoration(labelText: '장소'),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _memoController,
                decoration: const InputDecoration(
                  labelText: '메모',
                  alignLabelWithHint: true,
                ),
                minLines: 3,
                maxLines: 5,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _suppliesController,
                decoration: const InputDecoration(
                  labelText: '준비물',
                  helperText: '쉼표로 구분해서 입력해 주세요.',
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              SwitchListTile.adaptive(
                tileColor: PlanFlowColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(
                    color: PlanFlowColors.primaryFaint,
                    width: 0.5,
                  ),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                title: const Text('중요 일정'),
                subtitle: const Text('긴급 알림을 함께 예약합니다.'),
                value: _critical,
                onChanged: (value) {
                  setState(() {
                    _critical = value;
                  });
                },
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _isSaving ? null : _handleSave,
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_isSaving ? '저장 중...' : '저장'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.pop(),
                child: const Text('취소'),
              ),
            ],
          ),
        ),
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
        ? emptyLabel ?? '설정 안 함'
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
