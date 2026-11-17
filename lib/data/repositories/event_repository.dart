import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/local_time.dart';
import '../../core/recurrence_expansion.dart' show expandRecurringEvent;
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
    bool adoptIncomingSource = true,
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

    return updateExternalSyncMetadata(
      eventId: existing.id,
      userId: existing.userId,
      externalId: incomingExternalId,
      externalCalendarId: incomingCalendarId,
      // PlanFlow owns reflected event content. When adoptIncomingSource is
      // false, keep the last applied provider revision; by default, adopt the
      // incoming etag, external revision, sync timestamp, and source.
      externalEtag: adoptIncomingSource ? incoming.externalEtag : null,
      externalUpdatedAt:
          adoptIncomingSource ? incoming.externalUpdatedAt : null,
      lastSyncedAt: adoptIncomingSource
          ? incoming.lastSyncedAt ?? DateTime.now().toUtc()
          : null,
      source: adoptIncomingSource ? incoming.source : null,
    );
  }

  Future<EventModel?> updateExternalSyncMetadata({
    required String eventId,
    String? userId,
    required String externalId,
    required String? externalCalendarId,
    String? externalEtag,
    DateTime? externalUpdatedAt,
    DateTime? lastSyncedAt,
    String? source,
  }) async {
    final event = await fetchEvent(eventId, userId: userId);
    if (event == null) {
      return null;
    }
    return updateEvent(event.copyWith(
      externalId: externalId,
      externalCalendarId: externalCalendarId,
      clearExternalCalendarId: externalCalendarId == null,
      externalEtag: externalEtag,
      externalUpdatedAt: externalUpdatedAt,
      lastSyncedAt: lastSyncedAt,
      source: source,
    ));
  }

  Future<EventModel> createEvent(EventModel event);

  /// Atomically creates a personal event and the selected group copies.
  /// Implementations must fail the whole operation if any group share fails.
  Future<EventModel> createEventWithGroupShares(
    EventModel event,
    List<String> groupIds,
  ) =>
      throw UnimplementedError(
        'createEventWithGroupShares is not implemented.',
      );

  /// Atomically updates an owned event and shares it with all selected groups.
  Future<EventModel> updateEventWithGroupShares(
    EventModel event,
    List<String> groupIds,
  ) =>
      throw UnimplementedError(
        'updateEventWithGroupShares is not implemented.',
      );

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
  final startAt = event.startAt;
  if (event.recurrenceRule?.isNotEmpty != true || startAt == null) {
    return <EventModel>[event];
  }

  final localStart = rangeStart.isUtc ? planflowLocal(rangeStart) : rangeStart;
  final localEnd = rangeEnd.isUtc ? planflowLocal(rangeEnd) : rangeEnd;
  final seed = event.copyWith(endAt: eventOverlapEndFor(event));
  final occurrences = expandRecurringEvent(
    event: seed,
    rangeStart: localStart,
    rangeEnd: localEnd,
    includeOccurrence: (occurrence, start, end) => eventRangesOverlap(
      rangeStart: start,
      rangeEnd: end,
      eventStart: occurrence.startAt!,
      eventEnd: occurrence.endAt!,
    ),
  );

  // The common expander emits wall-clock dates. Repository queries compare
  // instants, so normalize expanded copies to the same basis as stored rows.
  return [
    for (final occurrence in occurrences)
      if (identical(occurrence, seed))
        event
      else
        occurrence.copyWith(
          startAt: planflowLocalDateTimeToUtc(occurrence.startAt!),
          endAt: planflowLocalDateTimeToUtc(occurrence.endAt!),
        ),
  ];
}

enum _EventSchema { full, withoutOccurrences, legacy }

@visibleForTesting
Future<List<dynamic>> collectEventPages(
  Future<List<dynamic>> Function(int from, int to) fetchPage,
) async {
  const pageSize = 1000;
  const maximumPages = 500;
  final events = <dynamic>[];
  var offset = 0;
  for (var page = 0; page < maximumPages; page++) {
    final rows = await fetchPage(offset, offset + pageSize - 1);
    // A server row limit can shorten any page. Only an empty page ends the scan.
    if (rows.isEmpty) {
      return events;
    }
    events.addAll(rows);
    offset += rows.length;
  }
  throw StateError(
    'EventRepository reached the $maximumPages-page safety limit '
    'before receiving an empty page.',
  );
}

