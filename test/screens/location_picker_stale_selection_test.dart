import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/location/location_picker_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';

/// 항상 빈 결과를 돌려주는 가짜 서비스 (테스트 전용).
class _EmptyLocationLookupService extends LocationLookupService {
  @override
  Future<LocationLookupSearchResult> searchWithFallback(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    return LocationLookupSearchResult(
      originalQuery: query,
      results: const <LocationLookupResult>[],
      searchedQueries: const <String>[],
      fallbackQueries: const <String>[],
    );
  }
}

void main() {
  LocationLookupResult result(String name) => LocationLookupResult(
        name: name,
        address: '테스트 주소 $name',
        latitude: 37.5,
        longitude: 127.0,
      );

  group('resolveSelectionAfterSearch (순수 상태 로직)', () {
    test('new search with results always selects the first result', () {
      final previous = result('이전장소');
      final fresh = resolveSelectionAfterSearch(
        currentSelected: previous,
        currentSelectedIsManual: false,
        currentSelectedForQuery: '이전쿼리',
        query: '새쿼리',
        results: [result('후보1'), result('후보2')],
      );
      expect(fresh?.name, '후보1');
    });

    test('stale search-result selection is cleared when a new query returns '
        'no results', () {
      final stale = result('이전쿼리의결과');
      final cleared = resolveSelectionAfterSearch(
        currentSelected: stale,
        currentSelectedIsManual: false,
        currentSelectedForQuery: '이전쿼리',
        query: '새쿼리',
        results: const <LocationLookupResult>[],
      );
      expect(cleared, isNull);
    });

    test('manual map selection made for the current query survives an empty '
        'search', () {
      final manual = LocationLookupResult(
        name: '새쿼리',
        address: '지도에서 직접 선택한 위치',
        latitude: 36.1,
        longitude: 128.4,
        provider: LocationLookupProvider.manual,
      );
      final kept = resolveSelectionAfterSearch(
        currentSelected: manual,
        currentSelectedIsManual: true,
        currentSelectedForQuery: '새쿼리',
        query: '새쿼리',
        results: const <LocationLookupResult>[],
      );
      expect(kept, same(manual));
    });

    test('manual map selection from an older query is cleared by a new '
        'query with no results', () {
      final oldManual = LocationLookupResult(
        name: '오래된쿼리',
        address: '지도에서 직접 선택한 위치',
        latitude: 36.1,
        longitude: 128.4,
        provider: LocationLookupProvider.manual,
      );
      final cleared = resolveSelectionAfterSearch(
        currentSelected: oldManual,
        currentSelectedIsManual: true,
        currentSelectedForQuery: '오래된쿼리',
        query: '새쿼리',
        results: const <LocationLookupResult>[],
      );
      expect(cleared, isNull);
    });

    test('a query change never relabels an old coordinate: old result is '
        'dropped, not renamed', () {
      final old = result('옛장소');
      final next = resolveSelectionAfterSearch(
        currentSelected: old,
        currentSelectedIsManual: false,
        currentSelectedForQuery: '옛쿼리',
        query: '새쿼리',
        results: const <LocationLookupResult>[],
      );
      // 좌표가 남더라도 이름이 새 쿼리로 바뀌면 안 되므로 아예 무효화.
      expect(next, isNull);
    });
  });

  testWidgets(
      'LocationPickerScreen clears stale selection UI after an empty search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '대전 성심당',
          canUseInAppMapOverride: false,
          initialResults: const <LocationLookupResult>[
            LocationLookupResult(
              name: '성심당 본점',
              address: '대전 중구 대종로480번길 15',
              latitude: 36.327,
              longitude: 127.427,
              provider: LocationLookupProvider.tmap,
            ),
          ],
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 초기 상태: 선택이 있고 확정 버튼 활성.
    expect(find.text('성심당 본점'), findsWidgets);
    final confirmBefore =
        tester.widget<FilledButton>(find.ancestor(
      of: find.text('이 위치 사용'),
      matching: find.byType(FilledButton),
    ));
    expect(confirmBefore.onPressed, isNotNull);

    // 새 쿼리로 검색 → 결과 없음 → 이전 선택은 무효화되어야 한다.
    await tester.enterText(
      find.byKey(const ValueKey('location-search-field')),
      '존재하지않는장소',
    );
    await tester.tap(find.byKey(const ValueKey('location-search-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('검색 결과가 없어요. 장소명을 더 구체적으로 입력하거나 외부 지도에서 먼저 확인해 주세요.'),
      findsOneWidget,
    );
    // 선택 라벨이 사라지고 확정 버튼이 비활성화된다.
    expect(find.text('성심당 본점'), findsNothing);
    final confirmAfter =
        tester.widget<FilledButton>(find.ancestor(
      of: find.text('이 위치 사용'),
      matching: find.byType(FilledButton),
    ));
    expect(confirmAfter.onPressed, isNull);
  });
}
