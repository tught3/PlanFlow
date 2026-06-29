import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

class GroupEventShareResult {
  const GroupEventShareResult({required this.created, required this.skipped});

  final List<EventModel> created;
  final List<EventModel> skipped;

  int get createdCount => created.length;
  int get skippedCount => skipped.length;
}

class GroupEventShareService {
  const GroupEventShareService({required EventRepository repository})
      : _repository = repository;

  static const String groupSource = 'group';

  final EventRepository _repository;

  Future<GroupEventShareResult> shareUpcomingPersonalEvents({
    required String userId,
    required String groupId,
    DateTime? now,
  }) async {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      throw ArgumentError.value(groupId, 'groupId', 'Group id is required.');
    }

    final threshold = (now ?? DateTime.now()).toUtc();
    final events = await _repository.listEvents(userId: userId);
    final existingGroupEvents = events
        .where((event) => _isGroupEventFor(event, normalizedGroupId))
        .toList();
    final created = <EventModel>[];
    final skipped = <EventModel>[];

    for (final event in events) {
      if (!_isShareablePersonalEvent(event, threshold)) {
        continue;
      }
      if (_hasMatchingGroupCopy(
        personalEvent: event,
        groupEvents: existingGroupEvents,
      )) {
        skipped.add(event);
        continue;
      }

      final copy = _groupCopyFor(
        personalEvent: event,
        groupId: normalizedGroupId,
      );
      final saved = await _repository.createEvent(copy);
      created.add(saved);
      existingGroupEvents.add(saved);
    }

    return GroupEventShareResult(created: created, skipped: skipped);
  }

  Future<List<EventModel>> updateLinkedGroupCopiesFromPersonal({
    required EventModel personalEvent,
    required String groupId,
  }) async {
    final normalizedGroupId = groupId.trim();
    final events = await _repository.listEvents(userId: personalEvent.userId);
    final linkedCopies = events.where((event) {
      return _isGroupEventFor(event, normalizedGroupId) &&
          _personalEventIdFromGroupCopy(event) == personalEvent.id;
    });

    final updated = <EventModel>[];
    for (final groupCopy in linkedCopies) {
      updated.add(
        await _repository.updateEvent(
          _copyEditableFields(
            from: personalEvent,
            to: groupCopy,
            source: groupSource,
            externalCalendarId: normalizedGroupId,
            parentEventId: null,
          ),
        ),
      );
    }
    return updated;
  }

  Future<EventModel?> updateLinkedPersonalEventFromGroupCopy({
    required EventModel groupEvent,
  }) async {
    final personalEventId = _personalEventIdFromGroupCopy(groupEvent);
    if (personalEventId == null || personalEventId.isEmpty) {
      return null;
    }
    final personalEvent = await _repository.fetchEvent(
      personalEventId,
      userId: groupEvent.userId,
    );
    if (personalEvent == null) {
      return null;
    }

    return _repository.updateEvent(
      _copyEditableFields(
        from: groupEvent,
        to: personalEvent,
        source: personalEvent.source,
        externalCalendarId: personalEvent.externalCalendarId,
        parentEventId: personalEvent.parentEventId,
      ),
    );
  }

  bool _isShareablePersonalEvent(EventModel event, DateTime threshold) {
    final startAt = event.startAt;
    if (event.source != 'manual' || startAt == null) {
      return false;
    }
    if (event.parentEventId?.trim().isNotEmpty == true) {
      return false;
    }
    return !startAt.toUtc().isBefore(threshold);
  }

  bool _isGroupEventFor(EventModel event, String groupId) {
    return event.source == groupSource && event.externalCalendarId == groupId;
  }

  bool _hasMatchingGroupCopy({
    required EventModel personalEvent,
    required List<EventModel> groupEvents,
  }) {
    return groupEvents.any((groupEvent) {
      if (_personalEventIdFromGroupCopy(groupEvent) == personalEvent.id) {
        return true;
      }
      return _duplicateKey(groupEvent) == _duplicateKey(personalEvent);
    });
  }

  EventModel _groupCopyFor({
    required EventModel personalEvent,
    required String groupId,
  }) {
    return EventModel(
      id: '',
      userId: personalEvent.userId,
      title: personalEvent.title,
      startAt: personalEvent.startAt,
      endAt: personalEvent.endAt,
      location: personalEvent.location,
      locationLat: personalEvent.locationLat,
      locationLng: personalEvent.locationLng,
      memo: personalEvent.memo,
      supplies: personalEvent.supplies,
      suppliesChecked: personalEvent.suppliesChecked,
      participants: personalEvent.participants,
      targets: personalEvent.targets,
      isCritical: personalEvent.isCritical,
      useStrongAlarm: personalEvent.useStrongAlarm,
      recurrenceRule: personalEvent.recurrenceRule,
      isAllDay: personalEvent.isAllDay,
      isMultiDay: personalEvent.isMultiDay,
      parentEventId: null,
      category: personalEvent.category,
      source: groupSource,
      externalId: _groupExternalId(groupId, personalEvent.id),
      externalCalendarId: groupId,
    );
  }

  EventModel _copyEditableFields({
    required EventModel from,
    required EventModel to,
    required String source,
    required String? externalCalendarId,
    required String? parentEventId,
  }) {
    return EventModel(
      id: to.id,
      userId: to.userId,
      title: from.title,
      startAt: from.startAt,
      endAt: from.endAt,
      location: from.location,
      locationLat: from.locationLat,
      locationLng: from.locationLng,
      memo: from.memo,
      supplies: from.supplies,
      suppliesChecked: from.suppliesChecked,
      participants: from.participants,
      targets: from.targets,
      isCritical: from.isCritical,
      useStrongAlarm: from.useStrongAlarm,
      recurrenceRule: from.recurrenceRule,
      isAllDay: from.isAllDay,
      isMultiDay: from.isMultiDay,
      parentEventId: parentEventId,
      category: from.category,
      source: source,
      externalId: to.externalId,
      externalCalendarId: externalCalendarId,
      externalEtag: to.externalEtag,
      externalUpdatedAt: to.externalUpdatedAt,
      lastSyncedAt: to.lastSyncedAt,
      createdAt: to.createdAt,
      updatedAt: to.updatedAt,
    );
  }

  String _groupExternalId(String groupId, String personalEventId) {
    return 'group:$groupId:personal:$personalEventId';
  }

  String? _personalEventIdFromGroupCopy(EventModel event) {
    final externalId = event.externalId?.trim();
    if (externalId == null || externalId.isEmpty) {
      return null;
    }
    final prefix = 'group:${event.externalCalendarId}:personal:';
    if (!externalId.startsWith(prefix)) {
      return null;
    }
    final id = externalId.substring(prefix.length).trim();
    return id.isEmpty ? null : id;
  }

  String _duplicateKey(EventModel event) {
    return [
      event.title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
      event.startAt?.toUtc().toIso8601String() ?? '',
      event.endAt?.toUtc().toIso8601String() ?? '',
    ].join('|');
  }
}
