import 'package:supabase_flutter/supabase_flutter.dart';

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

class SupabaseEventRepository extends EventRepository {
  SupabaseEventRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _tableName = 'events';
  static const String _selectColumns =
      'id, user_id, title, start_at, end_at, location, location_lat, '
      'location_lng, memo, supplies, supplies_checked, is_critical, source, '
      'recurrence_rule, is_all_day, is_multi_day, parent_event_id, category, '
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

    final mergedEvent = EventModel(
      id: existing.id,
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
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
      category: event.category,
      source: normalizedSource,
      externalId: normalizedExternalId,
      externalCalendarId: event.externalCalendarId,
      externalEtag: event.externalEtag,
      externalUpdatedAt: event.externalUpdatedAt,
      lastSyncedAt: event.lastSyncedAt,
      createdAt: existing.createdAt,
      updatedAt: existing.updatedAt,
    );

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
      ..remove('recurrence_rule')
      ..remove('is_all_day')
      ..remove('is_multi_day')
      ..remove('parent_event_id')
      ..remove('category')
      ..remove('updated_at');
  }

  bool _isMissingSyncSchemaError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return text.contains('external_calendar_id') ||
        text.contains('external_etag') ||
        text.contains('external_updated_at') ||
        text.contains('last_synced_at') ||
        text.contains('recurrence_rule') ||
        text.contains('is_all_day') ||
        text.contains('is_multi_day') ||
        text.contains('parent_event_id') ||
        text.contains('category') ||
        text.contains('updated_at') ||
        text.contains('pgrst204') ||
        text.contains('42703');
  }
}
