import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/env.dart';
import 'korean_holidays.dart';

/// 한국천문연구원(KASI) "특일 정보" 공공데이터포털 API로 그 해의 실제
/// 공휴일 목록을 받아와 [KoreanHolidays]에 반영한다.
///
/// [KoreanHolidays]의 계산식(klc 패키지, 2050년까지)은 오프라인으로도 항상
/// 동작하는 기본값이고, 이 서비스는 그 위에 정부가 실시간으로 발표하는
/// 데이터(임시공휴일·선거일 등 계산으로는 알 수 없는 항목 포함)를 얹어
/// 정확도를 높이는 보강 레이어다. 네트워크가 없거나 API 키가 없거나
/// 실패해도 앱은 klc 계산값으로 계속 동작한다(fail-open).
class KasiHolidayService {
  KasiHolidayService._();

  static final KasiHolidayService instance = KasiHolidayService._();

  static const _endpoint =
      'https://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/getRestDeInfo';
  static const _cacheKeyPrefix = 'kasi_holidays_year_';

  /// 주어진 연도들의 공휴일 데이터를 캐시(있으면 즉시) 또는 API(없으면
  /// 백그라운드로)에서 읽어와 [KoreanHolidays]에 반영한다. 완료를 기다릴
  /// 필요가 없는 fire-and-forget 호출로 설계됐다.
  Future<void> primeYears(Iterable<int> years) async {
    await Future.wait(years.map(_primeYear));
  }

  Future<void> _primeYear(int year) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('$_cacheKeyPrefix$year');
      if (cached != null) {
        _applyRawJson(year, cached);
        return;
      }
      final fetched = await _fetchYear(year);
      if (fetched == null) {
        return;
      }
      final applied = _applyRawJson(year, fetched);
      if (applied) {
        await prefs.setString('$_cacheKeyPrefix$year', fetched);
      }
    } catch (_) {
      // 캐시/네트워크 어느 단계에서 실패하든 klc 계산값으로 계속 동작하면
      // 되므로 조용히 무시한다.
    }
  }

  Future<String?> _fetchYear(int year) async {
    final apiKey = AppEnv.kasiHolidayApiKey;
    if (apiKey.isEmpty) {
      return null;
    }
    final uri = Uri.parse(
      '$_endpoint?serviceKey=$apiKey&solYear=$year&numOfRows=50&_type=json',
    );
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return null;
      }
      return response.body;
    } catch (_) {
      return null;
    }
  }

  /// [rawJson]을 파싱해 [KoreanHolidays]에 반영한다. 성공적으로 최소 1개
  /// 이상의 항목을 반영했으면 true(캐시에 저장할 가치가 있음을 의미).
  @visibleForTesting
  bool applyRawJsonForTesting(int year, String rawJson) =>
      _applyRawJson(year, rawJson);

  bool _applyRawJson(int year, String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return false;
      }
      final body = (decoded['response'] as Map?)?['body'];
      final items = (body as Map?)?['items'];
      final rawItem = (items as Map?)?['item'];
      final itemList = switch (rawItem) {
        List() => rawItem,
        Map() => [rawItem],
        _ => const [],
      };

      final dayOff = <(int, int), String>{};
      for (final entry in itemList) {
        if (entry is! Map) {
          continue;
        }
        final dateName = entry['dateName']?.toString().trim() ?? '';
        final isHoliday = entry['isHoliday']?.toString() == 'Y';
        if (!isHoliday ||
            dateName.isEmpty ||
            (year < 2026 && dateName.contains('제헌절'))) {
          continue;
        }
        final locdate = entry['locdate']?.toString() ?? '';
        if (locdate.length != 8) {
          continue;
        }
        final month = int.tryParse(locdate.substring(4, 6));
        final day = int.tryParse(locdate.substring(6, 8));
        if (month == null || day == null) {
          continue;
        }
        dayOff[(month, day)] = dateName;
      }

      if (dayOff.isEmpty) {
        return false;
      }
      KoreanHolidays.applyLiveData(year, dayOff);
      return true;
    } catch (_) {
      return false;
    }
  }
}
