import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/local_time.dart';
import '../models/event_model.dart';

abstract class EventRepository {
  const EventRepository();

  factory EventRepository.supabase({SupabaseClient? client}) =
      SupabaseEventRepository;

  Future<List<EventModel>> listEvents({String? userId});

  Future<EventModel?> fetchEvent(String eventId, {String? userId});

  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) {
    return Future<EventModel?>.value(null);
  }

  /// 특정 source의 external_id 전체를 Set으로 일괄 조회 (중복 스킵용 사전 조회)
  Future<Set<String>> fetchExternalIdsBySource({
    required String source,
    String? userId,
  }) {
    return Future.value(<String>{});
  }

  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return <EventModel>[];
  }

  Future<EventModel?> findEventByTitleAndStart({
    required String title,
    required DateTime startAt,
    String? userId,
    Duration tolerance = const Duration(minutes: 1),
    Set<String> excludedSources = const <String>{},
  }) async {
    final normalizedTitle = _normalizeDuplicateTitle(title);
    if (normalizedTitle.isEmpty) {
      return null;
    }
    final events = await listEvents(userId: userId);
    for (final event in events) {
      if (excludedSources.contains(event.source)) {
        continue;
      }
      final eventStartAt = event.startAt;
      if (eventStartAt == null) {
        continue;
      }
      final sameTitle =
          _normalizeDuplicateTitle(event.title) == normalizedTitle;
      final startDelta = eventStartAt.toUtc().difference(startAt.toUtc()).abs();
      if (sameTitle && startDelta <= tolerance) {
        return event;
      }
    }
    return null;
  }

  Future<EventModel?> attachExternalSyncMetadataIfCompatible({
    required EventModel existing,
    required EventModel incoming,
  }) async {
    final incomingExternalId = incoming.externalId?.trim();
    final incomingCalendarId = incoming.externalCalendarId?.trim();
    if (incomingExternalId == null ||
        incomingExternalId.isEmpty ||
        incomingCalendarId == null ||
        incomingCalendarId.isEmpty) {
      return null;
    }

    final existingExternalId = existing.externalId?.trim() ?? '';
    final existingCalendarId = existing.externalCalendarId?.trim() ?? '';
    if (existingExternalId.isNotEmpty &&
        existingCalendarId.isNotEmpty &&
        existingCalendarId != incomingCalendarId) {
      return null;
    }

    final linkedEvent = _mergeExternalMetadata(
      existing: existing,
      incoming: incoming,
      externalId: incomingExternalId,
      externalCalendarId: incomingCalendarId,
      keepExistingPeopleFields: true,
    );
    return updateEvent(linkedEvent);
  }

  Future<EventModel> createEvent(EventModel event);

  Future<EventModel> updateEvent(EventModel event);

  Future<EventModel> updateSuppliesChecked({
    required String eventId,
    required List<String> suppliesChecked,
    String? userId,
  }) {
    throw UnimplementedError('updateSuppliesChecked is not implemented.');
  }

  Future<EventModel> upsertEventBySourceExternalId(EventModel event) {
    return upsertEvent(event);
  }

  Future<void> deleteEvent(String eventId, {String? userId});

  @Deprecated('Use listEvents instead.')
  Future<List<EventModel>> fetchEvents(String userId) {
    return listEvents(userId: userId);
  }

  @Deprecated('Use createEvent or updateEvent instead.')
  Future<void> saveEvent(EventModel event) async {
    await upsertEvent(event);
  }

  Future<EventModel> upsertEvent(EventModel event) {
    if (event.id.trim().isEmpty) {
      return createEvent(event);
    }
    return updateEvent(event);
  }
}

