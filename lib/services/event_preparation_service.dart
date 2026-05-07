import 'package:flutter/foundation.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'departure_alarm_service.dart';
import 'location_lookup_service.dart';
import 'travel_time_buffer_service.dart';

class EventPreparationService {
  const EventPreparationService({
    EventRepository? eventRepository,
    LocationLookupService? locationLookupService,
    TravelTimeBufferService? travelTimeBufferService,
    DepartureAlarmService? departureAlarmService,
  })  : _eventRepository = eventRepository,
        _locationLookupService = locationLookupService,
        _travelTimeBufferService = travelTimeBufferService,
        _departureAlarmService = departureAlarmService;

  final EventRepository? _eventRepository;
  final LocationLookupService? _locationLookupService;
  final TravelTimeBufferService? _travelTimeBufferService;
  final DepartureAlarmService? _departureAlarmService;

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();
  LocationLookupService get _locations =>
      _locationLookupService ?? LocationLookupService();
  TravelTimeBufferService get _travelTime =>
      _travelTimeBufferService ?? TravelTimeBufferService();
  DepartureAlarmService get _departureAlarms =>
      _departureAlarmService ?? const DepartureAlarmService();

  Future<EventPreparationResult> prepareAfterSave(EventModel event) async {
    var preparedEvent = event;
    var locationResolved = false;
    var travelEstimateCount = 0;

    try {
      preparedEvent = await _ensureLocationCoordinates(preparedEvent);
      locationResolved = preparedEvent.locationLat != event.locationLat ||
          preparedEvent.locationLng != event.locationLng;
    } catch (error, stackTrace) {
      debugPrint('Event preparation location lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      final departureResult =
          await _departureAlarms.scheduleForEvent(preparedEvent);
      debugPrint(
        'Event preparation departure alarm: event=${preparedEvent.id} '
        'scheduled=${departureResult.isScheduled} '
        'reason=${departureResult.skippedReason ?? 'scheduled'} '
        'travel=${departureResult.travelMinutes ?? 'n/a'}',
      );
    } catch (error, stackTrace) {
      debugPrint('Event preparation departure alarm skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      travelEstimateCount = await _precomputeAdjacentTravel(preparedEvent);
    } catch (error, stackTrace) {
      debugPrint('Event preparation adjacent travel skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    return EventPreparationResult(
      event: preparedEvent,
      locationResolved: locationResolved,
      travelEstimateCount: travelEstimateCount,
    );
  }

  Future<EventModel> _ensureLocationCoordinates(EventModel event) async {
    final location = event.location?.trim();
    if (location == null ||
        location.isEmpty ||
        (event.locationLat != null && event.locationLng != null)) {
      return event;
    }

    final candidates = await _locations.search(location);
    if (candidates.isEmpty) {
      return event;
    }

    final selected = candidates.first;
    final updated = _copyEvent(
      event,
      location: selected.name.isNotEmpty ? selected.name : event.location,
      locationLat: selected.latitude,
      locationLng: selected.longitude,
    );
    return _events.updateEvent(updated);
  }

  Future<int> _precomputeAdjacentTravel(EventModel event) async {
    final startAt = event.startAt;
    final lat = event.locationLat;
    final lng = event.locationLng;
    if (startAt == null || lat == null || lng == null) {
      return 0;
    }

    final sameDay =
        (await _events.listEvents(userId: event.userId)).where((candidate) {
      final candidateStart = candidate.startAt;
      return candidate.id != event.id &&
          candidateStart != null &&
          candidateStart.year == startAt.year &&
          candidateStart.month == startAt.month &&
          candidateStart.day == startAt.day &&
          candidate.locationLat != null &&
          candidate.locationLng != null;
    }).toList(growable: false)
          ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    EventModel? previous;
    EventModel? next;
    for (final candidate in sameDay) {
      if (candidate.startAt!.isBefore(startAt)) {
        previous = candidate;
        continue;
      }
      if (candidate.startAt!.isAfter(startAt)) {
        next = candidate;
        break;
      }
    }

    var computed = 0;
    if (previous != null) {
      await _logTravelEstimate(
        origin: previous,
        destination: event,
      );
      computed += 1;
    }
    if (next != null) {
      await _logTravelEstimate(
        origin: event,
        destination: next,
      );
      computed += 1;
    }
    return computed;
  }

  Future<void> _logTravelEstimate({
    required EventModel origin,
    required EventModel destination,
  }) async {
    final originLat = origin.locationLat;
    final originLng = origin.locationLng;
    final destinationLat = destination.locationLat;
    final destinationLng = destination.locationLng;
    if (originLat == null ||
        originLng == null ||
        destinationLat == null ||
        destinationLng == null) {
      return;
    }
    final estimate = await _travelTime.estimateWithMapApis(
      originLat: originLat,
      originLng: originLng,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      locationText: destination.location,
    );
    debugPrint(
      'Event preparation travel estimate: '
      '${origin.title} -> ${destination.title} '
      '${estimate.minutes}m source=${estimate.source.name}',
    );
  }

  EventModel _copyEvent(
    EventModel event, {
    String? location,
    double? locationLat,
    double? locationLng,
  }) {
    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: location ?? event.location,
      locationLat: locationLat ?? event.locationLat,
      locationLng: locationLng ?? event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      isCritical: event.isCritical,
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
}

class EventPreparationResult {
  const EventPreparationResult({
    required this.event,
    required this.locationResolved,
    required this.travelEstimateCount,
  });

  final EventModel event;
  final bool locationResolved;
  final int travelEstimateCount;
}
