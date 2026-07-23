import 'package:klc/klc.dart' as klc;

class KoreanHolidays {
  KoreanHolidays._();

  /// 양력 고정일 "쉬는 날"(공휴일): (month, day) → 이름
  static const Map<(int, int), String> _fixed = {
    (1, 1): '신정',
    (3, 1): '삼일절',
    (5, 5): '어린이날',
    (6, 6): '현충일',
    (8, 15): '광복절',
    (10, 3): '개천절',
    (10, 9): '한글날',
    (12, 25): '성탄절',
  };

  /// 앱이 KASI API/계산으로 자체 표시하는 공휴일 이름 전체(대체공휴일·연휴 포함).
  /// 외부 캘린더 동기화(네이버/구글 등)가 같은 이름의 공휴일을 별도 이벤트로
  /// 또 가져와 화면에 2개로 겹쳐 보이는 걸 막기 위해, 동기화 쪽에서 이 이름과
  /// 정확히 일치하는 제목은 가져오지 않도록 걸러낼 때 쓴다(사용자 지적,
  /// 2026-07-23 — 광복절이 네이버 동기화로 중복 저장됨).
  static const Set<String> knownHolidayNames = {
    '신정',
    '삼일절',
    '어린이날',
    '현충일',
    '광복절',
    '개천절',
    '한글날',
    '성탄절',
    '설날',
    '설날연휴',
    '추석',
    '추석연휴',
    '부처님오신날',
    '제헌절',
    '대체공휴일',
  };

  /// 국경일이지만 "쉬는 날"이 아닌 기념일: (month, day) → 이름.
  /// 이름은 표시하되 날짜 숫자를 빨간(휴무) 색으로 칠하지 않는다.
  /// 제헌절은 2025년까지 이 범주에 속하고, 2026년부터는 쉬는 날이다.
  static const Map<(int, int), String> _commemorativeOnly = {(7, 17): '제헌절'};

  /// [KasiHolidayService]가 한국천문연구원 공공 API에서 받아온 "그 해의
  /// 실제 쉬는 날" 데이터. 연도별로 채워지며, 있으면 [_fixed]/[_lunarForYear]
  /// 계산값보다 우선한다(임시공휴일·선거일 등 계산으로 알 수 없는 항목도
  /// 포함되므로 더 정확하다). 없는 연도는 계산값(klc)으로 그대로 동작한다.
  static final Map<int, Map<(int, int), String>> _liveOverride = {};

  static Map<(int, int), String> _constitutionDayOffs(int year) {
    if (year < 2026) {
      return const {};
    }

    final days = <(int, int), String>{(7, 17): '제헌절'};
    final constitutionDay = DateTime(year, 7, 17);
    if (constitutionDay.weekday == DateTime.saturday ||
        constitutionDay.weekday == DateTime.sunday) {
      days[_nextWeekday(year, 7, 17)] = '대체공휴일';
    }
    return days;
  }

  /// [KasiHolidayService]가 API 응답을 파싱한 뒤 호출한다.
  static void applyLiveData(int year, Map<(int, int), String> dayOff) {
    _liveOverride[year] = Map.unmodifiable(dayOff);
  }

  /// 음력 기반 공휴일 (연도별 양력 환산).
  /// 설날·추석은 전날/당일/다음날(3일) 포함.
  ///
  /// 한국천문연구원(KASI) 데이터 기반의 klc 패키지로 음력→양력을 실시간
  /// 계산한다(지원 범위: 1391~2050년, 그 밖의 연도는 빈 맵 반환).
  /// 과거엔 연도별 양력 날짜를 하드코딩한 표였으나, 매 10년마다 표를
  /// 늘려줘야 하는 유지보수 부담이 있어 계산식으로 교체했다.
  static Map<(int, int), String> _lunarForYear(int year) {
    (int, int)? solarFor(int lunarMonth, int lunarDay) {
      final valid = klc.setLunarDate(year, lunarMonth, lunarDay, false);
      if (!valid) {
        return null;
      }
      return (klc.getSolarMonth(), klc.getSolarDay());
    }

    (int, int) shiftDays((int, int) monthDay, int deltaDays) {
      final shifted = DateTime(
        year,
        monthDay.$1,
        monthDay.$2,
      ).add(Duration(days: deltaDays));
      return (shifted.month, shifted.day);
    }

    final result = <(int, int), String>{};

    final seol = solarFor(1, 1);
    if (seol != null) {
      result[shiftDays(seol, -1)] = '설날연휴';
      result[seol] = '설날';
      result[shiftDays(seol, 1)] = '설날연휴';
    }

    final buddha = solarFor(4, 8);
    if (buddha != null) {
      result[buddha] = '부처님오신날';
    }

    final chuseok = solarFor(8, 15);
    if (chuseok != null) {
      result[shiftDays(chuseok, -1)] = '추석연휴';
      result[chuseok] = '추석';
      result[shiftDays(chuseok, 1)] = '추석연휴';
    }

    return result;
  }