String _normalizeDuplicateTitle(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

List<EventModel> filterDuplicateWarningEvents({
  required EventModel draft,
  required List<EventModel> candidates,
}) {
  return candidates
      .where((candidate) => _shouldWarnAsDuplicate(draft, candidate))
      .toList(growable: false);
}

bool _shouldWarnAsDuplicate(EventModel draft, EventModel candidate) {
  final draftStart = draft.startAt;
  final candidateStart = candidate.startAt;
  if (draftStart == null || candidateStart == null) {
    return false;
  }

  if (_hasSameLocalScheduleWindow(draft, candidate)) {
    return true;
  }

  return _hasSimilarDuplicateContent(draft, candidate);
}

bool _hasSameLocalScheduleWindow(EventModel left, EventModel right) {
  final leftStart = left.startAt;
  final rightStart = right.startAt;
  if (leftStart == null || rightStart == null) {
    return false;
  }

  final leftLocalStart = planflowLocal(leftStart);
  final rightLocalStart = planflowLocal(rightStart);
  final sameStartMinute = leftLocalStart.year == rightLocalStart.year &&
      leftLocalStart.month == rightLocalStart.month &&
      leftLocalStart.day == rightLocalStart.day &&
      leftLocalStart.hour == rightLocalStart.hour &&
      leftLocalStart.minute == rightLocalStart.minute;
  if (!sameStartMinute) {
    return false;
  }

  return _displayEndDayForDuplicate(left) == _displayEndDayForDuplicate(right);
}

DateTime _displayEndDayForDuplicate(EventModel event) {
  final startAt = event.startAt;
  final endAt = event.endAt ?? startAt;
  if (startAt == null || endAt == null) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  var localEnd = planflowLocal(endAt);
  if (endAt.isAfter(startAt) &&
      localEnd.hour == 0 &&
      localEnd.minute == 0 &&
      localEnd.second == 0 &&
      localEnd.millisecond == 0 &&
      localEnd.microsecond == 0) {
    localEnd = localEnd.subtract(const Duration(microseconds: 1));
  }
  return DateTime(localEnd.year, localEnd.month, localEnd.day);
}

bool _hasSimilarDuplicateContent(EventModel draft, EventModel candidate) {
  final draftParts = <String>[
    draft.title,
    draft.location ?? '',
    draft.memo ?? '',
  ];
  final candidateParts = <String>[
    candidate.title,
    candidate.location ?? '',
    candidate.memo ?? '',
  ];
  final draftText = _normalizeDuplicateComparable(draftParts.join(' '));
  final candidateText = _normalizeDuplicateComparable(candidateParts.join(' '));
  if (draftText.isEmpty || candidateText.isEmpty) {
    return false;
  }
  if (draftText == candidateText) {
    return true;
  }
  final shorter =
      draftText.length <= candidateText.length ? draftText : candidateText;
  final longer =
      draftText.length > candidateText.length ? draftText : candidateText;
  if (shorter.length >= 4 && longer.contains(shorter)) {
    return true;
  }

  final leftTokens = _duplicateTokens(draftParts.join(' '));
  final rightTokens = _duplicateTokens(candidateParts.join(' '));
  if (leftTokens.isEmpty || rightTokens.isEmpty) {
    return false;
  }
  final intersection = leftTokens.intersection(rightTokens).length;
  final union = leftTokens.union(rightTokens).length;
  return union > 0 && intersection / union >= 0.55;
}

String _normalizeDuplicateComparable(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[^\w가-힣]'), '');
}

Set<String> _duplicateTokens(String value) {
  return value
      .toLowerCase()
      .split(RegExp(r'[\s,./·:;()]+'))
      .map(_normalizeDuplicateComparable)
      .where((token) => token.length >= 2)
      .toSet();
}

bool shouldKeepExistingEventForExternalImport({
  required EventModel existing,
  required EventModel incoming,
}) {
  final existingUpdatedAt = existing.updatedAt ?? existing.createdAt;
  final lastSyncedAt = existing.lastSyncedAt ?? existing.externalUpdatedAt;
  if (existingUpdatedAt == null || lastSyncedAt == null) {
    return false;
  }
  final hasLocalEditAfterSync =
      existingUpdatedAt.toUtc().isAfter(lastSyncedAt.toUtc());
  if (!hasLocalEditAfterSync) {
    return false;
  }

  final existingEtag = (existing.externalEtag ?? '').trim();
  final incomingEtag = (incoming.externalEtag ?? '').trim();
  final externalStateAdvanced = existingEtag.isNotEmpty &&
      incomingEtag.isNotEmpty &&
      existingEtag != incomingEtag;
  return !externalStateAdvanced;
}

DateTime eventOverlapEndFor(EventModel event) {
  final startAt = event.startAt;
  if (startAt == null) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  final endAt = event.endAt;
  if (endAt != null && endAt.isAfter(startAt)) {
    return endAt;
  }

  final fallbackDuration = (event.isAllDay || event.isMultiDay)
      ? const Duration(days: 1)
      : const Duration(minutes: 30);
  return startAt.add(fallbackDuration);
}

bool eventRangesOverlap({
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required DateTime eventStart,
  required DateTime eventEnd,
}) {
  final normalizedRangeStart = rangeStart.toUtc();
  final normalizedRangeEnd = rangeEnd.toUtc();
  final normalizedEventStart = eventStart.toUtc();
  final normalizedEventEnd = eventEnd.toUtc();

  if (normalizedRangeStart.isAtSameMomentAs(normalizedEventStart)) {
    return true;
  }

  return normalizedEventStart.isBefore(normalizedRangeEnd) &&
      normalizedRangeStart.isBefore(normalizedEventEnd);
}

List<EventModel> expandEventOccurrencesForOverlap(
  EventModel event, {
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  final rule = event.recurrenceRule?.toUpperCase();
  final startAt = event.startAt;
  if (rule == null || rule.isEmpty || startAt == null) {
    return <EventModel>[event];
  }

  final freq = RegExp(r'FREQ=([A-Z]+)').firstMatch(rule)?.group(1);
  if (freq == null) {
    return <EventModel>[event];
  }

  final intervalText = RegExp(r'INTERVAL=(\d+)').firstMatch(rule)?.group(1);
  final interval = int.tryParse(intervalText ?? '1')?.clamp(1, 365) ?? 1;
  final until = _parseRRuleUntilForOverlap(
    RegExp(r'UNTIL=([0-9TzZ]+)').firstMatch(rule)?.group(1),
  );
  final hardEnd = until?.isBefore(rangeEnd) == true ? until! : rangeEnd;
  final localStartAt = planflowLocal(startAt);
  final duration = event.endAt?.difference(startAt) ??
      ((event.isAllDay || event.isMultiDay)
          ? const Duration(days: 1)
          : const Duration(minutes: 30));
  final occurrences = <EventModel>[];

  if (freq == 'WEEKLY') {
    final byDays = _parseRRuleByDaysForOverlap(rule);
    if (byDays.isNotEmpty) {
      var weekStart = DateTime(
        localStartAt.year,
        localStartAt.month,
        localStartAt.day,
        localStartAt.hour,
        localStartAt.minute,
        localStartAt.second,
      ).subtract(Duration(days: localStartAt.weekday - DateTime.monday));
      var safety = 0;
      while (weekStart.isBefore(hardEnd) && safety < 120) {
        safety += 1;
        for (final weekday in byDays) {
          final day = weekStart.add(Duration(days: weekday - DateTime.monday));
          final current = DateTime(
            day.year,
            day.month,
            day.day,
            localStartAt.hour,
            localStartAt.minute,
            localStartAt.second,
          );
          if (current.isBefore(localStartAt) || !current.isBefore(hardEnd)) {
            continue;
          }
          final candidate = _copyEventWithTime(
            event,
            startAt: current,
            endAt: current.add(duration),
          );
          if (_eventIntersectsOverlapRange(candidate, rangeStart, rangeEnd)) {
            occurrences.add(candidate);
          }
        }
        weekStart = weekStart.add(Duration(days: 7 * interval));
      }
      return occurrences.isEmpty ? <EventModel>[event] : occurrences;
    }
  }

  var current = localStartAt;
  var safety = 0;
  while (current.isBefore(hardEnd) && safety < 420) {
    safety += 1;
    final candidate = _copyEventWithTime(
      event,
      startAt: current,
      endAt: current.add(duration),
    );
    if (_eventIntersectsOverlapRange(candidate, rangeStart, rangeEnd)) {
      occurrences.add(candidate);
    }
    current = switch (freq) {
      'DAILY' => current.add(Duration(days: interval)),
      'WEEKLY' => current.add(Duration(days: 7 * interval)),
      'MONTHLY' => DateTime(
          current.year,
          current.month + interval,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
      'YEARLY' => DateTime(
          current.year + interval,
          current.month,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
      _ => hardEnd,
    };
  }
  return occurrences.isEmpty ? <EventModel>[event] : occurrences;
}

EventModel _copyEventWithTime(
  EventModel event, {
  required DateTime startAt,
  required DateTime? endAt,
}) {
  return EventModel(
    id: event.id,
    userId: event.userId,
    title: event.title,
    startAt: startAt,
    endAt: endAt,
    location: event.location,
    locationLat: event.locationLat,
    locationLng: event.locationLng,
    memo: event.memo,
    supplies: event.supplies,
    suppliesChecked: event.suppliesChecked,
    participants: event.participants,
    targets: event.targets,
    isCritical: event.isCritical,
    recurrenceRule: event.recurrenceRule,
    isAllDay: event.isAllDay,
    isMultiDay: event.isMultiDay,
    parentEventId: event.parentEventId,
    groupEventId: event.groupEventId,
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

bool _eventIntersectsOverlapRange(
  EventModel event,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final startAt = event.startAt;
  if (startAt == null) {
    return false;
  }
  final eventEnd = eventOverlapEndFor(event);
  return eventRangesOverlap(
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    eventStart: startAt,
    eventEnd: eventEnd,
  );
}

DateTime? _parseRRuleUntilForOverlap(String? value) {
  if (value == null || value.length < 8) {
    return null;
  }
  final digits = value.replaceAll(RegExp('[^0-9]'), '');
  if (digits.length < 8) {
    return null;
  }
  final year = int.tryParse(digits.substring(0, 4));
  final month = int.tryParse(digits.substring(4, 6));
  final day = int.tryParse(digits.substring(6, 8));
  if (year == null || month == null || day == null) {
    return null;
  }
  return DateTime(year, month, day, 23, 59, 59);
}

Set<int> _parseRRuleByDaysForOverlap(String rule) {
  final raw = RegExp(r'BYDAY=([A-Z,]+)').firstMatch(rule)?.group(1);
  if (raw == null || raw.isEmpty) {
    return const <int>{};
  }

  final days = <int>{};
  for (final token in raw.split(',')) {
    switch (token.trim()) {
      case 'MO':
        days.add(DateTime.monday);
        break;
      case 'TU':
        days.add(DateTime.tuesday);
        break;
      case 'WE':
        days.add(DateTime.wednesday);
        break;
      case 'TH':
        days.add(DateTime.thursday);
        break;
      case 'FR':
        days.add(DateTime.friday);
        break;
      case 'SA':
        days.add(DateTime.saturday);
        break;
      case 'SU':
        days.add(DateTime.sunday);
        break;
    }
  }
  return days;
}

class SupabaseEventRepository extends EventRepository {
  SupabaseEventRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _tableName = 'events';
  static const String _selectColumns =
      'id, user_id, title, start_at, end_at, location, location_lat, '
      'location_lng, memo, supplies, supplies_checked, is_critical, use_strong_alarm, source, '
      'participants, targets, '
      'recurrence_rule, is_all_day, is_multi_day, parent_event_id, '
      'group_event_id, category, '
      'external_id, external_calendar_id, external_etag, external_updated_at, '
      'last_synced_at, created_at, updated_at';
  static const String _legacySelectColumns =
      'id, user_id, title, start_at, end_at, location, location_lat, '
      'location_lng, memo, supplies, supplies_checked, is_critical, source, '
      'external_id, created_at';

  final SupabaseClient _client;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    final resolvedUserId = _resolveUserId(userId);
    final response = await _selectEventsForUser(resolvedUserId);

    return response
        .map((row) => EventModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    final resolvedUserId = _resolveUserId(userId);
    final response = await _selectEventById(eventId, resolvedUserId);

    if (response == null) {
      return null;
    }
    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final normalizedSource = source.trim();
    final normalizedExternalId = externalId.trim();
    if (normalizedSource.isEmpty || normalizedExternalId.isEmpty) {
      return null;
    }

    final response = await _selectEventBySourceExternalId(
      source: normalizedSource,
      externalId: normalizedExternalId,
      userId: resolvedUserId,
    );

    if (response == null) {
      return null;
    }
    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<Set<String>> fetchExternalIdsBySource({
    required String source,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final normalizedSource = source.trim();
    if (normalizedSource.isEmpty) {
      return <String>{};
    }
    final rows = await _client
        .from(_tableName)
        .select('external_id')
        .eq('user_id', resolvedUserId)
        .eq('source', normalizedSource)
        .not('external_id', 'is', null);
    return {
      for (final row in rows)
        if (row['external_id'] != null) row['external_id'] as String,
    };
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    if (!rangeEnd.isAfter(rangeStart)) {
      return <EventModel>[];
    }

    final resolvedUserId = _resolveUserId(userId);
    final normalizedExcludedEventId = excludedEventId?.trim();
    final events = await listEvents(userId: resolvedUserId);
    return events.where((event) {
      if (normalizedExcludedEventId != null &&
          normalizedExcludedEventId.isNotEmpty &&
          event.id == normalizedExcludedEventId) {
        return false;
      }

      final occurrences = expandEventOccurrencesForOverlap(
        event,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      return occurrences.any((candidate) {
        final eventStart = candidate.startAt;
        if (eventStart == null) {
          return false;
        }

        final eventEnd = eventOverlapEndFor(candidate);
        return eventRangesOverlap(
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          eventStart: eventStart,
          eventEnd: eventEnd,
        );
      });
    }).toList(growable: false);
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);

    final response = await _insertEvent(event);

    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);
    if (event.id.trim().isEmpty) {
      throw ArgumentError.value(event.id, 'event.id', 'Event id is required.');
    }

    final response = await _updateEventRow(event, resolvedUserId);

    if (response == null) {
      throw StateError('Event not found for the current user.');
    }

    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);

    final normalizedSource = event.source.trim();
    final normalizedExternalId = (event.externalId ?? '').trim();
    if (normalizedSource.isEmpty || normalizedExternalId.isEmpty) {
      return upsertEvent(event);
    }

    final existing = await fetchEventBySourceExternalId(
      source: normalizedSource,
      externalId: normalizedExternalId,
      userId: resolvedUserId,
    );

    if (existing == null) {
      return createEvent(event);
    }

    if (shouldKeepExistingEventForExternalImport(
      existing: existing,
      incoming: event,
    )) {
      return existing;
    }

    final mergedEvent = _mergeExternalMetadata(
      existing: existing,
      incoming: event,
      externalId: normalizedExternalId,
      externalCalendarId: event.externalCalendarId,
      keepExistingPeopleFields: false,
    ).copyWithSource(normalizedSource);

    return updateEvent(mergedEvent);
  }

  @override
  Future<EventModel> upsertEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);

    final response = await _upsertEventRow(event);

    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> updateSuppliesChecked({
    required String eventId,
    required List<String> suppliesChecked,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final response = await _updateSuppliesCheckedRow(
      eventId: eventId,
      suppliesChecked: suppliesChecked,
      userId: resolvedUserId,
    );

    if (response == null) {
      throw StateError('Event not found for the current user.');
    }

    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    final resolvedUserId = _resolveUserId(userId);
    await _client
        .from(_tableName)
        .delete()
        .eq('id', eventId)
        .eq('user_id', resolvedUserId);
  }

  String _resolveCurrentUserId() {
    final userId =
        _client.auth.currentSession?.user.id ?? _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError('A signed-in user is required for event writes.');
    }
    return userId;
  }

  String _resolveUserId(String? userId) {
    final resolvedUserId = userId ??
        _client.auth.currentSession?.user.id ??
        _client.auth.currentUser?.id;
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      throw StateError('A signed-in user is required for event queries.');
    }
    return resolvedUserId;
  }

  void _validateWritableEvent(EventModel event, String resolvedUserId) {
    if (event.userId != resolvedUserId) {
      throw StateError(
        'Event userId must match the signed-in user for scoped writes.',
      );
    }
    if (event.title.trim().isEmpty) {
      throw ArgumentError.value(
          event.title, 'event.title', 'Title is required.');
    }
    if (event.startAt == null) {
      throw ArgumentError.value(
        event.startAt,
        'event.startAt',
        'Start time is required.',
      );
    }
  }

  Map<String, dynamic> _rowAsJson(Object? row) {
    return Map<String, dynamic>.from(row as Map);
  }

  Future<List<dynamic>> _selectEventsForUser(String userId) async {
    try {
      return await _client
          .from(_tableName)
          .select(_selectColumns)
          .eq('user_id', userId)
          .order('start_at');
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .select(_legacySelectColumns)
          .eq('user_id', userId)
          .order('start_at');
    }
  }

  Future<Map<String, dynamic>?> _selectEventById(
    String eventId,
    String userId,
  ) async {
    try {
      return await _client
          .from(_tableName)
          .select(_selectColumns)
          .eq('id', eventId)
          .eq('user_id', userId)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .select(_legacySelectColumns)
          .eq('id', eventId)
          .eq('user_id', userId)
          .maybeSingle();
    }
  }

  Future<Map<String, dynamic>?> _selectEventBySourceExternalId({
    required String source,
    required String externalId,
    required String userId,
  }) async {
    try {
      return await _client
          .from(_tableName)
          .select(_selectColumns)
          .eq('user_id', userId)
          .eq('source', source)
          .eq('external_id', externalId)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .select(_legacySelectColumns)
          .eq('user_id', userId)
          .eq('source', source)
          .eq('external_id', externalId)
          .maybeSingle();
    }
  }

  Future<Map<String, dynamic>> _insertEvent(EventModel event) async {
    try {
      return await _client
          .from(_tableName)
          .insert(event.toJson(includeId: event.id.trim().isNotEmpty))
          .select(_selectColumns)
          .single();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .insert(
            _legacyPayload(
              event.toJson(includeId: event.id.trim().isNotEmpty),
            ),
          )
          .select(_legacySelectColumns)
          .single();
    }
  }

  Future<Map<String, dynamic>?> _updateEventRow(
    EventModel event,
    String userId,
  ) async {
    try {
      return await _client
          .from(_tableName)
          .update(event.toUpdateJson())
          .eq('id', event.id)
          .eq('user_id', userId)
          .select(_selectColumns)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .update(_legacyPayload(event.toUpdateJson()))
          .eq('id', event.id)
          .eq('user_id', userId)
          .select(_legacySelectColumns)
          .maybeSingle();
    }
  }

  Future<Map<String, dynamic>> _upsertEventRow(EventModel event) async {
    try {
      return await _client
          .from(_tableName)
          .upsert(
            event.toJson(includeId: event.id.trim().isNotEmpty),
            onConflict: 'id',
          )
          .select(_selectColumns)
          .single();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .upsert(
            _legacyPayload(
              event.toJson(includeId: event.id.trim().isNotEmpty),
            ),
            onConflict: 'id',
          )
          .select(_legacySelectColumns)
          .single();
    }
  }

  Future<Map<String, dynamic>?> _updateSuppliesCheckedRow({
    required String eventId,
    required List<String> suppliesChecked,
    required String userId,
  }) async {
    try {
      return await _client
          .from(_tableName)
          .update(<String, dynamic>{'supplies_checked': suppliesChecked})
          .eq('id', eventId)
          .eq('user_id', userId)
          .select(_selectColumns)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (!_isMissingSyncSchemaError(error)) {
        rethrow;
      }
      return _client
          .from(_tableName)
          .update(<String, dynamic>{'supplies_checked': suppliesChecked})
          .eq('id', eventId)
          .eq('user_id', userId)
          .select(_legacySelectColumns)
          .maybeSingle();
    }
  }

  Map<String, dynamic> _legacyPayload(Map<String, dynamic> payload) {
    return Map<String, dynamic>.from(payload)
      ..remove('external_calendar_id')
      ..remove('external_etag')
      ..remove('external_updated_at')
      ..remove('last_synced_at')
      ..remove('participants')
      ..remove('targets')
      ..remove('recurrence_rule')
      ..remove('is_all_day')
      ..remove('is_multi_day')
      ..remove('parent_event_id')
      ..remove('group_event_id')
      ..remove('category')
      ..remove('use_strong_alarm')
      ..remove('updated_at');
  }

  bool _isMissingSyncSchemaError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return text.contains('external_calendar_id') ||
        text.contains('external_etag') ||
        text.contains('external_updated_at') ||
        text.contains('last_synced_at') ||
        text.contains('participants') ||
        text.contains('targets') ||
        text.contains('recurrence_rule') ||
        text.contains('is_all_day') ||
        text.contains('is_multi_day') ||
        text.contains('parent_event_id') ||
        text.contains('group_event_id') ||
        text.contains('category') ||
        text.contains('use_strong_alarm') ||
        text.contains('updated_at') ||
        text.contains('pgrst204') ||
        text.contains('42703');
  }
}

extension on EventModel {
  EventModel copyWithSource(String source) {
    return EventModel(
      id: id,
      userId: userId,
      title: title,
      startAt: startAt,
      endAt: endAt,
      location: location,
      locationLat: locationLat,
      locationLng: locationLng,
      memo: memo,
      supplies: supplies,
      suppliesChecked: suppliesChecked,
      participants: participants,
      targets: targets,
      isCritical: isCritical,
      useStrongAlarm: useStrongAlarm,
      recurrenceRule: recurrenceRule,
      isAllDay: isAllDay,
      isMultiDay: isMultiDay,
      parentEventId: parentEventId,
      groupEventId: groupEventId,
      category: category,
      source: source,
      externalId: externalId,
      externalCalendarId: externalCalendarId,
      externalEtag: externalEtag,
      externalUpdatedAt: externalUpdatedAt,
      lastSyncedAt: lastSyncedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

EventModel _mergeExternalMetadata({
  required EventModel existing,
  required EventModel incoming,
  required String externalId,
  required String? externalCalendarId,
  required bool keepExistingPeopleFields,
}) {
  final participants = keepExistingPeopleFields || incoming.participants.isEmpty
      ? existing.participants
      : incoming.participants;
  final targets = keepExistingPeopleFields || incoming.targets.isEmpty
      ? existing.targets
      : incoming.targets;
  return EventModel(
    id: existing.id,
    userId: incoming.userId,
    title: incoming.title,
    startAt: incoming.startAt,
    endAt: incoming.endAt,
    location: incoming.location,
    locationLat: incoming.locationLat,
    locationLng: incoming.locationLng,
    memo: incoming.memo,
    supplies: incoming.supplies,
    suppliesChecked: incoming.suppliesChecked,
    participants: participants,
    targets: targets,
    isCritical: existing.isCritical || incoming.isCritical,
    useStrongAlarm: existing.useStrongAlarm || incoming.useStrongAlarm,
    recurrenceRule: incoming.recurrenceRule,
    isAllDay: incoming.isAllDay,
    isMultiDay: incoming.isMultiDay,
    parentEventId: incoming.parentEventId,
    groupEventId: existing.groupEventId,
    category: incoming.category,
    source: incoming.source,
    externalId: externalId,
    externalCalendarId: externalCalendarId,
    externalEtag: incoming.externalEtag ?? existing.externalEtag,
    externalUpdatedAt: incoming.externalUpdatedAt ?? existing.externalUpdatedAt,
    lastSyncedAt: incoming.lastSyncedAt ?? DateTime.now().toUtc(),
    createdAt: existing.createdAt,
    updatedAt: existing.updatedAt,
  );
}
