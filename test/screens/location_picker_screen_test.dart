import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/location/location_picker_screen.dart';
import 'package:planflow/services/location_lookup_service.dart';

void main() {
  testWidgets(
      'LocationPickerScreen shows fallback when in-app map is unavailable with one candidate',
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

    expect(find.text('지도에서 장소 선택'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('location-search-field')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('location-search-button')), findsOneWidget);
    expect(find.textContaining('앱 안 지도를 열 수 없습니다.'), findsOneWidget);
    expect(find.textContaining('아래 장소 후보를 선택하거나 외부 지도'), findsOneWidget);
    expect(find.text('Google 지도'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(find.text('TMAP'), findsWidgets);
    expect(find.text('성심당 본점'), findsWidgets);
    expect(
      find.text('현재 검색된 후보가 없어요. 검색어를 바꿔보거나 지도에서 직접 선택해 주세요.'),
      findsNothing,
    );
    expect(
        find.byKey(const ValueKey('location-candidates-hint')), findsNothing);
    expect(find.byKey(const ValueKey('location-candidates-scroll-left')),
        findsNothing);
    expect(find.byKey(const ValueKey('location-candidates-scroll-right')),
        findsNothing);
    expect(find.byType(ChoiceChip), findsAtLeastNWidgets(1));
    expect(find.text('이 위치 사용'), findsOneWidget);
  });

  testWidgets(
      'LocationPickerScreen gives non-map guidance for empty search and hides candidate scroll controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '',
          canUseInAppMapOverride: false,
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );

    final searchField = find.byKey(const ValueKey('location-search-field'));
    final searchButton = find.byKey(const ValueKey('location-search-button'));
    await tester.enterText(searchField, '없는장소');
    await tester.showKeyboard(searchField);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    expect(searchButton, findsOneWidget);
    expect(
      find.text('검색 결과가 없어요. 장소명을 더 구체적으로 입력하거나 외부 지도에서 먼저 확인해 주세요.'),
      findsOneWidget,
    );
    expect(find.textContaining('앱 안 지도를 열 수 없습니다.'), findsOneWidget);
    expect(
      find.text('현재 검색된 후보가 없어요. 검색어를 바꿔보거나 지도에서 직접 선택해 주세요.'),
      findsOneWidget,
    );
    expect(
        find.byKey(const ValueKey('location-candidates-hint')), findsNothing);
    expect(find.byKey(const ValueKey('location-candidates-scroll-left')),
        findsNothing);
    expect(find.byKey(const ValueKey('location-candidates-scroll-right')),
        findsNothing);
    expect(find.text('Google 지도'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(find.text('TMAP'), findsWidgets);
  });

  testWidgets('LocationPickerScreen preserves initial auth failure guidance',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '서울역',
          initialMessage: '네이버 지도 API 인증 또는 서비스 권한을 확인해 주세요.',
          canUseInAppMapOverride: false,
          locationLookupService: _ThrowingLocationLookupService(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.text('네이버 지도 API 인증 또는 서비스 권한을 확인해 주세요.'),
      findsOneWidget,
    );
    expect(find.textContaining('장소 검색에 실패했어요'), findsNothing);
  });

  testWidgets('LocationPickerScreen shows lookup exception message on search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '',
          canUseInAppMapOverride: false,
          locationLookupService: _ThrowingLocationLookupService(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '서울역');
    await tester.tap(find.widgetWithText(FilledButton, '검색'));
    await tester.pumpAndSettle();

    expect(
      find.text('네이버 지도 API 인증 또는 서비스 권한을 확인해 주세요.'),
      findsOneWidget,
    );
    expect(find.textContaining('장소 검색에 실패했어요'), findsNothing);
  });

  testWidgets(
      'LocationPickerScreen shows map-unavailable fallback when map readiness is forced to timeout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '서울역',
          debugForceMapUnavailableTimeout: true,
          initialResults: const <LocationLookupResult>[
            LocationLookupResult(
              name: '서울역',
              address: '서울특별시 용산구 한강대로 405',
              latitude: 37.5559,
              longitude: 126.9723,
              provider: LocationLookupProvider.tmap,
            ),
          ],
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining('지도 화면이 아직 열리지 않았어요.'), findsAtLeastNWidgets(1));
    expect(find.text('이 위치 사용'), findsOneWidget);
    expect(find.text('서울역'), findsWidgets);
    expect(find.text('Google 지도'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(find.text('TMAP'), findsWidgets);
    expect(
        find.byKey(const ValueKey('location-candidates-hint')), findsNothing);
  });

  testWidgets(
      'LocationPickerScreen shows candidate scroll hint and chevrons when multiple candidates exist',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const first = LocationLookupResult(
      name: '잠실역',
      address: '서울특별시 송파구 잠실동',
      latitude: 37.513,
      longitude: 127.100,
      provider: LocationLookupProvider.tmap,
    );
    const second = LocationLookupResult(
      name: '잠실야구장',
      address: '서울특별시 송파구 잠실',
      latitude: 37.511,
      longitude: 127.072,
      provider: LocationLookupProvider.naver,
    );
    const third = LocationLookupResult(
      name: '롯데월드',
      address: '서울특별시 송파구 잠실동',
      latitude: 37.511,
      longitude: 127.098,
      provider: LocationLookupProvider.google,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '잠실',
          canUseInAppMapOverride: false,
          initialResults: const <LocationLookupResult>[first, second, third],
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('location-candidates-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('location-candidates-scroll-left')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('location-candidates-scroll-right')),
        findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('location-candidates-scroll-left')))
            .onPressed,
        isNotNull);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('location-candidates-scroll-right')))
            .onPressed,
        isNotNull);
    await tester
        .tap(find.byKey(const ValueKey('location-candidates-scroll-right')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('location-candidates-scroll-left')));
    await tester.pump();
    expect(find.text(first.name), findsAtLeastNWidgets(1));
  });
}

class _EmptyLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(String query) async {
    return const <LocationLookupResult>[];
  }
}

class _ThrowingLocationLookupService extends LocationLookupService {
  @override
  Future<LocationLookupSearchResult> searchWithFallback(String query) async {
    throw const LocationLookupException(
      statusCode: 401,
      message: '네이버 지도 API 인증 또는 서비스 권한을 확인해 주세요.',
      provider: LocationLookupProvider.naver,
    );
  }
}
