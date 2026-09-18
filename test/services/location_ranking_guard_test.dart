import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/location_lookup_service.dart';

/// _rankResults의 tier 정렬 + 무관 결과 가드 회귀 테스트.
/// (순수 로직 — sortByRelevance 공개 진입점으로 검증, HTTP 없음)
void main() {
  setUp(() {
    LocationLookupService.resetLookupCacheForTesting();
  });

  LocationLookupResult poi({
    String name = '강릉아산병원',
    String address = '강원특별자치도 강릉시 사천면 방동길 38',
    double lat = 37.745,
    double lng = 128.896,
    LocationLookupProvider provider = LocationLookupProvider.naver,
  }) {
    return LocationLookupResult(
      name: name,
      address: address,
      latitude: lat,
      longitude: lng,
      provider: provider,
    );
  }

  test('strong name-match POI outranks irrelevant address even with provider '
      'and distance bonuses', () {
    final service = LocationLookupService();

    // 주소-only 결과: provider 보너스(+8)와 지역/토큰 겹침으로 점수를 받지만
    // 이름 매칭이 없으므로 tier 0 → 정확히 이름이 일치하는 POI(tier 1)에 밀린다.
    final addressOnly = LocationLookupResult(
      name: '강원특별자치도 강릉시 사천면 방동길 38',
      address: '강원특별자치도 강릉시 사천면 방동길 38',
      latitude: 37.745,
      longitude: 128.896,
      provider: LocationLookupProvider.tmap,
    );

    final ranked = service.sortByRelevance(
      '강릉아산병원',
      [addressOnly, poi(provider: LocationLookupProvider.naver)],
      preferredProvider: LocationLookupProvider.tmap,
    );

    expect(ranked.first.name, '강릉아산병원');
    expect(ranked, hasLength(2));
  });

  test('typo-near name match still survives and ranks as strong', () {
    final service = LocationLookupService();

    final nearMatch = poi(name: '강릉아산정형외과'); // 무관한 다른 병원 아님 — 오탈자 대상
    final typo = poi(name: '강름아산병원'); // 1글자 오탈자 (편집거리 1)
    final unrelatedAddress = LocationLookupResult(
      name: '경기도 성남시 분당구 대왕판교로',
      address: '경기도 성남시 분당구 대왕판교로',
      latitude: 37.395,
      longitude: 127.111,
    );

    final ranked = service.sortByRelevance(
      '강릉아산병원',
      [unrelatedAddress, typo, nearMatch],
    );

    // 오탈자 근접 매칭이 tier 1로 최상위에 온다. 무관한 경기도 주소와
    // 지역 접두사만 겹치는 "강릉아산정형외과"는 tier 0이라 그 아래로 밀린다.
    expect(ranked.first.name, '강름아산병원');
    expect(ranked.map((r) => r.name), containsAll(
      <String>['강름아산병원', '강릉아산정형외과'],
    ));
    expect(ranked, hasLength(3));
  });

  test('all-irrelevant results are dropped to empty instead of showing a '
      'confident wrong marker', () {
    final service = LocationLookupService();

    final wrongAddress = LocationLookupResult(
      name: '충청남도 아산시 염치읍 궁 locals 111',
      address: '충청남도 아산시 염치읍',
      latitude: 36.79,
      longitude: 127.11,
    );

    // 지역 힌트("강릉"), 토큰 겹침 모두 없는 무관 결과만 있으면 빈 결과.
    // wrongAddress(충남 아산)는 쿼리 매칭 지역 힌트가 "강릉"뿐이라 겹침 없음
    // → 마찬가지로 무관으로 탈락한다 (엉뚱한 마커 표시 방지).
    final noAffinity = LocationLookupResult(
      name: '서울특별시 중구 세종대로 110',
      address: '서울특별시 중구 세종대로 110',
      latitude: 37.566,
      longitude: 126.978,
    );

    expect(service.sortByRelevance('강릉아산병원', [noAffinity]), isEmpty);
    expect(
      service.sortByRelevance('강릉아산병원', [noAffinity, wrongAddress]),
      isEmpty,
    );
  });

  test('Latin-script geocode result is not judged irrelevant against a Korean '
      'query (transliteration benefit of the doubt)', () {
    final service = LocationLookupService();

    final latin = LocationLookupResult(
      name: 'Gangnam Station',
      address: 'Gangnam',
      latitude: 37.497,
      longitude: 127.027,
    );

    final ranked = service.sortByRelevance('강남역', [latin]);

    expect(ranked, hasLength(1));
    expect(ranked.single.name, 'Gangnam Station');
  });
}
