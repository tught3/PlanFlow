import 'package:flutter/foundation.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
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

  /// [resolveCoordinates] 가 false이면 좌표 해석(TMAP POI 검색)을 건너뛰고
  /// 이미 좌표가 있는 일정만 알람 처리한다. 백그라운드 알람 재계산
  /// (calendar_auto_sync / recalculateAlarmsForEvents / refreshUpcoming) 처럼
  /// 사용자가 직접 저장하지 않는 모든 호출은 반드시 false로 설정해야 한다.
  ///
  /// 좌표 해석에 실패한 일정은 좌표가 저장되지 않으므로, 백그라운드 동기화가
  /// 돌 때마다(앱 시작·resume·주기) 그 일정의 POI 검색이 무한 반복돼
  /// TMAP POI API 호출이 하루 수만 회로 폭주(네트워크/CPU 폭주 → 삼성 강제종료)한다.
  /// POI 검색은 foreground 사용자 저장(prepareAfterSave 기본 호출)에서 1회성으로만 수행한다.
  Future<EventPreparationResult> prepareAfterSave(
    EventModel event, {
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    bool resolveCoordinates = true,
  }) async {
    var preparedEvent = event;
    var locationResolved = false;
    var travelEstimateCount = 0;

    if (resolveCoordinates) {
      try {
        preparedEvent = await _ensureLocationCoordinates(preparedEvent);
        locationResolved = preparedEvent.locationLat != event.locationLat ||
            preparedEvent.locationLng != event.locationLng;
      } catch (error, stackTrace) {
        debugPrint('Event preparation location lookup skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    try {
      final departureResult = await _departureAlarms.scheduleForEvent(
        preparedEvent,
        safetyMarginOverride: departureSafetyMargin,
        // 백그라운드(resolveCoordinates=false)면 라이브 GPS·routes API를 모두 건너뛴다.
        cacheOnlyLocation: !resolveCoordinates,
      );
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

    // 인접 일정 이동시간 사전계산은 routes API를 부르므로 foreground 저장 때만 수행.
    // 백그라운드(resolveCoordinates=false)에선 건너뛰어 API 폭주를 막는다.
    if (resolveCoordinates) {
      try {
        travelEstimateCount = await _precomputeAdjacentTravel(preparedEvent);
      } catch (error, stackTrace) {
        debugPrint('Event preparation adjacent travel skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    return EventPreparationResult(
      event: preparedEvent,
      locationResolved: locationResolved,
      travelEstimateCount: travelEstimateCount,
    );
  }

  Future<EventModel> _ensureLocationCoordinates(EventModel event) async {
    if (event.locationLat != null && event.locationLng != null) {
      return event;
    }

    final origin = await AppPermissionService()
        .getCurrentLocationWithPermission(requestIfMissing: false);
    for (final query in _buildDestinationSearchQueries(event)) {
      final candidates = await _locations.search(query, origin: origin);
      if (candidates.isEmpty) {
        continue;
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

    return event;
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
          planflowIsSameLocalDay(candidateStart, startAt) &&
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

  List<String> _buildDestinationSearchQueries(EventModel event) {
    final queries = <String>[];
    void addQuery(String? value) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) {
        return;
      }
      if (queries.contains(normalized)) {
        return;
      }
      queries.add(normalized);
    }

    addQuery(event.location);
    addQuery(event.title);
    addQuery(event.memo);
    addQuery([
      event.location,
      event.title,
    ].whereType<String>().join(' '));
    addQuery([
      event.title,
      event.memo,
    ].whereType<String>().join(' '));
    addQuery([
      event.location,
      event.memo,
    ].whereType<String>().join(' '));
    return queries;
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
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: event.recurrenceRule,
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
