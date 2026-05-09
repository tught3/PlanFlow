import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/event_metadata.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../location/location_pick_flow.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/event_preparation_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../widgets/recurrence_selector.dart';
import '../../widgets/reminder_offset_selector.dart';

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
  double? _locationLat;
  double? _locationLng;
  late bool _critical;
  late RecurrenceSelection _recurrenceSelection;
  bool _isAllDay = false;
  bool _isMultiDay = false;
  String _category = '기타';
  Duration? _reminderOffset = ReminderOffsetSelector.defaultValue;
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

  DateTime _eventRangeEnd(DateTime startAt, DateTime? endAt) {
    if (endAt != null && endAt.isAfter(startAt)) {
      return endAt;
    }
    if (_isAllDay || _isMultiDay) {
      return startAt.add(const Duration(days: 1));
    }
    return startAt.add(const Duration(minutes: 30));
  }

  Future<bool> _showOverlapWarning(List<EventModel> overlappingEvents) {
    final count = overlappingEvents.length;
    final message = count == 1
        ? '기존 일정 1개와 시간이 겹칩니다.\n계속 저장할까요?'
        : '기존 일정 $count개와 시간이 겹칩니다.\n계속 저장할까요?';
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('일정이 겹쳐요'),
        content: Text(message),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        actions: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('중단'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('계속 저장'),
              ),
            ],
          ),
        ],
      ),
    ).then((value) => value ?? false);
  }

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
    _startAt = event?.startAt == null
        ? DateTime.now().add(const Duration(hours: 1))
        : planflowLocal(event!.startAt!);
    _endAt = event?.endAt == null ? null : planflowLocal(event!.endAt!);
    _locationLat = event?.locationLat;
    _locationLng = event?.locationLng;
    _critical = event?.isCritical ?? false;
    _recurrenceSelection = RecurrenceSelection.fromRRule(event?.recurrenceRule);
    _isAllDay = event?.isAllDay ?? false;
    _isMultiDay = event?.isMultiDay ?? false;
    _category = event?.category ?? '기타';
    _loadEventIfNeeded();
    if (event != null) {
      unawaited(_loadReminderOffsetIfNeeded(event));
    }
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

      String? recurrenceScope;
      if (!_isNewEvent &&
          _loadedEvent?.recurrenceRule?.trim().isNotEmpty == true) {
        recurrenceScope = await _chooseRecurrenceEditScopeSafe();
        if (recurrenceScope == null) {
          return;
        }
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
        locationLat: _locationLat,
        locationLng: _locationLng,
        memo: _emptyToNull(_memoController.text),
        supplies: supplies,
        suppliesChecked: _loadedEvent?.suppliesChecked ?? const <String>[],
        isCritical: _critical,
        recurrenceRule: _recurrenceSelection.toRRule(),
        isAllDay: _isAllDay,
        isMultiDay: _isMultiDay,
        parentEventId: _loadedEvent?.parentEventId,
        category: _category,
        source: _loadedEvent?.source ?? 'manual',
        externalId: _loadedEvent?.externalId,
        externalCalendarId: _loadedEvent?.externalCalendarId,
        externalEtag: _loadedEvent?.externalEtag,
        externalUpdatedAt: _loadedEvent?.externalUpdatedAt,
        lastSyncedAt: _loadedEvent?.lastSyncedAt,
        createdAt: _loadedEvent?.createdAt,
        updatedAt: _loadedEvent?.updatedAt,
      );

      final overlapStart = updatedEvent.startAt ?? _startAt;
      final overlappingEvents = await _repository.findOverlappingEvents(
        rangeStart: overlapStart,
        rangeEnd: _eventRangeEnd(overlapStart, updatedEvent.endAt),
        userId: user.id,
        excludedEventId: _loadedEvent?.id ?? updatedEvent.id,
      );
      if (!mounted) {
        return;
      }
      if (overlappingEvents.isNotEmpty) {
        final shouldContinue = await _showOverlapWarning(overlappingEvents);
        if (!shouldContinue || !mounted) {
          return;
        }
      }

      late final EventModel savedEvent;
      if (_isNewEvent) {
        savedEvent = await _repository.createEvent(updatedEvent);
      } else if (recurrenceScope == 'single' && _loadedEvent != null) {
        savedEvent = await _repository.createEvent(
          _detachedRecurringEvent(
            updatedEvent,
            parentEventId: _loadedEvent!.id,
            keepRecurrence: false,
          ),
        );
      } else if (recurrenceScope == 'future' && _loadedEvent != null) {
        final original = _loadedEvent!;
        final originalStart = original.startAt;
        final isFirstOccurrence = originalStart == null ||
            planflowIsSameLocalDay(originalStart, _startAt);
        if (isFirstOccurrence) {
          savedEvent = await _repository.updateEvent(updatedEvent);
        } else {
          await _repository.updateEvent(
            _eventWithRecurrenceRule(
              original,
              _truncateRRuleBefore(original.recurrenceRule, _startAt),
            ),
          );
          savedEvent = await _repository.createEvent(
            _detachedRecurringEvent(
              updatedEvent,
              parentEventId: original.id,
              keepRecurrence: true,
            ),
          );
        }
      } else {
        savedEvent = await _repository.updateEvent(updatedEvent);
      }

      final settings = await SettingsRepository.supabase().fetchSettings(
        user.id,
      );
      final sideEffectResult = await widget.sideEffectService.syncAfterSave(
        event: savedEvent,
        userId: user.id,
        reminderOffset: _reminderOffset,
        criticalAlarmOffset: _reminderOffset,
        prepTimeMin: settings?.prepTimeMin ??
            SmartPreparationAlarmService.defaultPrepTimeMin,
        prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
            SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
        departPreAlarmOffset: settings?.departPreAlarmOffset ??
            SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
        isFirstExternalEventOfDay: await _isFirstExternalEventOfDay(
          userId: user.id,
          event: savedEvent,
        ),
      );
      unawaited(CalendarAutoSyncService().syncAfterEventSave(savedEvent));
      unawaited(EventPreparationService().prepareAfterSave(savedEvent));
      final widgetRefreshed = await _refreshHomeWidget(_repository, savedEvent);

      if (mounted) {
        final actionText = _isNewEvent ? '일정을 만들었습니다.' : '일정을 수정했습니다.';
        final warningText = sideEffectResult.isFullySynced
            ? ''
            : ' 알림 동기화가 일부 실패했습니다. 설정을 확인해 주세요.';
        final widgetWarningText =
            widgetRefreshed ? '' : ' 홈 위젯 갱신은 다시 확인해 주세요.';
        _showMessage('$actionText$warningText$widgetWarningText');
        EventRefreshBus.instance.notifyChanged(
          reason: _isNewEvent ? 'event_created' : 'event_updated',
          eventId: savedEvent.id,
          startAt: savedEvent.startAt,
        );
        context.go(AppRoutes.calendar);
      }
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('일정 저장 실패. 로그인 상태 또는 Supabase 스키마를 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  EventModel _detachedRecurringEvent(
    EventModel event, {
    required String parentEventId,
    required bool keepRecurrence,
  }) {
    return EventModel(
      id: '',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      isCritical: event.isCritical,
      recurrenceRule: keepRecurrence ? event.recurrenceRule : null,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: parentEventId,
      category: event.category,
      source: 'manual',
      externalId: null,
      externalCalendarId: null,
      externalEtag: null,
      externalUpdatedAt: null,
      lastSyncedAt: null,
      createdAt: null,
      updatedAt: null,
    );
  }

  EventModel _eventWithRecurrenceRule(EventModel event, String? rule) {
    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      isCritical: event.isCritical,
      recurrenceRule: rule,
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
    );
  }

  String? _truncateRRuleBefore(String? rule, DateTime boundary) {
    if (rule == null || rule.trim().isEmpty) {
      return null;
    }
    final until = DateTime(boundary.year, boundary.month, boundary.day)
        .subtract(const Duration(days: 1));
    return RecurrenceSelection.fromRRule(rule).copyWith(until: until).toRRule();
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
      final event = await _repository.fetchEvent(eventId, userId: user.id);
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
        _locationLat = event.locationLat;
        _locationLng = event.locationLng;
        _memoController.text = event.memo ?? '';
        _suppliesController.text = event.supplies.join(', ');
        _startAt =
            event.startAt == null ? _startAt : planflowLocal(event.startAt!);
        _endAt = event.endAt == null ? null : planflowLocal(event.endAt!);
        _critical = event.isCritical;
        _recurrenceSelection =
            RecurrenceSelection.fromRRule(event.recurrenceRule);
        _isAllDay = event.isAllDay;
        _isMultiDay = event.isMultiDay;
        _category = event.category;
      });
      unawaited(_loadReminderOffsetIfNeeded(event));
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

  Future<void> _loadReminderOffsetIfNeeded(EventModel event) async {
    final startAt = event.startAt;
    if (event.id.trim().isEmpty || startAt == null || !AppEnv.isSupabaseReady) {
      return;
    }

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return;
      }
      final row = await Supabase.instance.client
          .from('reminders')
          .select('notify_at')
          .eq('event_id', event.id)
          .eq('user_id', user.id)
          .eq('type', 'push')
          .maybeSingle();
      if (!mounted) {
        return;
      }
      if (row == null) {
        setState(() {
          _reminderOffset = null;
        });
        return;
      }
      final notifyAt = DateTime.tryParse(row['notify_at'].toString());
      if (notifyAt == null) {
        return;
      }
      final minutes = startAt.difference(notifyAt).inMinutes;
      if (minutes < 0) {
        return;
      }
      setState(() {
        _reminderOffset = Duration(minutes: minutes);
      });
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen reminder load skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _refreshHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return false;
      }
      final now = DateTime.now();
      final events = await repository.listEvents(userId: user.id);
      final nextEvents = events.where((event) {
        final startAt = event.startAt;
        return startAt != null && !startAt.isBefore(now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
      final nextEvent = nextEvents.isEmpty ? fallbackEvent : nextEvents.first;
      return widget.homeWidgetService.updateScheduleData(
        nextEvent: HomeWidgetNextEventData(
          title: nextEvent.title,
          eventId: nextEvent.id,
          startAt: nextEvent.startAt,
          location: nextEvent.location,
          isCritical: nextEvent.isCritical,
        ),
        todayEvents: _todayWidgetEvents(nextEvents, now),
        month: now,
        monthDays: _monthWidgetDays(nextEvents, now),
        weekDays: _weekWidgetDays(nextEvents, now),
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen widget refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _isFirstExternalEventOfDay({
    required String userId,
    required EventModel event,
  }) async {
    try {
      final dayEvents = await _repository.listEvents(userId: userId);
      return const SmartPreparationAlarmService().isFirstExternalEventOfDay(
        event: event,
        dayEvents: dayEvents,
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen first external lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return true;
    }
  }

  // ignore: unused_element
  Future<String?> _chooseRecurrenceEditScope() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('반복 일정 수정'),
        content: const Text(
          '반복 일정입니다. 어떤 범위에 수정 내용을 적용할까요?',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        actions: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('취소'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop('single'),
                child: const Text('이 일정만'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop('future'),
                child: const Text('이후 모든 일정'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('all'),
                child: const Text('전체 반복 일정'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<String?> _chooseRecurrenceEditScopeSafe() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('반복 일정 수정'),
        content: const Text(
          '반복 일정입니다. 어떤 범위에 수정 내용을 적용할까요?',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        actions: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('취소'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop('single'),
                child: const Text('이 일정만'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop('future'),
                child: const Text('이후 모든 일정'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('all'),
                child: const Text('전체 반복 일정'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<HomeWidgetListEventData> _todayWidgetEvents(
    List<EventModel> events,
    DateTime now,
  ) {
    return events
        .where((event) {
          final startAt = event.startAt;
          return startAt != null && planflowIsSameLocalDay(startAt, now);
        })
        .take(6)
        .map(_homeWidgetListEvent)
        .toList(growable: false);
  }

  List<HomeWidgetMonthDayData> _monthWidgetDays(
    List<EventModel> events,
    DateTime now,
  ) {
    final counts = <int, int>{};
    for (final event in events) {
      final startAt = event.startAt;
      final localStart = startAt == null ? null : planflowLocal(startAt);
      if (localStart == null ||
          localStart.year != now.year ||
          localStart.month != now.month) {
        continue;
      }
      counts[localStart.day] = (counts[localStart.day] ?? 0) + 1;
    }
    return counts.entries
        .map(
          (entry) => HomeWidgetMonthDayData(
            day: entry.key,
            summary: '일정 ${entry.value}',
          ),
        )
        .toList(growable: false);
  }

  List<HomeWidgetWeekDayData> _weekWidgetDays(
    List<EventModel> events,
    DateTime now,
  ) {
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    return List<HomeWidgetWeekDayData>.generate(7, (index) {
      final day = weekStart.add(Duration(days: index));
      final dayEvents = events.where((event) {
        final startAt = event.startAt;
        return startAt != null && planflowIsSameLocalDay(startAt, day);
      }).toList(growable: false);
      return HomeWidgetWeekDayData(
        date: day,
        summary: dayEvents.isEmpty ? '일정 없음' : '${dayEvents.length}개',
        events: dayEvents.map(_homeWidgetListEvent).toList(growable: false),
      );
    });
  }

  HomeWidgetListEventData _homeWidgetListEvent(EventModel event) {
    return HomeWidgetListEventData(
      title: event.title,
      startAt: event.startAt,
      location: event.location,
    );
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _pickLocationOnMap() async {
    final query = _locationController.text.trim();
    if (query.isEmpty) {
      _showMessage('장소를 먼저 입력해 주세요.');
      return;
    }

    try {
      debugPrint('PlanFlow operation start: event_edit.pick_location');
      final selected = await pickLocationFromQuery(
        context: context,
        query: query,
        locationLookupService: LocationLookupService(),
      );
      if (!mounted || selected == null) {
        return;
      }
      setState(() {
        _locationController.text = selected.label;
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
      });
      _showMessage('정확한 위치를 선택했어요.');
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen location pick failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('위치 선택을 열지 못했어요. 지도 키와 네트워크를 확인해 주세요.');
      }
    } finally {
      debugPrint('PlanFlow operation end: event_edit.pick_location');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: Text(_isNewEvent ? '일정 만들기' : '일정 편집')),
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
                decoration: InputDecoration(
                  labelText: '장소',
                  suffixIcon: IconButton(
                    tooltip: '지도에서 위치 선택',
                    onPressed: _pickLocationOnMap,
                    icon: const Icon(Icons.map_outlined),
                  ),
                ),
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
              _EventTypeEditor(
                isAllDay: _isAllDay,
                isMultiDay: _isMultiDay,
                category: _category,
                recurrence: _recurrenceSelection,
                onTypeChanged: (value) {
                  setState(() {
                    _isAllDay = value == 'all_day';
                    _isMultiDay = value == 'multi_day';
                  });
                },
                onCategoryChanged: (value) {
                  setState(() {
                    _category = value;
                  });
                },
                onRecurrenceChanged: (value) {
                  setState(() {
                    _recurrenceSelection = value;
                  });
                },
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              ReminderOffsetSelector(
                value: _reminderOffset,
                onChanged: (value) {
                  setState(() {
                    _reminderOffset = value;
                  });
                },
                subtitle: '기본은 1시간 전입니다. 이 일정만 다르게 바꿀 수 있어요.',
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              SwitchListTile.adaptive(
                tileColor: _critical
                    ? const Color(0xFFFFE3DD)
                    : PlanFlowColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: _critical
                        ? const Color(0xFFB42318)
                        : PlanFlowColors.primaryFaint,
                    width: _critical ? 1.2 : 0.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                title: const Text('강한 알림으로 예약'),
                subtitle: const Text(
                  '정확한 알람과 강한 진동/전체 화면 알림을 시도합니다. Android 무음·방해금지 설정은 기기 정책에 따라 직접 해제해야 할 수 있어요.',
                ),
                secondary: Icon(
                  _critical
                      ? Icons.priority_high_rounded
                      : Icons.notifications_active_outlined,
                  color: _critical
                      ? const Color(0xFFB42318)
                      : PlanFlowColors.textSecondary,
                ),
                activeThumbColor: const Color(0xFFB42318),
                activeTrackColor: const Color(0xFFFFC9BE),
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

class _EventTypeEditor extends StatelessWidget {
  const _EventTypeEditor({
    required this.isAllDay,
    required this.isMultiDay,
    required this.category,
    required this.recurrence,
    required this.onTypeChanged,
    required this.onCategoryChanged,
    required this.onRecurrenceChanged,
  });

  final bool isAllDay;
  final bool isMultiDay;
  final String category;
  final RecurrenceSelection recurrence;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<RecurrenceSelection> onRecurrenceChanged;

  @override
  Widget build(BuildContext context) {
    final selectedType = isMultiDay
        ? 'multi_day'
        : isAllDay
            ? 'all_day'
            : 'single';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '일정 유형',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(
                value: 'single',
                label: Text(PlanFlowEventTypeLabels.single),
              ),
              ButtonSegment<String>(
                value: 'all_day',
                label: Text(PlanFlowEventTypeLabels.allDay),
              ),
              ButtonSegment<String>(
                value: 'multi_day',
                label: Text(PlanFlowEventTypeLabels.multiDay),
              ),
            ],
            selected: <String>{selectedType},
            onSelectionChanged: (selected) => onTypeChanged(selected.first),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: PlanFlowEventCategories.values.map((item) {
              return ChoiceChip(
                label: Text(item),
                selected: category == item,
                onSelected: (_) => onCategoryChanged(item),
              );
            }).toList(growable: false),
          ),
          const SizedBox(height: 12),
          RecurrenceSelector(
            value: recurrence,
            onChanged: onRecurrenceChanged,
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
        ? emptyLabel ?? '설정 안 함'
        : MaterialLocalizations.of(context).formatFullDate(value!);
    final time = value == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(value!));

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
