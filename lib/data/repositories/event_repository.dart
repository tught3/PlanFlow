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

  Future<EventModel> createEvent(EventModel event);

  Future<EventModel> updateEvent(EventModel event);

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

class SupabaseEventRepository extends EventRepository {
  SupabaseEventRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _tableName = 'events';
  static const String _selectColumns =
      'id, user_id, title, start_at, end_at, location, location_lat, location_lng, memo, supplies, is_critical, source, external_id, created_at';

  final SupabaseClient _client;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    final resolvedUserId = _resolveUserId(userId);
    final response = await _client
        .from(_tableName)
        .select(_selectColumns)
        .eq('user_id', resolvedUserId)
        .order('start_at');

    final rows = response as List<dynamic>;
    return rows
        .map((row) => EventModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    final resolvedUserId = _resolveUserId(userId);
    final response = await _client
        .from(_tableName)
        .select(_selectColumns)
        .eq('id', eventId)
        .eq('user_id', resolvedUserId)
        .maybeSingle();

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

    final response = await _client
        .from(_tableName)
        .select(_selectColumns)
        .eq('user_id', resolvedUserId)
        .eq('source', normalizedSource)
        .eq('external_id', normalizedExternalId)
        .maybeSingle();

    if (response == null) {
      return null;
    }
    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);

    final payload = event.toJson(includeId: event.id.trim().isNotEmpty);
    final response = await _client
        .from(_tableName)
        .insert(payload)
        .select(_selectColumns)
        .single();

    return EventModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);
    if (event.id.trim().isEmpty) {
      throw ArgumentError.value(event.id, 'event.id', 'Event id is required.');
    }

    final response = await _client
        .from(_tableName)
        .update(event.toJson())
        .eq('id', event.id)
        .eq('user_id', resolvedUserId)
        .select(_selectColumns)
        .maybeSingle();

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
      isCritical: event.isCritical,
      source: normalizedSource,
      externalId: normalizedExternalId,
      createdAt: existing.createdAt,
    );

    return updateEvent(mergedEvent);
  }

  @override
  Future<EventModel> upsertEvent(EventModel event) async {
    final resolvedUserId = _resolveCurrentUserId();
    _validateWritableEvent(event, resolvedUserId);

    final response = await _client
        .from(_tableName)
        .upsert(
          event.toJson(includeId: event.id.trim().isNotEmpty),
          onConflict: 'id',
        )
        .select(_selectColumns)
        .single();

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
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError('A signed-in user is required for event writes.');
    }
    return userId;
  }

  String _resolveUserId(String? userId) {
    final resolvedUserId = userId ?? _client.auth.currentUser?.id;
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
}
