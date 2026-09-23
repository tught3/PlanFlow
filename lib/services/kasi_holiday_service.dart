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
/// KASI data is the sole authority for official days off. If the API key,
/// network, response, or cache is unavailable, the app fails closed and does
/// not infer a holiday from a fixed-date or lunar calculation.
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
        if (_applyRawJson(year, cached)) {
          return;
        }
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
      // Fail closed: no KASI data means no official holiday classification.
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

  /// [rawJson]을 파싱해 [KoreanHolidays]에 반영한다. 유효한 KASI 응답의
  /// 항목이 0개여도 true이며, 이 경우 해당 연도는 확정된 빈 결과로 저장된다.
  @visibleForTesting
  bool applyRawJsonForTesting(int year, String rawJson) =>
      _applyRawJson(year, rawJson);

  bool _applyRawJson(int year, String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return false;
      }
      final response = decoded['response'];
      if (response is! Map) return false;
      final header = response['header'];
      if (header is! Map || header['resultCode']?.toString() != '00') {
        return false;
      }
      final body = response['body'];
      if (body is! Map) return false;
      final items = body['items'];
      if (items is! Map) return false;
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
        if (!isHoliday || dateName.isEmpty) {
          continue;
        }
        final locdate = entry['locdate']?.toString() ?? '';
        if (locdate.length != 8) {
          continue;
        }
        if (int.tryParse(locdate.substring(0, 4)) != year) {
          continue;
        }
        final month = int.tryParse(locdate.substring(4, 6));
        final day = int.tryParse(locdate.substring(6, 8));
        if (month == null || day == null) {
          continue;
        }
        dayOff[(month, day)] = dateName;
      }

      KoreanHolidays.applyLiveData(year, dayOff);
      return true;
    } catch (_) {
      return false;
    }
  }
}
