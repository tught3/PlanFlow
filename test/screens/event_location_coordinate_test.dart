import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';

const String _hospital = '원주세브란스기독병원';
const double _lat = 37.3495;
const double _lng = 127.9458;

/// 저장된 일정(좌표 보유) — 서버 행을 흉내낸다.
EventModel _persistedEvent() {
  return EventModel(
    id: 'event-1',
    userId: 'user-1',
    title: '병원 방문',
    startAt: DateTime.utc(2026, 10, 28, 9),
    endAt: DateTime.utc(2026, 10, 28, 10),
    location: _hospital,
    locationLat: _lat,
    locationLng: _lng,
  );
}

/// 알림/위치표시 등 경로에서 넘어오는 부분 스냅샷 — 좌표가 빠져 있다.
EventModel _routeSnapshot() {
  return EventModel(
    id: 'event-1',
    userId: 'user-1',
    title: '병원 방문',
    startAt: DateTime.utc(2026, 10, 28, 9),
    endAt: DateTime.utc(2026, 10, 28, 10),
    location: _hospital,
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.persisted);

  final EventModel persisted;
  int fetchEventCalls = 0;
  EventModel? updatedEvent;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    fetchEventCalls++;
    return persisted;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => [persisted];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvent = event;
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}

/// 지오코딩 호출을 세는 가짜. 호출되면 "재검색 없이 좌표를 유지" 계약 위반.
class _CountingLocationLookupService extends LocationLookupService {
  _CountingLocationLookupService({this.results = const <LocationLookupResult>[]});

  final List<LocationLookupResult> results;
  int searchCalls = 0;

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchCalls++;
    return results;
  }

  @override
  Future<LocationLookupSearchResult> searchWithFallback(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchCalls++;
    return LocationLookupSearchResult(
      originalQuery: query,
      results: results,
      searchedQueries: const <String>[],
      fallbackQueries: const <String>[],
    );
  }
}

void main() {
  group('event location coordinate regression', () {
    testWidgets('편집 화면은 저장된 좌표를 재검색 없이 복구한다', (tester) async {
      final repository = _FakeEventRepository(_persistedEvent());
      final lookup = _CountingLocationLookupService();

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            event: _routeSnapshot(),
            eventRepository: repository,
            locationLookupService: lookup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 서버 행에서 좌표를 복구했다.
      expect(repository.fetchEventCalls, 1);
      final editor = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      expect(editor.locationLat, _lat);
      expect(editor.locationLng, _lng);
      expect(find.text('지도 위치 연결됨'), findsOneWidget);
      expect(find.text('지도 위치 미지정'), findsNothing);
      // 추가 지오코딩(재검색)은 일어나면 안 된다.
      expect(lookup.searchCalls, 0);
    });

    testWidgets('저장된 좌표가 있는 상태에서 장소 텍스트를 그대로 두면 '
        '재검색하지 않는다', (tester) async {
      final repository = _FakeEventRepository(_persistedEvent());
      final lookup = _CountingLocationLookupService();

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            event: _routeSnapshot(),
            eventRepository: repository,
            locationLookupService: lookup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editor = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      editor.onLocationTextChanged?.call(_hospital);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(lookup.searchCalls, 0);
      final refreshed = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      expect(refreshed.locationLat, _lat);
      expect(refreshed.locationLng, _lng);
      expect(find.text('지도 위치 연결됨'), findsOneWidget);
    });

    testWidgets('장소 텍스트를 실제로 바꾸면 좌표를 비운다', (tester) async {
      final repository = _FakeEventRepository(_persistedEvent());
      final lookup = _CountingLocationLookupService();

      await tester.pumpWidget(
        MaterialApp(
          home: EventEditScreen(
            event: _routeSnapshot(),
            eventRepository: repository,
            locationLookupService: lookup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editor = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      editor.onLocationTextChanged?.call('다른 장소');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final refreshed = tester.widget<CalendarStyleEventEditor>(
        find.byType(CalendarStyleEventEditor),
      );
      expect(refreshed.locationLat, isNull);
      expect(refreshed.locationLng, isNull);
      expect(find.text('지도 위치 미지정'), findsOneWidget);
    });

    testWidgets('상세 화면은 저장된 좌표가 있으면 연결됨으로 표시한다',
        (tester) async {
      final repository = _FakeEventRepository(_persistedEvent());

      await tester.pumpWidget(
        MaterialApp(
          home: EventDetailScreen(
            event: _routeSnapshot(),
            eventRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('지도 위치 연결됨'), findsOneWidget);
      expect(find.text('지도 위치 미지정'), findsNothing);
    });

    test('저장 좌표는 장소 텍스트가 같으면 유지하고 바뀌면 비운다', () {
      final preserved = EventEditScreen.resolveCoordinatesForSave(
        currentLat: null,
        currentLng: null,
        storedLat: _lat,
        storedLng: _lng,
        storedLocation: _hospital,
        currentLocation: _hospital,
      );
      expect(preserved.lat, _lat);
      expect(preserved.lng, _lng);

      final cleared = EventEditScreen.resolveCoordinatesForSave(
        currentLat: null,
        currentLng: null,
        storedLat: _lat,
        storedLng: _lng,
        storedLocation: _hospital,
        currentLocation: '다른 장소',
      );
      expect(cleared.lat, isNull);
      expect(cleared.lng, isNull);

      final replaced = EventEditScreen.resolveCoordinatesForSave(
        currentLat: 35.1,
        currentLng: 129.0,
        storedLat: _lat,
        storedLng: _lng,
        storedLocation: _hospital,
        currentLocation: _hospital,
      );
      expect(replaced.lat, 35.1);
      expect(replaced.lng, 129.0);
    });
  });
}
