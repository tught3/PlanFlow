import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/location/location_picker_screen.dart';
import 'package:planflow/services/location_lookup_service.dart';

void main() {
  testWidgets(
      'LocationPickerScreen shows fallback when in-app map is unavailable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '대전 성심당',
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

    expect(find.text('지도에서 장소 선택'), findsOneWidget);
    expect(find.textContaining('앱 안 지도를 열 수 없습니다.'), findsOneWidget);
    expect(find.textContaining('아래 장소 후보를 선택하거나 외부 지도'), findsOneWidget);
    expect(find.text('Google 지도'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(find.text('TMAP'), findsWidgets);
    expect(find.text('성심당 본점'), findsWidgets);
    expect(find.text('이 위치 사용'), findsOneWidget);
  });

  testWidgets('LocationPickerScreen gives non-map guidance for empty search',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: LocationPickerScreen(
          initialQuery: '',
          locationLookupService: _EmptyLocationLookupService(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '없는장소');
    await tester.tap(find.widgetWithText(FilledButton, '검색'));
    await tester.pumpAndSettle();

    expect(
      find.text('검색 결과가 없어요. 장소명을 더 구체적으로 입력하거나 외부 지도에서 먼저 확인해 주세요.'),
      findsOneWidget,
    );
    expect(find.textContaining('앱 안 지도를 열 수 없습니다.'), findsOneWidget);
  });
}

class _EmptyLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(String query) async {
    return const <LocationLookupResult>[];
  }
}
