import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import '../core/startup_route_gate.dart';

class EventPrefetchService {
  EventPrefetchService._();

  static final EventPrefetchService _instance = EventPrefetchService._();

  factory EventPrefetchService() => _instance;

  static const Duration defaultMaxAge = Duration(minutes: 3);

  final Map<String, _EventPrefetchEntry> _cacheByUserId =
      <String, _EventPrefetchEntry>{};
  final Set<String> _warmingUserIds = <String>{};

  Future<void> warmUp(
    String userId, {
    EventRepository? repository,
  }) async {
    final resolvedUserId = userId.trim();
    if (resolvedUserId.isEmpty || _warmingUserIds.contains(resolvedUserId)) {
      return;
    }
    // Claim before the first await so auth listeners cannot enqueue duplicate
    // warmups for the same user while onboarding is still deferred.
    _warmingUserIds.add(resolvedUserId);
    await startupRouteGate.startupWorkAllowedWhenIdle;
    try {
      final events = await (repository ?? EventRepository.supabase())
          .listEvents(userId: resolvedUserId);
      // A transient empty/partial warm-up response must not erase a fresh
      // snapshot that the CalendarScreen can already render immediately.
      // The screen performs the same protection for its foreground reload;
      // keeping it here prevents the app-start path from poisoning that
      // first-frame cache before the user opens the calendar.
      final existing = getCached(resolvedUserId);
      if (existing != null && existing.isNotEmpty && events.length <= 1) {
        final byId = <String, EventModel>{
          for (final event in existing)
            if (event.id.trim().isNotEmpty) event.id: event,
          for (final event in events)
            if (event.id.trim().isNotEmpty) event.id: event,
        };
        store(resolvedUserId, byId.values.toList(growable: false));
      } else {
        store(resolvedUserId, events);
      }
    } catch (error, stackTrace) {
      debugPrint('Event prefetch skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _warmingUserIds.remove(resolvedUserId);
    }
  }

  List<EventModel>? getCached(String userId,
      {Duration maxAge = defaultMaxAge}) {
    final entry = _cacheByUserId[userId.trim()];
    if (entry == null || !entry.isFresh(maxAge)) {
      return null;
    }
    return List<EventModel>.of(entry.events);
  }

  bool isFresh(String userId, {Duration maxAge = defaultMaxAge}) {
    return _cacheByUserId[userId.trim()]?.isFresh(maxAge) ?? false;
  }

  void store(String userId, List<EventModel> events) {
    final resolvedUserId = userId.trim();
    if (resolvedUserId.isEmpty) {
      return;
    }
    _cacheByUserId[resolvedUserId] = _EventPrefetchEntry(
      events: List<EventModel>.of(events),
      fetchedAt: DateTime.now(),
    );
  }

  void invalidate({String? userId}) {
    final resolvedUserId = userId?.trim();
    if (resolvedUserId != null && resolvedUserId.isNotEmpty) {
      _cacheByUserId.remove(resolvedUserId);
      _warmingUserIds.remove(resolvedUserId);
      return;
    }
    _cacheByUserId.clear();
    _warmingUserIds.clear();
  }
}

class _EventPrefetchEntry {
  const _EventPrefetchEntry({
    required this.events,
    required this.fetchedAt,
  });

  final List<EventModel> events;
  final DateTime fetchedAt;

  bool isFresh(Duration maxAge) {
    return DateTime.now().difference(fetchedAt) <= maxAge;
  }
}
