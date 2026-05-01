import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';

class ConfirmScreen extends StatefulWidget {
  const ConfirmScreen({
    super.key,
    this.parsedSchedule = const <String, dynamic>{},
    EventRepository? eventRepository,
  }) : eventRepository = eventRepository ?? const _UnavailableEventRepository();

  final Map<String, dynamic> parsedSchedule;
  final EventRepository eventRepository;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
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

      await repository.createEvent(
        EventModel(
          id: '',
          userId: user.id,
          title: title,
          startAt: _dateTimeValue(widget.parsedSchedule['start_at']) ??
              DateTime.now(),
          endAt: _dateTimeValue(widget.parsedSchedule['end_at']),
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

      if (mounted) {
        _showMessage('Event saved.');
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
