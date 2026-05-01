import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../services/home_widget_service.dart';
import '../../services/notification_service.dart';

class ConfirmScreen extends StatefulWidget {
  ConfirmScreen({
    super.key,
    this.parsedSchedule = const <String, dynamic>{},
    EventRepository? eventRepository,
    NotificationService? notificationService,
    HomeWidgetService? homeWidgetService,
  })  : eventRepository =
            eventRepository ?? const _UnavailableEventRepository(),
        notificationService = notificationService ?? NotificationService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final Map<String, dynamic> parsedSchedule;
  final EventRepository eventRepository;
  final NotificationService notificationService;
  final HomeWidgetService homeWidgetService;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
  late DateTime _startAt;
  DateTime? _endAt;
  late bool _isCritical;
  bool _isSaving = false;

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
    _suppliesController = TextEditingController(
      text: _stringListValue(widget.parsedSchedule['supplies']).join(', '),
    );
    _startAt = _dateTimeValue(widget.parsedSchedule['start_at']) ??
        DateTime.now().add(const Duration(hours: 1));
    _endAt = _dateTimeValue(widget.parsedSchedule['end_at']);
    _isCritical = widget.parsedSchedule['is_critical'] == true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _suppliesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showMessage('Title is required.');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (!AppEnv.isConfigured) {
        _showMessage('Saved locally for now. Add env values to sync.');
        if (mounted) {
          context.go(AppRoutes.home);
        }
        return;
      }

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _showMessage('Saved locally for now. Sign in to sync with Supabase.');
        if (mounted) {
          context.go(AppRoutes.home);
        }
        return;
      }

      final repository = widget.eventRepository is _UnavailableEventRepository
          ? EventRepository.supabase()
          : widget.eventRepository;

      final savedEvent = await repository.createEvent(
        EventModel(
          id: '',
          userId: user.id,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          location: _emptyToNull(_locationController.text),
          memo: _emptyToNull(_memoController.text),
          supplies: _suppliesController.text
              .split(',')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false),
          isCritical: _isCritical,
        ),
      );
      final followUpResult = await _saveRelatedRecords(
        client: Supabase.instance.client,
        userId: user.id,
        event: savedEvent,
      );
      await _updateHomeWidget(repository, savedEvent);

      if (mounted) {
        _showMessage(
          followUpResult.hasFailures
              ? 'Event saved. Some reminders or logs need another sync.'
              : 'Event saved.',
        );
        context.go(AppRoutes.home);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('Could not save yet. Check Supabase sign-in and env.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<_FollowUpSaveResult> _saveRelatedRecords({
    required SupabaseClient client,
    required String userId,
    required EventModel event,
  }) async {
    final failures = <Object>[];
    final eventStartAt = event.startAt ?? _startAt;
    final preActions = _preActionPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );
    if (preActions.isNotEmpty) {
      await _tryFollowUp(
        failures,
        () => client.from('pre_actions').insert(preActions),
      );
    }

    final eventReminderNotifyAt =
        eventStartAt.subtract(const Duration(minutes: 60));
    final criticalAlarmNotifyAt =
        eventStartAt.subtract(const Duration(minutes: 30));
    final reminderPayloads = <Map<String, dynamic>>[
      _reminderPayload(
        userId: userId,
        eventId: event.id,
        type: 'push',
        notifyAt: eventReminderNotifyAt,
      ),
      if (_isCritical)
        _reminderPayload(
          userId: userId,
          eventId: event.id,
          type: 'system_alarm',
          notifyAt: criticalAlarmNotifyAt,
        ),
    ];
    await _tryFollowUp(
      failures,
      () => client.from('reminders').insert(reminderPayloads),
    );

    final location = _emptyToNull(_locationController.text);
    if (location != null) {
      await _tryFollowUp(
        failures,
        () => client.from('location_history').insert(<String, dynamic>{
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
        failures,
        () => client.from('voice_logs').insert(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'raw_text': rawText,
          'parsed_json': widget.parsedSchedule,
        }),
      );
    }

    await _tryFollowUp(
      failures,
      () => widget.notificationService.scheduleEventReminder(
        id: widget.notificationService.notificationIdFor('${event.id}:push'),
        title: event.title,
        body: 'Upcoming schedule: ${event.title}',
        notifyAt: eventReminderNotifyAt,
      ),
    );

    if (_isCritical) {
      await _tryFollowUp(
        failures,
        () => widget.notificationService.scheduleCriticalAlarm(
          id: widget.notificationService
              .notificationIdFor('${event.id}:critical'),
          title: event.title,
          notifyAt: criticalAlarmNotifyAt,
        ),
      );
    }

    return _FollowUpSaveResult(failures: failures);
  }

  Future<void> _tryFollowUp(
    List<Object> failures,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      failures.add(error);
    }
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
    final now = DateTime.now();
    final events = await repository.listEvents();
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

  List<Map<String, dynamic>> _preActionPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    final rawPreActions = widget.parsedSchedule['pre_actions'];
    if (rawPreActions is! List) {
      return const <Map<String, dynamic>>[];
    }

    return rawPreActions
        .whereType<Map>()
        .map((preAction) {
          final title = _stringValue(preAction['title']);
          final offsetHours = _intValue(preAction['offset_hours']);
          if (title == null || offsetHours == null) {
            return null;
          }
          return <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': title,
            'notify_at': eventStartAt
                .subtract(Duration(hours: offsetHours))
                .toIso8601String(),
            'is_done': false,
          };
        })
        .whereType<Map<String, dynamic>>()
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
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm Event')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            if (_parseFailed)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(AppConstants.defaultPadding),
                  child: Text(
                    'Automatic parsing failed. Review and enter the details manually.',
                  ),
                ),
              ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            _DateTimeTile(
              label: 'Start',
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
              label: 'End',
              value: _endAt,
              emptyLabel: 'No end time',
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
                      tooltip: 'Clear end time',
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
              controller: _suppliesController,
              decoration: const InputDecoration(
                labelText: 'Supplies',
                helperText: 'Separate items with commas.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(
                labelText: 'Memo',
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
              title: const Text('Critical alarm'),
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
              label: Text(_isSaving ? 'Saving' : 'Save event'),
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
        ? emptyLabel ?? 'Not set'
        : MaterialLocalizations.of(context).formatFullDate(value!);
    final time = value == null
        ? null
        : MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(value!),
          );

    return ListTile(
      contentPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      title: Text(label),
      subtitle: Text(time == null ? text : '$text · $time'),
      trailing: trailing ?? const Icon(Icons.edit_calendar),
      onTap: onTap,
    );
  }
}

class _UnavailableEventRepository extends EventRepository {
  const _UnavailableEventRepository();

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError();
  }
}

class _FollowUpSaveResult {
  const _FollowUpSaveResult({
    required this.failures,
  });

  final List<Object> failures;

  bool get hasFailures => failures.isNotEmpty;
}
