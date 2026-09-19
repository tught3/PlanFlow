import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/location/location_picker_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 검색 요청을 Completer로 통제하는 가짜 서비스 (테스트 전용).
class _ControlledLocationLookupService extends LocationLookupService {
  _ControlledLocationLookupService();

  final List<Completer<LocationLookupSearchResult>> requests = [];

  @override
  Future<LocationLookupSearchResult> searchWithFallback(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) {
    final completer = Completer<LocationLookupSearchResult>();
    requests.add(completer);
    return completer.future;
  }

  void completeLatest(List<LocationLookupResult> results) {
    requests.last.complete(
      LocationLookupSearchResult(
        originalQuery: 'anything',
        results: results,
        searchedQueries: const <String>[],
        fallbackQueries: const <String>[],
      ),
    );
  }
}

LocationLookupResult result(String name) => LocationLookupResult(
      name: name,
      address: '테스트 주소 $name',
      latitude: 37.5,
      longitude: 127.0,
    );

Future<void> _pumpPicker(
  WidgetTester tester,
  _ControlledLocationLookupService service,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    MaterialApp(
      home: LocationPickerScreen(
        initialQuery: '첫검색어',
        locationLookupService: service,
      ),
    ),
  );
  // initState의 post-frame 초기 검색 실행 대기.
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildAppleMapsUri (순수 URL 로직)', () {
    test('좌표가 있는 선택 장소는 q=장소명&ll=위도,경도 형태로 만든다', () {
      final uri = buildAppleMapsUri(
        queryText: '검색어',
        selected: result('스타벅스 본점'),
      );
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters['q'], '스타벅스 본점');
      expect(uri.queryParameters['ll'], '37.500000,127.000000');
    });

    test('선택 장소가 없으면 q=검색어 형태로 만든다', () {
      final uri = buildAppleMapsUri(queryText: '강남역 맛집');
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters['q'], '강남역 맛집');
      expect(uri.queryParameters.containsKey('ll'), isFalse);
    });
  });

  group('위치 선택 화면 검색 타임아웃/stale 응답', () {
    testWidgets('검색이 상한(12초)을 넘으면 스피너가 지워지고 재시도 안내가 뜬다',
        (tester) async {
      final service = _ControlledLocationLookupService();
      await _pumpPicker(tester, service);
      expect(service.requests, hasLength(1));
      expect(find.byKey(const ValueKey('location-search-button')), findsOneWidget);

      // 응답 없이 상한 시간 경과.
      await tester.pump(kLocationSearchTimeout);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('중단했어요'), findsOneWidget);
      // 타임아웃 후에도 검색 버튼은 재사용 가능(활성)해야 한다.
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('location-search-button')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('타임아웃 이후 늦게 도착한 응답은 화면을 덮어쓰지 않는다', (tester) async {
      final service = _ControlledLocationLookupService();
      await _pumpPicker(tester, service);
      await tester.pump(kLocationSearchTimeout);
      await tester.pump();
      expect(find.textContaining('중단했어요'), findsOneWidget);

      service.completeLatest([result('늦게도착한장소')]);
      await tester.pump();
      await tester.pump();

      expect(find.text('늦게도착한장소'), findsNothing);
      expect(find.textContaining('중단했어요'), findsOneWidget);
    });

    testWidgets('이전 쿼리의 늦은 응답이 새 쿼리 결과를 덮어쓰지 않는다', (tester) async {
      final service = _ControlledLocationLookupService();
      await _pumpPicker(tester, service);
      expect(service.requests, hasLength(1));

      // 초기 검색이 타임아웃으로 중단된 뒤 (버튼 재활성화) 새 쿼리 검색.
      await tester.pump(kLocationSearchTimeout);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('location-search-field')),
        '새쿼리',
      );
      await tester.tap(find.byKey(const ValueKey('location-search-button')));
      await tester.pump();
      expect(service.requests, hasLength(2));

      // 이전 쿼리 응답이 늦게 도착 → 폐기되어야 한다.
      service.requests.first.complete(
          LocationLookupSearchResult(
            originalQuery: '첫검색어',
            results: [result('오래된응답장소')],
            searchedQueries: const <String>[],
            fallbackQueries: const <String>[],
          ),
        );
      await tester.pump();
      await tester.pump();

      expect(find.text('오래된응답장소'), findsNothing);

      // 새 쿼리 응답은 정상 반영된다.
      service.completeLatest([result('새응답장소')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('새응답장소'), findsWidgets);
    });
  });
}