  /// 대체공휴일 대상 + 예외 발생 조건.
  ///
  /// 규칙 (2021~):
  /// - 설날·추석 연휴(3일) 중 1일이라도 일요일/공휴일이면
  ///   → 연휴 종료 후 첫 비공휴일 평일
  /// - 어린이날이 토/일이면 → 다음 첫 평일
  /// - 삼일절·광복절·개천절·한글날·부처님오신날이 일요일이면
  ///   → 다음 첫 평일
  static Set<(int, int)> _substituteDays(int year) {
    final allDays = <(int, int), String>{};
    allDays.addAll(_fixed);
    if (year >= 2026) {
      allDays[(7, 17)] = '제헌절';
    }
    allDays.addAll(_lunarForYear(year));

    final subs = <(int, int)>{};

    /// 3일 연휴(설날·추석) 검사: 셋 중 하나가 일요일이면 대체 추가
    for (final prefix in ['설날', '추석']) {
      final periodKeys =
          allDays.entries
              .where((e) => e.value.startsWith(prefix))
              .map((e) => e.key)
              .toList()
            ..sort((a, b) {
              if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
              return a.$2.compareTo(b.$2);
            });
      if (periodKeys.length != 3) continue;
      final overlapsSunday = periodKeys.any((k) {
        final d = DateTime(year, k.$1, k.$2);
        return d.weekday == DateTime.sunday;
      });
      if (!overlapsSunday) continue;
      var candidate = _nextWeekday(
        year,
        periodKeys.last.$1,
        periodKeys.last.$2,
      );
      while (allDays.containsKey(candidate) || subs.contains(candidate)) {
        candidate = _nextWeekday(year, candidate.$1, candidate.$2);
      }
      subs.add(candidate);
    }

    /// 단일 공휴일 검사
    final singleHolidays = <(int, int), String>{
      (3, 1): '삼일절',
      (5, 5): '어린이날',
      (6, 6): '현충일',
      (8, 15): '광복절',
      (10, 3): '개천절',
      (10, 9): '한글날',
    };
    if (year >= 2026) {
      singleHolidays[(7, 17)] = '제헌절';
    }
    final lunarKeys = _lunarForYear(
      year,
    ).entries.where((e) => e.value == '부처님오신날').map((e) => e.key).toList();
    if (lunarKeys.isNotEmpty) {
      singleHolidays[lunarKeys.first] = '부처님오신날';
    }

    for (final entry in singleHolidays.entries) {
      final (m, d) = entry.key;
      final name = entry.value;
      final date = DateTime(year, m, d);
      final isWeekend = name == '어린이날' || name == '제헌절'
          ? (date.weekday == DateTime.saturday ||
                date.weekday == DateTime.sunday)
          : date.weekday == DateTime.sunday;
      if (!isWeekend) continue;
      var candidate = _nextWeekday(year, m, d);
      while (allDays.containsKey(candidate) || subs.contains(candidate)) {
        candidate = _nextWeekday(year, candidate.$1, candidate.$2);
      }
      subs.add(candidate);
    }

    return subs;
  }

  /// date(m,d) 다음 첫 평일
  static (int, int) _nextWeekday(int year, int month, int day) {
    var m = month;
    var d = day + 1;
    final daysInMonth = DateTime(year, m + 1, 0).day;
    if (d > daysInMonth) {
      d = 1;
      m += 1;
      if (m > 12) {
        m = 1;
      }
    }
    var dt = DateTime(year, m, d);
    while (dt.weekday == DateTime.saturday || dt.weekday == DateTime.sunday) {
      d += 1;
      if (d > DateTime(year, m + 1, 0).day) {
        d = 1;
        m += 1;
        if (m > 12) {
          m = 1;
        }
      }
      dt = DateTime(year, m, d);
    }
    return (m, d);
  }

  /// 모든 공휴일(고정일 + 음력 + 대체)을 한 Map으로 반환.
  /// 제헌절은 2026년부터 포함한다.
  ///
  /// [_liveOverride]에 해당 연도 데이터가 있으면(KasiHolidayService가
  /// 공공 API에서 받아온 값) 그걸 우선 반환한다 — 임시공휴일·선거일처럼
  /// 계산으로는 알 수 없는 항목까지 포함해 더 정확하다. 없으면 klc 계산값.
  static Map<(int, int), String> _allForYear(int year) {
    final live = _liveOverride[year];
    if (live != null) {
      return Map<(int, int), String>.unmodifiable({
        ...live,
        ..._constitutionDayOffs(year),
      });
    }
    final result = <(int, int), String>{};
    result.addAll(_fixed);
    result.addAll(_constitutionDayOffs(year));
    result.addAll(_lunarForYear(year));
    for (final key in _substituteDays(year)) {
      result[key] = '대체공휴일';
    }
    return result;
  }

  /// 주어진 날짜가 한국 쉬는 날(공휴일)이면 true.
  static bool isDayOff(DateTime date) {
    return _allForYear(date.year).containsKey((date.month, date.day));
  }

  /// 주어진 날짜가 한국 공휴일이면 true.
  /// isDayOff()와 동일한 로직으로 하위호환성 유지.
  static bool isHoliday(DateTime date) {
    return isDayOff(date);
  }

  /// 주어진 날짜의 공휴일명, 아니면 null.
  /// 쉬는 날(isDayOff) 또는 국경일(2025년까지의 제헌절)인 경우 이름을 반환.
  static String? holidayName(DateTime date) {
    final (month, day) = (date.month, date.day);
    final allDays = _allForYear(date.year);
    if (allDays.containsKey((month, day))) {
      return allDays[(month, day)];
    }
    return _commemorativeOnly[(month, day)];
  }

  /// 주어진 날짜가 공휴일이거나 주말(토/일)이면 true.
  static bool isHolidayOrWeekend(DateTime date) {
    if (isHoliday(date)) return true;
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return true;
    }
    return false;
  }
}
