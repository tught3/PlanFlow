import 'package:flutter/foundation.dart';

import '../core/diag_logger.dart';
import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
import 'departure_alarm_service.dart';
import 'location_lookup_service.dart';
import 'travel_time_buffer_service.dart';

class EventPreparationService {
  /// 목적지 후보 쿼리(_buildDestinationSearchQueries) 중 실제로 시도할 최대 개수.
  /// 쿼리 하나가 미해결이면 LocationLookupService 내부 fallback으로 tmap POI를
  /// 최대 6콜까지 쓴다(_maxFallbackQueries=5, 1+5). 6개 쿼리를 전부 시도하면
  /// 이벤트 1건 저장만으로 최대 36콜까지 치솟아 60/60s 레이트리밋을 혼자
  /// 절반 이상 잡아먹는다(실측: window_count=60 폭주 신고, 2026-07-04).
  /// location/title/memo 단독 쿼리(성공 확률 높음) 3개만 시도하고, 조합형
  /// 쿼리 3개(성공 확률 낮음)는 시도하지 않는다 — 최대 18콜로 절반 이하로 캡.
  static const int _maxDestinationQueries = 3;

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
      final logMsg =
          'departure_alarm event=${preparedEvent.id} '
          'location=${preparedEvent.location ?? 'none'} '
          'lat=${preparedEvent.locationLat} lng=${preparedEvent.locationLng} '
          'scheduled=${departureResult.isScheduled} '
          'reason=${departureResult.skippedReason ?? 'ok'} '
          'travel=${departureResult.travelMinutes ?? 'n/a'}';
      DiagLogger.log('EventPrep', logMsg);
      debugPrint('Event preparation $logMsg');
    } catch (error, stackTrace) {
      DiagLogger.log('EventPrep', 'departure_alarm error: $error');
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

    // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
    // 사용자가 장소를 적지 않았으면(location이 null/빈 문자열) 좌표 해석을
    // 절대 시도하지 않는다. 과거에는 이 가드가 없어 _buildDestinationSearchQueries가
    // event.title/event.memo를 장소 검색어로 대신 써버렸고, "회의"처럼 흔한
    // 제목이 현재 GPS 근접 편향 때문에 "성남 청년회의소" 같은 무관한 POI와
    // 부분일치해 개인 일정 location에 유령 장소가 기록됐다. 장소를 안 적은
    // 사용자 의도를 존중해 여기서 즉시 반환한다(현재 위치 조회·검색·
    // updateEvent 전부 스킵).
    final rawLocation = event.location;
    if (rawLocation == null || rawLocation.trim().isEmpty) {
      return event;
    }

    final origin = await AppPermissionService()
        .getCurrentLocationWithPermission(requestIfMissing: false);
    for (final query
        in _buildDestinationSearchQueries(event).take(_maxDestinationQueries)) {
      final candidates = await _locations.search(query, origin: origin);
      if (candidates.isEmpty) {
        continue;
      }

      final selected = candidates.first;
      // selected.name으로 location을 덮어쓰지 않고 사용자가 적은 원문 location을
      // 유지한다. 이 경로는 이미 event.location이 비어있지 않은 경우에만 실행되므로
      // (위 가드), 사용자가 실제로 입력한 장소 텍스트가 존재한다 — POI 검색 결과의
      // 공식명(selected.name)으로 바꿔치기하면 사용자가 알아보기 쉬운 표현(예: 상호
      // 줄임말·별칭)이 검색 API의 정식 명칭으로 대체되어 되레 혼란을 줄 수 있다.
      // 좌표(lat/lng)만 붙이는 것이 최소 변경이며 더 안전하다.
      final updated = _copyEvent(
        event,
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

  // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
  // event.title/event.memo는 더 이상 장소 검색어로 쓰지 않는다. 이 서비스의
  // 정당한 목적은 "사용자가 이름으로 적은 장소"(event.location)에 좌표를
  // 붙이는 것뿐이다. title/memo는 사용자가 장소로 의도하지 않은 자유 텍스트라
  // 검색어로 쓰면 무관한 POI가 부분일치로 뽑혀 location에 잘못 기록될 수 있다
  // (실증: "회의" 제목이 "성남 청년회의소"와 부분일치해 유령 주입). 어차피
  // event.location이 비어있으면 _ensureLocationCoordinates가 이 함수를 호출하기
  // 전에 이미 반환하므로, 여기서는 항상 location이 존재하는 상태에서만 호출된다.
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