class SupabaseEventRepository extends EventRepository {
  SupabaseEventRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _tableName = 'events';
  static const String _selectColumnsWithoutOccurrences =
      'id, user_id, title, start_at, end_at, location, location_lat, '
      'location_lng, memo, supplies, supplies_checked, is_critical, use_strong_alarm, source, '
      'participants, targets, '
      'recurrence_rule, is_all_day, is_multi_day, parent_event_id, '
      'group_event_id, category, '
      'external_id, external_calendar_id, external_etag, external_updated_at, '
      'last_synced_at, created_at, updated_at';
  static const String _selectColumns = '$_selectColumnsWithoutOccurrences, '
      'overridden_occurrence_date, deleted_occurrence_dates';
  static const String _legacySelectColumns =
      'id, user_id, title, start_at, end_at, location, location_lat, '
      'location_lng, memo, supplies, supplies_checked, is_critical, source, '
      'external_id, created_at';

  final SupabaseClient _client;
  bool _hasOccurrenceColumns = true;

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
    final ids = <String>{};
    String? afterId;
    while (true) {
      var query = _client
          .from(_tableName)
          .select('id,external_id')
          .eq('user_id', resolvedUserId)
          .eq('source', normalizedSource)
          .not('external_id', 'is', null);
      if (afterId != null) {
        query = query.gt('id', afterId);
      }
      final rows = await query.order('id', ascending: true).limit(1000);
      if (rows.isEmpty) {
        return ids;
      }
      ids.addAll(rows.map((row) => row['external_id'] as String));
      final lastId = rows.last['id'] as String;
      if (lastId == afterId) {
        throw StateError('External event ID pagination did not advance.');
      }
      afterId = lastId;
    }
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
        rangeStart: rangeStart.toUtc(),
        rangeEnd: rangeEnd.toUtc(),
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
  Future<EventModel> createEventWithGroupShares(
    EventModel event,
    List<String> groupIds,
  ) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);
    if (event.id.trim().isEmpty) {
      throw ArgumentError.value(
          event.id, 'event.id', 'Stable event id required.');
    }
    final uniqueGroupIds = groupIds.toSet().toList(growable: false);
    if (uniqueGroupIds.isEmpty) {
      throw ArgumentError.value(
          groupIds, 'groupIds', 'At least one group required.');
    }
    final response = await _client.rpc(
      'create_personal_event_with_groups',
      params: <String, dynamic>{
        'p_event': event.toJson(),
        'p_group_ids': uniqueGroupIds,
      },
    );
    if (response is! Map) {
      throw StateError('일정 생성/그룹 공유 응답 형식이 올바르지 않습니다.');
    }
    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> updateEventWithGroupShares(
    EventModel event,
    List<String> groupIds,
  ) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);
    if (event.id.trim().isEmpty) {
      throw ArgumentError.value(event.id, 'event.id', 'Event id required.');
    }
    final uniqueGroupIds = groupIds.toSet().toList(growable: false);
    if (uniqueGroupIds.isEmpty) {
      throw ArgumentError.value(
          groupIds, 'groupIds', 'At least one group required.');
    }
    final response = await _client.rpc(
      'update_personal_event_with_groups',
      params: <String, dynamic>{
        'p_event': event.toJson(),
        'p_group_ids': uniqueGroupIds,
      },
    );
    if (response is! Map) {
      throw StateError('일정 수정/그룹 공유 응답 형식이 올바르지 않습니다.');
    }
    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);
    if (event.id.trim().isEmpty) {
      throw ArgumentError.value(event.id, 'event.id', 'Event id is required.');
    }

    // 좌표 쌍이 비어온 저장(경로 스냅샷 재저장, 외부 캘린더 동기화 병합 등)
    // 이 저장된 유효 좌표를 지워버리지 않도록, 장소 텍스트가 그대로면
    // 서버에 이미 저장된 좌표를 유지한다. 장소 텍스트가 실제로 바뀌었으면
    // 좌표를 비워 다음 재검색으로 다시 잡게 한다.
    final effectiveEvent = await _preserveStoredCoordinates(
      event,
      resolvedUserId,
    );

    final response = await _updateEventRow(effectiveEvent, resolvedUserId);

    if (response == null) {
      throw StateError('Event not found for the current user.');
    }

    return EventModel.fromJson(_rowAsJson(response));
  }

  /// 저장 요청에 좌표 쌍이 없고 저장된 쌍이 유효하며 장소 텍스트가 같을 때만
  /// 저장된 좌표를 유지한 이벤트를 돌려준다. 그 외에는 요청값 그대로 둔다
  /// (좌표를 새로 만들어내지 않는다).
  Future<EventModel> _preserveStoredCoordinates(
    EventModel event,
    String userId,
  ) async {
    final nextLocation = event.location?.trim() ?? '';
    if (nextLocation.isEmpty) {
      return event.copyWith(clearLocationLat: true, clearLocationLng: true);
    }
    if (event.hasValidLocationCoordinates) {
      return event;
    }
    try {
      final row = await _client
          .from(_tableName)
          .select('location, location_lat, location_lng')
          .eq('id', event.id)
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        return event;
      }
      final resolved = EventModel.resolveCoordinatesForWrite(
        storedLocation: row['location'] as String?,
        storedLat: EventModel.parseCoordinateValue(row['location_lat']),
        storedLng: EventModel.parseCoordinateValue(row['location_lng']),
        nextLocation: event.location,
        nextLat: event.locationLat,
        nextLng: event.locationLng,
      );
      if (!EventModel.hasValidCoordinatePair(
        lat: resolved.lat,
        lng: resolved.lng,
      )) {
        return event.copyWith(clearLocationLat: true, clearLocationLng: true);
      }
      return event.copyWith(
        locationLat: resolved.lat,
        locationLng: resolved.lng,
      );
    } on PostgrestException catch (error) {
      // Do not overwrite a possibly valid stored pair when its preservation
      // read failed. Stop this save instead of silently writing nulls.
      debugPrint(
          'EventRepository coordinate preservation read failed: ${error.code}');
      rethrow;
    }
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
    ).copyWith(source: normalizedSource);

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
  Future<EventModel?> updateExternalSyncMetadata({
    required String eventId,
    String? userId,
    required String externalId,
    required String? externalCalendarId,
    String? externalEtag,
    DateTime? externalUpdatedAt,
    DateTime? lastSyncedAt,
    String? source,
  }) async {
    final resolvedUserId = _resolveCurrentUserId();
    if (userId != null && userId != resolvedUserId) {
      throw StateError(
        'Event userId must match the signed-in user for scoped writes.',
      );
    }
    if (eventId.trim().isEmpty) {
      throw ArgumentError.value(eventId, 'eventId', 'Event id is required.');
    }
    final payload = <String, dynamic>{
      'external_id': externalId,
      'external_calendar_id': externalCalendarId,
      if (externalEtag != null) 'external_etag': externalEtag,
      if (externalUpdatedAt != null)
        'external_updated_at': externalUpdatedAt.toUtc().toIso8601String(),
      if (lastSyncedAt != null)
        'last_synced_at': lastSyncedAt.toUtc().toIso8601String(),
      if (source != null) 'source': source,
    };
    final response = await _withEventSchema(
      (schema) => _client
          .from(_tableName)
          .update(_eventPayload(schema, payload))
          .eq('id', eventId)
          .eq('user_id', resolvedUserId)
          .select(_columnsFor(schema))
          .maybeSingle(),
    );
    return response == null ? null : EventModel.fromJson(_rowAsJson(response));
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

  Future<List<dynamic>> _selectEventsForUser(String userId) => _withEventSchema(
        (schema) => collectEventPages(
          (from, to) => _client
              .from(_tableName)
              .select(_columnsFor(schema))
              .eq('user_id', userId)
              .order('start_at', ascending: true)
              .order('id', ascending: true)
              .range(from, to),
        ),
      );

  Future<Map<String, dynamic>?> _selectEventById(
    String eventId,
    String userId,
  ) =>
      _withEventSchema(
        (schema) => _client
            .from(_tableName)
            .select(_columnsFor(schema))
            .eq('id', eventId)
            .eq('user_id', userId)
            .maybeSingle(),
      );

  Future<Map<String, dynamic>?> _selectEventBySourceExternalId({
    required String source,
    required String externalId,
    required String userId,
  }) =>
      _withEventSchema(
        (schema) => _client
            .from(_tableName)
            .select(_columnsFor(schema))
            .eq('user_id', userId)
            .eq('source', source)
            .eq('external_id', externalId)
            .maybeSingle(),
      );

  Future<Map<String, dynamic>> _insertEvent(EventModel event) {
    final payload = event.toJson(includeId: event.id.trim().isNotEmpty);
    return _withEventSchema(
      (schema) => _client
          .from(_tableName)
          .insert(_eventPayload(schema, payload))
          .select(_columnsFor(schema))
          .single(),
    );
  }

  Future<Map<String, dynamic>?> _updateEventRow(
    EventModel event,
    String userId,
  ) =>
      _withEventSchema(
        (schema) => _client
            .from(_tableName)
            .update(_eventPayload(schema, event.toUpdateJson()))
            .eq('id', event.id)
            .eq('user_id', userId)
            .select(_columnsFor(schema))
            .maybeSingle(),
      );

  Future<Map<String, dynamic>> _upsertEventRow(EventModel event) {
    final payload = event.toJson(includeId: event.id.trim().isNotEmpty);
    return _withEventSchema(
      (schema) => _client
          .from(_tableName)
          .upsert(_eventPayload(schema, payload), onConflict: 'id')
          .select(_columnsFor(schema))
          .single(),
    );
  }

  Future<Map<String, dynamic>?> _updateSuppliesCheckedRow({
    required String eventId,
    required List<String> suppliesChecked,
    required String userId,
  }) =>
      _withEventSchema(
        (schema) => _client
            .from(_tableName)
            .update(<String, dynamic>{'supplies_checked': suppliesChecked})
            .eq('id', eventId)
            .eq('user_id', userId)
            .select(_columnsFor(schema))
            .maybeSingle(),
      );

  String _columnsFor(_EventSchema schema) => switch (schema) {
        _EventSchema.full => _selectColumns,
        _EventSchema.withoutOccurrences => _selectColumnsWithoutOccurrences,
        _EventSchema.legacy => _legacySelectColumns,
      };

  Map<String, dynamic> _eventPayload(
    _EventSchema schema,
    Map<String, dynamic> payload,
  ) =>
      switch (schema) {
        _EventSchema.full => payload,
        _EventSchema.withoutOccurrences => _payloadWithoutOccurrences(payload),
        _EventSchema.legacy => _legacyPayload(payload),
      };

  Map<String, dynamic> _payloadWithoutOccurrences(
      Map<String, dynamic> payload) {
    return Map<String, dynamic>.of(payload)
      ..remove('overridden_occurrence_date')
      ..remove('deleted_occurrence_dates');
  }

  Future<T> _withEventSchema<T>(
    Future<T> Function(_EventSchema schema) request,
  ) async {
    var schema = _hasOccurrenceColumns
        ? _EventSchema.full
        : _EventSchema.withoutOccurrences;
    while (true) {
      try {
        return await request(schema);
      } on PostgrestException catch (error) {
        if (schema == _EventSchema.legacy) {
          rethrow;
        }
        final text =
            '${error.code} ${error.message} ${error.details}'.toLowerCase();
        if (schema == _EventSchema.full &&
            (text.contains('42703') || text.contains('pgrst204')) &&
            (text.contains('overridden_occurrence_date') ||
                text.contains('deleted_occurrence_dates'))) {
          _hasOccurrenceColumns = false;
          schema = _EventSchema.withoutOccurrences;
        } else if (_isMissingSyncSchemaError(text)) {
          schema = _EventSchema.legacy;
        } else {
          rethrow;
        }
      }
    }
  }

  Map<String, dynamic> _legacyPayload(Map<String, dynamic> payload) {
    return _payloadWithoutOccurrences(payload)
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

  bool _isMissingSyncSchemaError(String text) {
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

EventModel _mergeExternalMetadata({
  required EventModel existing,
  required EventModel incoming,
  required String externalId,
  required String? externalCalendarId,
}) {
  // Keep already resolved coordinates when the external location is unchanged.
  final coordinates = EventModel.resolveCoordinatesForWrite(
    storedLocation: existing.location,
    storedLat: existing.locationLat,
    storedLng: existing.locationLng,
    nextLocation: incoming.location,
    nextLat: incoming.locationLat,
    nextLng: incoming.locationLng,
  );
  return existing.copyWith(
    userId: incoming.userId,
    title: incoming.title,
    startAt: incoming.startAt,
    clearStartAt: incoming.startAt == null,
    endAt: incoming.endAt,
    clearEndAt: incoming.endAt == null,
    location: incoming.location,
    clearLocation: incoming.location == null,
    locationLat: coordinates.lat,
    clearLocationLat: coordinates.lat == null,
    locationLng: coordinates.lng,
    clearLocationLng: coordinates.lng == null,
    memo: incoming.memo,
    clearMemo: incoming.memo == null,
    supplies: incoming.supplies,
    suppliesChecked: incoming.suppliesChecked,
    participants: incoming.participants.isEmpty ? null : incoming.participants,
    targets: incoming.targets.isEmpty ? null : incoming.targets,
    isCritical: existing.isCritical || incoming.isCritical,
    useStrongAlarm: existing.useStrongAlarm || incoming.useStrongAlarm,
    recurrenceRule: incoming.recurrenceRule,
    clearRecurrenceRule: incoming.recurrenceRule == null,
    isAllDay: incoming.isAllDay,
    isMultiDay: incoming.isMultiDay,
    parentEventId: incoming.parentEventId,
    clearParentEventId: incoming.parentEventId == null,
    category: incoming.category,
    source: incoming.source,
    externalId: externalId,
    externalCalendarId: externalCalendarId,
    clearExternalCalendarId: externalCalendarId == null,
    externalEtag: incoming.externalEtag,
    externalUpdatedAt: incoming.externalUpdatedAt,
    lastSyncedAt: incoming.lastSyncedAt ?? DateTime.now().toUtc(),
  );
}
