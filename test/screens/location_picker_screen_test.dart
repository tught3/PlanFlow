import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/location/location_pick_flow.dart';
import 'package:planflow/screens/location/location_picker_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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

  testWidgets('LocationPickerScreen unfocuses keyboard before button search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _EmptyLocationLookupService();
    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '',
          canUseInAppMapOverride: false,
          locationLookupService: service,
        ),
      ),
    );

    final searchField = find.byKey(const ValueKey('location-search-field'));
    await tester.enterText(searchField, '서울역');
    await tester.showKeyboard(searchField);
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('location-search-button')));
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
    expect(service.searchCallCount, 1);
  });

  testWidgets('LocationPickerScreen unfocuses keyboard before enter search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _EmptyLocationLookupService();
    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '',
          canUseInAppMapOverride: false,
          locationLookupService: service,
        ),
      ),
    );

    final searchField = find.byKey(const ValueKey('location-search-field'));
    await tester.enterText(searchField, '서울역');
    await tester.showKeyboard(searchField);
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
    expect(service.searchCallCount, 1);
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

  testWidgets(
      'pickLocationFromQuery starts current location lookup while place search is pending and passes the future to the picker',
      (tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

    final lookupService = _BlockingLocationLookupService();
    final permissionService = _TrackingPermissionService();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                unawaited(
                  pickLocationFromQuery(
                    context: context,
                    query: '서울역',
                    locationLookupService: lookupService,
                    appPermissionService: permissionService,
                    preferredMapProvider: 'naver',
                    canUseInAppMapOverride: false,
                  ),
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(lookupService.searchStarted.isCompleted, isTrue);
    await permissionService.currentStarted.future.timeout(
      const Duration(seconds: 1),
    );
    expect(find.byType(LocationPickerScreen), findsNothing);

    lookupService.completeWith(
      const LocationLookupSearchResult(
        originalQuery: '서울역',
        results: <LocationLookupResult>[
          LocationLookupResult(
            name: '서울역',
            address: '서울특별시 용산구 한강대로 405',
            latitude: 37.5559,
            longitude: 126.9723,
            provider: LocationLookupProvider.naver,
          ),
        ],
        searchedQueries: <String>['서울역'],
        fallbackQueries: <String>[],
      ),
    );
    await tester.pumpAndSettle();

    final screen = tester.widget<LocationPickerScreen>(
      find.byType(LocationPickerScreen),
    );
    expect(screen.initialMapCenter, isNull);
    expect(screen.initialMapCenterFuture, isNotNull);
    expect(screen.initialResults.single.name, '서울역');
  });

  testWidgets(
      'pickLocationFromQuery opens picker quickly when current location is slow',
      (tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

    final lookupService = _BlockingLocationLookupService();
    final permissionService = _SlowPermissionService();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                unawaited(
                  pickLocationFromQuery(
                    context: context,
                    query: '서울역',
                    locationLookupService: lookupService,
                    appPermissionService: permissionService,
                    preferredMapProvider: 'naver',
                    canUseInAppMapOverride: false,
                  ),
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    lookupService.completeWith(
      const LocationLookupSearchResult(
        originalQuery: '서울역',
        results: <LocationLookupResult>[
          LocationLookupResult(
            name: '서울역',
            address: '서울특별시 용산구 한강대로 405',
            latitude: 37.5559,
            longitude: 126.9723,
            provider: LocationLookupProvider.naver,
          ),
        ],
        searchedQueries: <String>['서울역'],
        fallbackQueries: <String>[],
      ),
    );

    await permissionService.currentStarted.future.timeout(
      const Duration(seconds: 1),
    );
    for (var i = 0;
        i < 10 && find.byType(LocationPickerScreen).evaluate().isEmpty;
        i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final screen = tester.widget<LocationPickerScreen>(
      find.byType(LocationPickerScreen),
    );
    expect(screen.initialMapCenter, isNull);
    expect(screen.initialResults.single.name, '서울역');
    permissionService.completeWith(null);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('pickLocationFromQuery requests location permission before map',
      (tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

    final permissionService = _DeniedPermissionService();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                unawaited(
                  pickLocationFromQuery(
                    context: context,
                    query: '',
                    locationLookupService: _EmptyLocationLookupService(),
                    appPermissionService: permissionService,
                    preferredMapProvider: 'naver',
                    canUseInAppMapOverride: false,
                  ),
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(permissionService.checkCount, greaterThanOrEqualTo(1));
    expect(permissionService.requestCount, 1);
    expect(find.text('위치 권한이 필요해요'), findsOneWidget);

    await tester.tap(find.text('계속 선택'));
    await tester.pumpAndSettle();

    final screen = tester.widget<LocationPickerScreen>(
      find.byType(LocationPickerScreen),
    );
    expect(screen.initialMapCenterFuture, isNull);
    expect(screen.initialMessage, contains('현재 위치를 보려면 위치 권한이 필요해요'));
  });
}

class _EmptyLocationLookupService extends LocationLookupService {
  int searchCallCount = 0;

  @override
  Future<List<LocationLookupResult>> search(String query) async {
    searchCallCount += 1;
    return const <LocationLookupResult>[];
  }

  @override
  Future<LocationLookupSearchResult> searchWithFallback(String query) async {
    searchCallCount += 1;
    return LocationLookupSearchResult(
      originalQuery: query,
      results: const <LocationLookupResult>[],
      searchedQueries:
          query.trim().isEmpty ? const <String>[] : <String>[query.trim()],
      fallbackQueries: const <String>[],
    );
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

class _BlockingLocationLookupService extends LocationLookupService {
  final Completer<void> searchStarted = Completer<void>();
  final Completer<LocationLookupSearchResult> _result =
      Completer<LocationLookupSearchResult>();

  @override
  Future<LocationLookupSearchResult> searchWithFallback(String query) {
    if (!searchStarted.isCompleted) {
      searchStarted.complete();
    }
    return _result.future;
  }

  void completeWith(LocationLookupSearchResult result) {
    if (!_result.isCompleted) {
      _result.complete(result);
    }
  }
}

class _TrackingPermissionService extends AppPermissionService {
  final Completer<void> currentStarted = Completer<void>();

  @override
  Future<bool> checkLocationPermission() async {
    return true;
  }

  @override
  Future<bool> requestLocationPermission() async {
    return true;
  }

  @override
  Future<GeoPoint?> getLastKnownLocation() async {
    return null;
  }

  @override
  Future<GeoPoint?> getCurrentLocation() async {
    if (!currentStarted.isCompleted) {
      currentStarted.complete();
    }
    return const GeoPoint(latitude: 37.5666, longitude: 126.979);
  }
}

class _SlowPermissionService extends AppPermissionService {
  final Completer<void> currentStarted = Completer<void>();
  final Completer<GeoPoint?> _currentLocation = Completer<GeoPoint?>();

  @override
  Future<bool> checkLocationPermission() async {
    return true;
  }

  @override
  Future<bool> requestLocationPermission() async {
    return true;
  }

  @override
  Future<GeoPoint?> getLastKnownLocation() async {
    return null;
  }

  @override
  Future<GeoPoint?> getCurrentLocation() {
    if (!currentStarted.isCompleted) {
      currentStarted.complete();
    }
    return _currentLocation.future;
  }

  void completeWith(GeoPoint? point) {
    if (!_currentLocation.isCompleted) {
      _currentLocation.complete(point);
    }
  }
}

class _DeniedPermissionService extends AppPermissionService {
  int checkCount = 0;
  int requestCount = 0;
  int settingsOpenCount = 0;

  @override
  Future<bool> checkLocationPermission() async {
    checkCount += 1;
    return false;
  }

  @override
  Future<bool> requestLocationPermission() async {
    requestCount += 1;
    return false;
  }

  @override
  Future<bool> openAppSettings() async {
    settingsOpenCount += 1;
    return true;
  }
}
